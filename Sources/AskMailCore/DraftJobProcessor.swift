import Foundation

enum DraftJobError: Error, CustomStringConvertible {
    case missingThreadContext
    case emptyThread
    case emptyDraft

    var description: String {
        switch self {
        case .missingThreadContext: return "message not found or has no resolved thread"
        case .emptyThread: return "resolved thread has no messages"
        case .emptyDraft: return "chat provider returned an empty draft"
        }
    }
}

/// The testable core of Draft-Modus's background orchestration — every
/// function here takes its dependencies explicitly (stores, parser, chat
/// provider, embedder), so it can be exercised with in-memory stores and stub
/// providers exactly like `DraftPipelineIntegrationTests`. `DraftEngine`
/// (`Sources/AskMailApp`) is the thin, untested-directly glue that wires real
/// dependencies (real file paths, `XPCEmailParser`, `SettingsStore`) into
/// these — the same split as `Ingestor.swift` (tested core) vs.
/// `Vectorizer.swift` (thin scheduling glue).
public enum DraftJobProcessor {

    public static let defaultMaxAttempts = 5

    /// Exponential backoff between automatic retries, capped at an hour:
    /// attempt 1 waits 2 min, 2 waits 4, 3 waits 8, 4 waits 16. With
    /// `defaultMaxAttempts == 5` and the retry filter's strict
    /// `attempts < maxAttempts`, a job's `attempts` reaches 5 after the 4th
    /// retry fails, which excludes it from any further retry — so
    /// `backoffSeconds(forAttempt: 5)` (32 min) is never actually consulted.
    /// No precedent value existed anywhere in the codebase for either
    /// number — a starting point to tune.
    public static func backoffSeconds(forAttempt attempt: Int) -> TimeInterval {
        min(pow(2, Double(attempt)) * 60, 3600)
    }

    /// A poll re-examines this trailing window even though the persisted
    /// watermark has already advanced past it — see `detectAndEnqueue`.
    static let watermarkGraceSeconds: Int64 = 300

    /// A job stuck in `.classifying`/`.drafting` longer than this was almost
    /// certainly orphaned by a crash/force-quit mid-step, not genuinely still
    /// in progress — see `recoverStuckJobs`.
    public static let stuckJobThresholdSeconds: TimeInterval = 600

    // MARK: Detection

    /// Fast candidate check: reads the drafts.db watermark, queries the
    /// envelope index for anything newer (with a trailing grace window —
    /// below), resolves each candidate ROWID to a file path, and keeps only
    /// Inbox mail (stricter than the ingestion allowlist, which also permits
    /// Sent — a reply is never drafted for the user's own outgoing mail).
    /// Enqueues a `draft_jobs` row for every surviving candidate.
    ///
    /// The watermark only ever advances *forward* (`max(watermark, ...)`),
    /// guaranteeing progress, but the *query* floor is `watermark -
    /// watermarkGraceSeconds`, so a message that ties or barely trails a
    /// previous poll's max timestamp — but only commits to the envelope
    /// index in a *later* poll (ordinary cross-mailbox sync races, clock
    /// skew, or the watermark having already advanced past it from
    /// non-Inbox mail in the same batch) — still gets re-examined instead of
    /// being silently and permanently skipped by a strict `date > watermark`
    /// comparison with no tiebreak. `enqueueJob` is idempotent (`INSERT OR
    /// IGNORE`), so re-examining an already-enqueued candidate is a safe
    /// no-op. This is a bounded mitigation, not an absolute guarantee: a
    /// message delayed by more than the grace window could still be missed.
    ///
    /// Returns the `EmlxFile`s the caller should feed into
    /// `MailboxIngestor.ingestNew(_:)` — detection never ingests itself, so
    /// thread-linking/chunking/embedding stays on the one shared, tested path
    /// `Vectorizer` also uses.
    @discardableResult
    public static func detectAndEnqueue(envelopeReader: EnvelopeIndexReader, draftStore: DraftStore,
                                        accountDirectory: URL,
                                        watermarkKey: String = "draft_watermark_date_unix",
                                        now: Date = Date()) throws -> [EmlxFile] {
        let watermark = Int64(try draftStore.meta(watermarkKey) ?? "0") ?? 0
        let queryFloor = max(0, watermark - watermarkGraceSeconds)
        let candidates = try envelopeReader.messages(newerThanUnix: queryFloor)
        guard !candidates.isEmpty else { return [] }
        let newWatermark = max(watermark, candidates.map(\.dateReceivedUnix).max() ?? watermark)

        let fileIndex = EmlxLocator.index(accountDirectory: accountDirectory)
        var enqueuedSourceIDs: Set<Int64> = []
        for candidate in candidates {
            guard let url = fileIndex[candidate.rowID],
                  EmlxLocator.topLevelMailbox(of: url)?.lowercased() == "inbox" else { continue }
            try draftStore.enqueueJob(sourceID: candidate.rowID, messageID: nil,
                                     detectedAt: Int64(now.timeIntervalSince1970))
            enqueuedSourceIDs.insert(candidate.rowID)
        }
        try draftStore.setMeta(watermarkKey, value: String(newWatermark))

        guard !enqueuedSourceIDs.isEmpty else { return [] }
        return EmlxLocator.scan(accountDirectory: accountDirectory)
            .filter { enqueuedSourceIDs.contains($0.sourceID) }
    }

