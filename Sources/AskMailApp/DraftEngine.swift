import AskMailCore
import Foundation

/// Single owner of Draft-Modus job processing. Mirrors `Vectorizer`'s shape
/// exactly: both the manual path (a future Settings action) and
/// `DraftScheduler`'s Timer/FSEvents/wake triggers funnel through
/// `runTick(_:)`, guarded by `isRunning` so runs never overlap. Everything
/// here is a no-op unless `SettingsStore.draftModeEnabled` is true, checked
/// first, before any I/O.
///
/// Thin by design and not unit-tested directly — the actual logic lives in
/// `DraftJobProcessor` (`AskMailCore`), which takes every dependency
/// explicitly and is exercised with in-memory stores/stub providers. This
/// class only wires *real* dependencies (real file paths, `XPCEmailParser`,
/// `SettingsStore`) into it, the same split `Vectorizer`/`MailboxIngestor`
/// already use.
@MainActor
final class DraftEngine: ObservableObject {
    static let shared = DraftEngine()

    enum Trigger: String { case timer, fsevents, launch, wake, manual }

    @Published private(set) var lastRunAt: Date?
    @Published private(set) var pendingCount: Int = 0
    @Published private(set) var failedCount: Int = 0
    private var isRunning = false

    private let settings = SettingsStore.shared

    init() {
        refreshCounts()
    }

    /// Runs one detect -> classify -> draft -> purge cycle. Scheduled
    /// triggers stay silent and skip on battery (FR-5 parity: skipped, not
    /// queued) unless `draftAllowOnBattery` is on; `.manual` ignores the
    /// battery gate the same way `Vectorizer`'s manual trigger does.
    @discardableResult
    func runTick(_ trigger: Trigger) async -> Bool {
        guard settings.draftModeEnabled else { return false }
        guard !isRunning else { return false }
        guard let directory = settings.accountDirectoryURL else { return false }
        if trigger != .manual, !PowerState.isOnACPower, !settings.draftAllowOnBattery {
            RollingLog.shared.log("draft tick skipped: on battery", level: .info)
            return false
        }

        isRunning = true
        defer {
            isRunning = false
            lastRunAt = Date()
            refreshCounts()
        }

        do {
            let draftStore = try DraftStore(path: SettingsStore.draftsDatabasePath)
            let askStore = try SQLiteStore(path: SettingsStore.databasePath)
            // XPCEmailParser (hardening H-6): re-parsing a candidate for
            // classification headers must stay in the sandboxed parser
            // process too, exactly like the ingest path.
            let parser = XPCEmailParser()
            let model = settings.embeddingModel

            // Recover anything orphaned by a crash/force-quit mid-step
            // before doing anything else this tick.
            try DraftJobProcessor.recoverStuckJobs(draftStore: draftStore)

            let toIngest = try DraftJobProcessor.detectAndEnqueue(
                envelopeReader: try EnvelopeIndexReader(), draftStore: draftStore,
                accountDirectory: directory)
            if !toIngest.isEmpty {
                let ingestor = MailboxIngestor(store: askStore,
                                               embedder: OllamaEmbedder(model: model),
                                               account: settings.accountStorageKey,
                                               embeddingStamp: await Vectorizer.embeddingStamp(for: model),
                                               parser: parser)
                _ = try await ingestor.ingestNew(toIngest)
            }

            // Local-only regardless of the user's configured Q&A provider
            // (H-11 has no per-instance consent moment for an unattended
            // background trigger — see docs/draft-contract.md and the
            // Draft-Modus design plan).
            let localLLM = OllamaClient(host: Defaults.ollamaLocalHost, model: settings.localChatModel)
            let fileIndex = EmlxLocator.index(accountDirectory: directory)
            try await DraftJobProcessor.classifyPendingJobs(
                draftStore: draftStore, askStore: askStore, parser: parser, fileIndex: fileIndex,
                llmFallback: localLLM, accountEmail: settings.accountEmail)

            let concurrency = Self.concurrency(for: trigger, isOnACPower: PowerState.isOnACPower,
                                               allowOnBattery: settings.draftAllowOnBattery)
            await DraftJobProcessor.draftEligibleJobs(
                draftStore: draftStore, askStore: askStore, chatProvider: localLLM,
                embedder: OllamaEmbedder(model: model), concurrency: concurrency)

            // Phase 3: local-only, same as everything else in this tick
            // (H-11 has no per-instance consent moment for an unattended
            // background trigger) — self-gated to once/24h internally.
            try await StyleLearner.learnIfDue(draftStore: draftStore, askStore: askStore,
                                              chatProvider: localLLM, accountEmail: settings.accountEmail)

            try DraftJobProcessor.purgeIfDue(draftStore: draftStore)
        } catch {
            RollingLog.shared.log("draft tick failed: \(error)", level: .error)
        }
        return true
    }

    /// Pure decision, pulled out of `runTick` so it's directly unit-testable
    /// despite `DraftEngine` itself not being (matches `Vectorizer`
    /// precedent) — `.manual` bypasses the battery-derived throttle too,
    /// matching `runTick`'s earlier battery-skip bypass for the same
    /// trigger, not just AC-power's usual 2.
    nonisolated static func concurrency(for trigger: Trigger, isOnACPower: Bool, allowOnBattery: Bool) -> Int {
        if trigger == .manual { return 2 }
        return isOnACPower ? 2 : (allowOnBattery ? 1 : 0)
    }

    /// Refreshes `pendingCount`/`failedCount` from disk (DM-12: background
    /// activity should be visible, not just toggleable). Call after any run
    /// and whenever Settings appears.
    func refreshCounts() {
        guard let draftStore = try? DraftStore(path: SettingsStore.draftsDatabasePath) else {
            pendingCount = 0
            failedCount = 0
            return
        }
        let counts = (try? draftStore.pendingAndFailedCounts()) ?? (pending: 0, failed: 0)
        pendingCount = counts.pending
        failedCount = counts.failed
    }
}
