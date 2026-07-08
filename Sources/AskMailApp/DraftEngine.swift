import AskMailCore
import Foundation
import UserNotifications

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
    /// Ready (drafted) count — the same figure the menu bar's "Drafts (n)"
    /// item and Settings' "Drafted" status show (DM-12 surfacing, extended
    /// to this phase's actual output).
    @Published private(set) var readyCount: Int = 0
    /// Newsletter/bulk-mail + auto-generated jobs combined (DraftStore.
    /// skippedJobCount's doc comment explains why they're one figure here).
    @Published private(set) var skippedCount: Int = 0
    private var isRunning = false

    private let settings = SettingsStore.shared

    /// Perf fix (Task 3, item 2): `refreshCounts()` used to open a fresh
    /// `DraftStore` (SQLite open + `FileHardening.lockDown`) on every call —
    /// called after every tick and whenever Settings appears. One instance is
    /// opened lazily and reused for the lifetime of the app; a tick's own
    /// read/write work still opens its own separate connection (WAL mode
    /// supports concurrent connections to the same file fine), since that one
    /// genuinely needs a fresh session per run.
    private var countsStore: DraftStore?

    /// Notification cursor key (`DraftStore.meta`), mirrors the detection
    /// watermark's own persistence idiom. `nonisolated`: read from
    /// `notifyNewlyReadyDrafts`, itself `nonisolated` since it runs inside
    /// `runTick`'s detached section — a plain `String` constant carries no
    /// actual actor-isolated state, so this is just satisfying the checker.
    private nonisolated static let notifiedCursorKey = "draft_last_notified_pk"

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

        // Snapshot the small bits of Settings state the detached work below
        // needs, on the main actor, before hopping off it. Perf fix (Task 3,
        // item 3): everything from here down used to run synchronously on
        // @MainActor -- filesystem walks and SQLite opens -- ahead of this
        // tick's first `await`, which could block UI responsiveness for the
        // duration. `settings`/`SettingsStore` aren't actor-isolated
        // themselves, but reading them only from the main actor keeps this
        // tick's inputs consistent with the guards just above.
        let embeddingModel = settings.embeddingModel
        let localChatModel = settings.localChatModel
        let accountStorageKey = settings.accountStorageKey
        let accountEmail = settings.accountEmail
        let concurrency = Self.concurrency(for: trigger, isOnACPower: PowerState.isOnACPower,
                                           allowOnBattery: settings.draftAllowOnBattery)

        do {
            try await Task.detached(priority: .utility) {
                let draftStore = try DraftStore(path: SettingsStore.draftsDatabasePath)
                let askStore = try SQLiteStore(path: SettingsStore.databasePath)
                // XPCEmailParser (hardening H-6): re-parsing a candidate for
                // classification headers must stay in the sandboxed parser
                // process too, exactly like the ingest path.
                let parser = XPCEmailParser()

                // Recover anything orphaned by a crash/force-quit mid-step
                // before doing anything else this tick.
                try DraftJobProcessor.recoverStuckJobs(draftStore: draftStore)

                // Perf fix (Task 3, item 1): one EmlxLocator.index() walk of
                // the account tree per tick, reused by both
                // detectAndEnqueue (inbox-candidate lookup + EmlxFile
                // construction) and classifyPendingJobs (source-file lookup)
                // below -- previously up to three separate recursive walks
                // per tick (two inside detectAndEnqueue, one here).
                let fileIndex = EmlxLocator.index(accountDirectory: directory)

                let toIngest = try DraftJobProcessor.detectAndEnqueue(
                    envelopeReader: try EnvelopeIndexReader(), draftStore: draftStore,
                    accountDirectory: directory, fileIndex: fileIndex)
                if !toIngest.isEmpty {
                    let ingestor = MailboxIngestor(store: askStore,
                                                   embedder: OllamaEmbedder(model: embeddingModel),
                                                   account: accountStorageKey,
                                                   embeddingStamp: await Vectorizer.embeddingStamp(for: embeddingModel),
                                                   parser: parser)
                    _ = try await ingestor.ingestNew(toIngest)
                }

                // Local-only regardless of the user's configured Q&A provider
                // (H-11 has no per-instance consent moment for an unattended
                // background trigger — see docs/draft-contract.md and the
                // Draft-Modus design plan).
                let localLLM = OllamaClient(host: Defaults.ollamaLocalHost, model: localChatModel)
                try await DraftJobProcessor.classifyPendingJobs(
                    draftStore: draftStore, askStore: askStore, parser: parser, fileIndex: fileIndex,
                    llmFallback: localLLM, accountEmail: accountEmail)

                await DraftJobProcessor.draftEligibleJobs(
                    draftStore: draftStore, askStore: askStore, chatProvider: localLLM,
                    embedder: OllamaEmbedder(model: embeddingModel), concurrency: concurrency)

                // Phase 3: local-only, same as everything else in this tick
                // (H-11 has no per-instance consent moment for an unattended
                // background trigger) — self-gated to once/24h internally.
                try await StyleLearner.learnIfDue(draftStore: draftStore, askStore: askStore,
                                                  chatProvider: localLLM, accountEmail: accountEmail)

                try DraftJobProcessor.purgeIfDue(draftStore: draftStore)

                // Task 2: best-effort local notification for any draft that
                // newly finished this tick, so the user doesn't have to poll
                // the Drafts window to notice one landed.
                await Self.notifyNewlyReadyDrafts(draftStore: draftStore)
            }.value
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

    /// Refreshes the published counts from disk (DM-12: background activity
    /// should be visible, not just toggleable). Call after any run and
    /// whenever Settings or the Drafts window appears.
    func refreshCounts() {
        guard let draftStore = cachedCountsStore() else {
            pendingCount = 0
            failedCount = 0
            readyCount = 0
            skippedCount = 0
            return
        }
        let counts = (try? draftStore.pendingAndFailedCounts()) ?? (pending: 0, failed: 0)
        pendingCount = counts.pending
        failedCount = counts.failed
        readyCount = (try? draftStore.readyDraftCount()) ?? 0
        skippedCount = (try? draftStore.skippedJobCount()) ?? 0
    }

    /// Lazily opens and caches the one `DraftStore` connection `refreshCounts`
    /// reuses (Task 3, item 2). Only a successful open is cached — a failure
    /// (e.g. called before the containing directory exists) retries on the
    /// next call instead of getting stuck permanently reporting zero.
    private func cachedCountsStore() -> DraftStore? {
        if let countsStore { return countsStore }
        let store = try? DraftStore(path: SettingsStore.draftsDatabasePath)
        countsStore = store
        return store
    }

    /// Posts one best-effort `UNUserNotification` per draft that became
    /// `ready` since the last tick, then advances the cursor so it's never
    /// repeated. `nonisolated` (called from `runTick`'s detached section):
    /// notification delivery does its own async XPC work and must never
    /// require hopping back to @MainActor. Cursor-based (`meta` table,
    /// mirrors the detection watermark's own persistence idiom) rather than a
    /// timestamp comparison, so a draft is notified exactly once.
    private nonisolated static func notifyNewlyReadyDrafts(draftStore: DraftStore) async {
        do {
            guard let cursorText = try draftStore.meta(notifiedCursorKey) else {
                // First-ever run: bootstrap the cursor to the current
                // high-water mark without notifying, so any pre-existing
                // ready drafts don't all fire at once the moment this phase
                // starts running.
                let bootstrap = try draftStore.maxReadyDraftPk()
                try draftStore.setMeta(notifiedCursorKey, value: String(bootstrap))
                return
            }
            let cursor = Int64(cursorText) ?? 0
            let newlyReady = try draftStore.readyDrafts(sincePk: cursor)
            guard !newlyReady.isEmpty else { return }
            await DraftNotifier.notify(newlyReadyDrafts: newlyReady)
            let newCursor = newlyReady.map(\.pk).max() ?? cursor
            try draftStore.setMeta(notifiedCursorKey, value: String(newCursor))
        } catch {
            RollingLog.shared.log("draft notification bookkeeping failed: \(error)", level: .info)
        }
    }
}