    // MARK: Classification

    /// Classifies every `pending` job, plus every backoff-eligible `.failed`
    /// job (re-parsing + re-classifying on *every* retry, regardless of
    /// whether that job's most recent failure was actually during
    /// classification or during drafting in `draftOne`). This is
    /// deliberately the *only* retry path: a job can never reach `draftOne`
    /// without having freshly passed the newsletter/auto-generated gate in
    /// the same retry cycle. An earlier version let `draftEligibleJobs`
    /// retry `.failed` jobs directly — which meant a `.ambiguous` verdict
    /// (a message with a real newsletter-ish signal that merely hit an
    /// LLM/transient hiccup) or a job that failed before `messageID` was ever
    /// recorded could retry straight into drafting with no re-classification,
    /// silently bypassing the newsletter gate (or, for a nil-messageID job,
    /// deterministically failing every retry on a confusing, unrelated error
    /// until it was pruned). Re-parsing an already-eligible job that failed
    /// during drafting is slightly redundant but cheap and safe — not a
    /// correctness risk the way skipping re-classification was.
    ///
    /// `.personal` -> `eligible`, `.newsletter` -> `newsletterSkipped`.
    /// `.ambiguous` is a genuine classification failure (the classifier
    /// already resolves ordinary ambiguity via `llmFallback`, so this only
    /// happens on an LLM/transient error) -- treated as `failed` + retryable,
    /// not a silent permanent skip.
    public static func classifyPendingJobs(draftStore: DraftStore, askStore: SQLiteStore,
                                           parser: EmailParsing, fileIndex: [Int64: URL],
                                           llmFallback: ChatProvider?, accountEmail: String,
                                           maxAttempts: Int = defaultMaxAttempts,
                                           now: Date = Date()) async throws {
        let pending = try draftStore.jobs(in: [.pending])
        let retryableFailed = try draftStore.jobs(in: [.failed]).filter { job in
            job.attempts < maxAttempts
                && now.timeIntervalSince1970 - Double(job.updatedAt) >= backoffSeconds(forAttempt: job.attempts)
        }

        for job in pending + retryableFailed {
            let updatedAt = Int64(now.timeIntervalSince1970)
            guard let url = fileIndex[job.sourceID] else {
                try draftStore.updateJobState(sourceID: job.sourceID, state: .failed,
                                              attempts: job.attempts + 1,
                                              lastError: "source file not found", updatedAt: updatedAt)
                continue
            }
            try draftStore.updateJobState(sourceID: job.sourceID, state: .classifying,
                                          attempts: job.attempts, lastError: nil, updatedAt: updatedAt)
            do {
                let email = try await parser.parse(fileURL: url)
                let headers = NewsletterClassifier.headers(from: email)

                if NewsletterClassifier.isAutoGenerated(headers: headers) {
                    try draftStore.updateJobState(sourceID: job.sourceID, messageID: email.messageID,
                                                  state: .autoGenerated, attempts: job.attempts,
                                                  lastError: nil, updatedAt: updatedAt)
                    continue
                }

                // Hard gate, same shape as isAutoGenerated above: nobody is
                // listening at a noreply@/no-reply@ address, so this never
                // reaches classify's weak-signal/LLM-fallback path at all --
                // reuses newsletterSkipped since the outcome (never drafted)
                // is identical, not a distinct reason worth its own state.
                if NewsletterClassifier.isNoReplySender(email.sender) {
                    try draftStore.updateJobState(sourceID: job.sourceID, messageID: email.messageID,
                                                  state: .newsletterSkipped, attempts: job.attempts,
                                                  lastError: nil, updatedAt: updatedAt)
                    continue
                }

                let priorCorrespondence = try hasPriorSentCorrespondence(
                    messageID: email.messageID, accountEmail: accountEmail, store: askStore)
                let verdict = await NewsletterClassifier.classify(
                    headers: headers, sender: email.sender, bodyText: email.bodyText,
                    hasPriorSentCorrespondence: priorCorrespondence, llmFallback: llmFallback)

                switch verdict {
                case .newsletter:
                    try draftStore.updateJobState(sourceID: job.sourceID, messageID: email.messageID,
                                                  state: .newsletterSkipped, attempts: job.attempts,
                                                  lastError: nil, updatedAt: updatedAt)
                case .personal:
                    try draftStore.updateJobState(sourceID: job.sourceID, messageID: email.messageID,
                                                  state: .eligible, attempts: job.attempts,
                                                  lastError: nil, updatedAt: updatedAt)
                case .ambiguous:
                    try draftStore.updateJobState(sourceID: job.sourceID, messageID: email.messageID,
                                                  state: .failed, attempts: job.attempts + 1,
                                                  lastError: "classification ambiguous", updatedAt: updatedAt)
                }
            } catch {
                try draftStore.updateJobState(sourceID: job.sourceID, state: .failed,
                                              attempts: job.attempts + 1,
                                              lastError: String(describing: error), updatedAt: updatedAt)
            }
        }
    }

    /// Approximates "have I already replied in this conversation?" at the
    /// thread level (not a mailbox-wide sent-correspondence signal — the
    /// current schema has no recipient/mailbox-role columns to support that
    /// more general question). Thread-scoped is arguably the more precise
    /// signal for drafting purposes anyway: it asks exactly "is this an
    /// ongoing conversation I'm already part of?"
    static func hasPriorSentCorrespondence(messageID: String, accountEmail: String,
                                           store: SQLiteStore) throws -> Bool {
        guard !accountEmail.isEmpty,
              let resolved = try store.messageByMessageID(messageID),
              let threadID = resolved.threadID else { return false }
        return try store.threadMessages(threadID: threadID)
            .contains { $0.sender.localizedCaseInsensitiveContains(accountEmail) }
    }

    // MARK: Drafting

    /// Drafts every `eligible` job, bounded to `concurrency` in flight at
    /// once (`concurrency == 0` skips this step entirely — the caller's
    /// battery policy). Retrying a `.failed` job is `classifyPendingJobs`'s
    /// job, not this function's — see its doc comment.
    public static func draftEligibleJobs(draftStore: DraftStore, askStore: SQLiteStore,
                                         chatProvider: ChatProvider, embedder: EmbeddingProvider,
                                         concurrency: Int, now: Date = Date()) async {
        guard concurrency > 0 else { return }
        let candidates = (try? draftStore.jobs(in: [.eligible])) ?? []
        guard !candidates.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            var index = 0
            func launchNext() {
                guard index < candidates.count else { return }
                let job = candidates[index]
                index += 1
                group.addTask {
                    await draftOne(job: job, draftStore: draftStore, askStore: askStore,
                                   chatProvider: chatProvider, embedder: embedder, now: now)
                }
            }
            for _ in 0..<min(concurrency, candidates.count) { launchNext() }
            while await group.next() != nil { launchNext() }
        }
    }

    private static func draftOne(job: DraftJob, draftStore: DraftStore, askStore: SQLiteStore,
                                 chatProvider: ChatProvider, embedder: EmbeddingProvider, now: Date) async {
        let updatedAt = Int64(now.timeIntervalSince1970)
        do {
            try draftStore.updateJobState(sourceID: job.sourceID, state: .drafting,
                                          attempts: job.attempts, lastError: nil, updatedAt: updatedAt)

            guard let messageID = job.messageID,
                  let resolved = try askStore.messageByMessageID(messageID),
                  let threadID = resolved.threadID else {
                throw DraftJobError.missingThreadContext
            }
            let fullThread = try askStore.threadMessages(threadID: threadID)
            // Draft a reply to *this job's* message specifically, not
            // whichever thread member happens to be chronologically newest:
            // under out-of-order delivery, the thread's true latest member
            // can be the account's own already-sent reply to a message
            // later than this one, which would otherwise produce a
            // nonsensical "reply to yourself" draft. Truncating to (and
            // including) this job's own message makes `DraftAssembler`'s
            // internal `thread.last` correct by construction.
            guard let targetIndex = fullThread.firstIndex(where: { $0.messageID == messageID }) else {
                throw DraftJobError.missingThreadContext
            }
            let thread = Array(fullThread[0...targetIndex])
            guard let latest = thread.last else { throw DraftJobError.emptyThread }

            let embedding = try await embedder.embed([latest.bodyText]).first ?? []
            let grounding = try Retriever.hybridRetrieve(
                embedding: embedding, keywordQuery: latest.bodyText, store: askStore,
                vectorTopN: Defaults.vectorTopN, keywordTopN: Defaults.keywordTopN,
                relevanceFloor: Defaults.relevanceFloor, excludingMessageIDs: Set(thread.map(\.messageID)),
                log: { RollingLog.shared.log($0, level: $1) })

            // Best-effort: a lookup failure (or no learned profile yet) must
            // never block drafting itself (Phase 3, docs/style-learning-contract.md).
            // Logged rather than silently swallowed so a persistently-failing
            // lookup (e.g. a corrupt drafts.db) is diagnosable.
            let styleGuidance: String?
            do {
                styleGuidance = try StyleLearner.guidance(forRecipient: latest.sender, draftStore: draftStore)
            } catch {
                RollingLog.shared.log("style guidance lookup failed for \(latest.sender): \(error)", level: .debug)
                styleGuidance = nil
            }
            let assembled = DraftAssembler().assemble(thread: thread, grounding: grounding, styleGuidance: styleGuidance)
            var draftText = ""
            for try await token in chatProvider.stream(ChatRequest(system: assembled.system, user: assembled.user)) {
                draftText += token
            }
            guard !draftText.isEmpty else { throw DraftJobError.emptyDraft }

            try draftStore.insertDraft(threadID: threadID, latestMessageID: latest.messageID,
                                       sender: latest.sender, subject: latest.subject,
                                       draftText: draftText, generatedAt: updatedAt, status: .ready)
            try draftStore.updateJobState(sourceID: job.sourceID, state: .drafted,
                                          attempts: job.attempts, lastError: nil, updatedAt: updatedAt)
        } catch {
            try? draftStore.updateJobState(sourceID: job.sourceID, state: .failed,
                                           attempts: job.attempts + 1,
                                           lastError: String(describing: error), updatedAt: updatedAt)
        }
    }

    // MARK: Recovery

    /// Recovers jobs orphaned by a crash/force-quit while `.classifying` or
    /// `.drafting` — states no query anywhere else revisits (`pending`/
    /// `failed` are the only states `classifyPendingJobs` looks at;
    /// `eligible` is the only one `draftEligibleJobs` looks at), so without
    /// this a killed-mid-step job would sit forever, invisible to
    /// processing, `pruneJobs`, and `pendingAndFailedCounts` alike. Resets
    /// any such job back to a state a subsequent pass will pick up, once
    /// it's been stuck longer than any single classify/draft step should
    /// reasonably take. Call at the start of every tick — cheap (two small
    /// queries) even when nothing is stuck.
    public static func recoverStuckJobs(draftStore: DraftStore,
                                        staleAfterSeconds: TimeInterval = stuckJobThresholdSeconds,
                                        now: Date = Date()) throws {
        let cutoff = Int64(now.timeIntervalSince1970) - Int64(staleAfterSeconds)
        let updatedAt = Int64(now.timeIntervalSince1970)
        for job in try draftStore.jobs(in: [.classifying]) where job.updatedAt < cutoff {
            try draftStore.updateJobState(sourceID: job.sourceID, state: .pending, attempts: job.attempts,
                                          lastError: "recovered after an interrupted classification",
                                          updatedAt: updatedAt)
        }
        for job in try draftStore.jobs(in: [.drafting]) where job.updatedAt < cutoff {
            try draftStore.updateJobState(sourceID: job.sourceID, state: .eligible, attempts: job.attempts,
                                          lastError: "recovered after an interrupted draft attempt",
                                          updatedAt: updatedAt)
        }
    }

    // MARK: Retention

    /// Once-per-24h purge of `drafts`/`draft_jobs` rows older than 14 days,
    /// gated by a `meta` timestamp so it's a no-op on every other tick.
    public static func purgeIfDue(draftStore: DraftStore, retentionDays: Int = 14,
                                  maxAttempts: Int = defaultMaxAttempts, now: Date = Date()) throws {
        let lastPurgeKey = "draft_last_purge_unix"
        let nowUnix = Int64(now.timeIntervalSince1970)
        let lastPurge = Int64(try draftStore.meta(lastPurgeKey) ?? "0") ?? 0
        guard nowUnix - lastPurge >= 86400 else { return }

        let cutoff = nowUnix - Int64(retentionDays) * 86400
        let draftsPruned = try draftStore.pruneDrafts(olderThanUnix: cutoff)
        let jobsPruned = try draftStore.pruneJobs(olderThanUnix: cutoff, maxAttempts: maxAttempts)
        try draftStore.setMeta(lastPurgeKey, value: String(nowUnix))
        if draftsPruned > 0 || jobsPruned > 0 {
            RollingLog.shared.log("draft purge: \(draftsPruned) drafts, \(jobsPruned) jobs", level: .info)
        }
    }
}