/// Best-effort local notifications for newly-ready drafts. Guarded on
/// `Bundle.main.bundleIdentifier != nil`: a bare `swift run` debug binary has
/// no bundle, and `UNUserNotificationCenter.current()` deterministically
/// crashes without one. Every failure (permission denied, XPC hiccup, ...) is
/// logged at `.info` and swallowed -- a missed notification must never block
/// or fail the drafting tick itself, and this feature is explicitly
/// read-only surfacing (docs/draft-contract.md), so there is nothing here
/// that ever needs to throw to a caller.
enum DraftNotifier {
    static func notify(newlyReadyDrafts: [DraftRecord]) async {
        guard !newlyReadyDrafts.isEmpty else { return }
        guard Bundle.main.bundleIdentifier != nil else {
            RollingLog.shared.log("draft notification skipped: no app bundle (swift run)", level: .info)
            return
        }
        let center = UNUserNotificationCenter.current()
        do {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                // Requested lazily here, the first time a draft is actually
                // ready to show -- not at launch -- so a user who never
                // enables Draft-Modus is never prompted for a permission
                // only this feature needs.
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            }
            let current = await center.notificationSettings()
            guard current.authorizationStatus == .authorized
                    || current.authorizationStatus == .provisional else { return }

            for draft in newlyReadyDrafts {
                let content = UNMutableNotificationContent()
                content.title = "AskMail"
                content.body = "Draft ready: \(draft.subject.isEmpty ? "(no subject)" : draft.subject)"
                let request = UNNotificationRequest(
                    identifier: "draft-ready-\(draft.pk)", content: content, trigger: nil)
                try await center.add(request)
            }
        } catch {
            RollingLog.shared.log("draft notification failed: \(error)", level: .info)
        }
    }
}
