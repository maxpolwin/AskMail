import AskMailCore
import Combine
import CoreFoundation
import Foundation
import IOKit.ps

/// Whether the Mac is currently running on AC power. Scheduled vectorization
/// only runs on AC (FR-5); the manual trigger ignores this.
enum PowerState {
    static var isOnACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo() else { return true }
        let snapshot = info.takeRetainedValue()
        guard let typeRef = IOPSGetProvidingPowerSourceType(snapshot) else { return true }
        // Fail open: if the power state is unknowable, don't block ingestion.
        return (typeRef.takeUnretainedValue() as String) == kIOPSACPowerValue
    }
}

/// Single owner of vectorization for the app. Both the Settings button (manual)
/// and the hourly scheduler funnel through `run(_:)`, so runs share one code
/// path and can never overlap. Publishes progress/status for the Settings UI.
@MainActor
final class Vectorizer: ObservableObject {
    static let shared = Vectorizer()

    enum Trigger: String { case manual, scheduled }

    @Published private(set) var progress: IngestProgress?
    @Published private(set) var status: String = ""
    /// Files that failed their most recent ingest attempt; drives the
    /// Settings "Retry N failed…" button.
    @Published private(set) var failedCount: Int = 0
    private var isRunning = false

    /// Read-only visibility into `isRunning` for `VectorizationScheduler`'s
    /// watcher-driven trigger: it needs to know a run is already in flight so
    /// it can re-arm its debounce instead of starting an overlapping one, but
    /// the actual no-overlap guard stays solely in `run(_:)` above — this
    /// never gates anything by itself.
    var isBusy: Bool { isRunning }

    private let settings = SettingsStore.shared

    init() {
        refreshFailedCount()
    }

    /// Refreshes `failedCount` from disk. Call after any run and whenever
    /// Settings appears, so a rebuild ("Delete & rebuild…") is reflected too.
    func refreshFailedCount() {
        guard let store = try? SQLiteStore(path: SettingsStore.databasePath) else {
            failedCount = 0
            return
        }
        failedCount = (try? store.failedIngestCount()) ?? 0
    }

    /// Runs an incremental vectorization. Manual runs report problems (no
    /// account, etc.) via `status`; scheduled runs stay silent and skip when off
    /// power (FR-5: skipped, not queued).
    @discardableResult
    func run(_ trigger: Trigger) async -> IngestSummary? {
        guard !isRunning else {
            if trigger == .manual { status = "A vectorization run is already in progress." }
            return nil
        }
        guard let directory = settings.accountDirectoryURL else {
            if trigger == .manual { status = "Select an account first." }
            return nil
        }
        if trigger == .scheduled && !PowerState.isOnACPower {
            RollingLog.shared.log("scheduled vectorize skipped: on battery")
            return nil
        }

        isRunning = true
        progress = IngestProgress(processed: 0, total: 0)
        status = ""
        defer {
            isRunning = false
            progress = nil
            refreshFailedCount()
        }

        let storageKey = settings.accountStorageKey
        do {
            let store = try SQLiteStore(path: SettingsStore.databasePath)
            let model = settings.embeddingModel
            // XPCEmailParser (hardening H-6): all untrusted .emlx/MIME/HTML/PDF
            // parsing runs in the sandboxed parser XPC service, never in this
            // (FDA-holding) process.
            let ingestor = MailboxIngestor(store: store,
                                           embedder: OllamaEmbedder(model: model),
                                           account: storageKey,
                                           embeddingStamp: await Self.embeddingStamp(for: model),
                                           parser: XPCEmailParser())
            let files = EmlxLocator.scan(accountDirectory: directory)
                .sorted { $0.sourceID < $1.sourceID }
            // Failure rows whose file no longer scans (excluded mailbox,
            // deleted message) can never be retried; drop them so the
            // "Retry N failed…" count is honest.
            if let pruned = try? store.pruneIngestFailures(keeping: Set(files.map(\.sourceID))),
               pruned > 0 {
                RollingLog.shared.log("pruned \(pruned) stale ingest failures (no longer scannable)", level: .info)
            }
            let summary = try await ingestor.ingestNew(files) { update in
                Task { @MainActor in
                    let v = Vectorizer.shared
                    if v.isRunning { v.progress = update }
                }
            }
            settings.lastVectorized = Date()
            status = "Done: \(summary.ingested) new, \(summary.empty) empty, \(summary.skipped) unchanged, \(summary.failed) failed."
            RollingLog.shared.log(
                "\(trigger.rawValue) vectorize done: \(summary.ingested) new, \(summary.empty) empty, "
                + "\(summary.skipped) unchanged, \(summary.failed) failed", level: .info)
            return summary
        } catch let error as IngestError {
            // A setup problem stopped the run before it could fail every message.
            // Already-done work is saved; the rest resumes once it's fixed.
            switch error {
            case .embedderUnreachable:
                RollingLog.shared.log("\(trigger.rawValue) vectorize stopped: Ollama unreachable")
                status = "Stopped: Ollama isn\u{2019}t running. Start it (\u{2018}ollama serve\u{2019}), then Vectorize now \u{2014} it resumes where it left off."
            case .embeddingModelMissing(let model):
                RollingLog.shared.log("\(trigger.rawValue) vectorize stopped: embedding model \(model) not installed", level: .error)
                status = "Stopped: the embedding model \u{2018}\(model)\u{2019} isn\u{2019}t installed. Download it above in Local engine, then Vectorize now \u{2014} it resumes where it left off."
            case .embeddingModelMismatch(let configured, let indexed):
                RollingLog.shared.log("\(trigger.rawValue) vectorize refused: index stamped \(indexed), configured \(configured)", level: .error)
                status = "Stopped: this index was built with \u{2018}\(indexed)\u{2019} but \u{2018}\(configured)\u{2019} is selected. Use Delete & rebuild to re-index, or switch the embedding model back."
            }
            return nil
        } catch {
            RollingLog.shared.log("\(trigger.rawValue) vectorize failed: \(error)", level: .error)
            status = "Vectorization failed: \(error)"
            return nil
        }
    }

    /// Re-attempts only the files that failed their last ingest, instead of
    /// re-scanning and re-embedding the whole mailbox. Shares `run`'s
    /// single-flight guard so a retry can never overlap a scheduled/manual run.
    @discardableResult
    func retryFailed() async -> IngestSummary? {
        guard !isRunning else {
            status = "A vectorization run is already in progress."
            return nil
        }
        guard let directory = settings.accountDirectoryURL else {
            status = "Select an account first."
            return nil
        }

        isRunning = true
        progress = IngestProgress(processed: 0, total: 0)
        status = ""
        defer {
            isRunning = false
            progress = nil
            refreshFailedCount()
        }

        let storageKey = settings.accountStorageKey
        do {
            let store = try SQLiteStore(path: SettingsStore.databasePath)
            let failedIDs = Set(try store.failedIngestSourceIDs())
            guard !failedIDs.isEmpty else {
                status = "No failed emails to retry."
                return nil
            }
            let model = settings.embeddingModel
            // XPCEmailParser (hardening H-6): all untrusted .emlx/MIME/HTML/PDF
            // parsing runs in the sandboxed parser XPC service, never in this
            // (FDA-holding) process.
            let ingestor = MailboxIngestor(store: store,
                                           embedder: OllamaEmbedder(model: model),
                                           account: storageKey,
                                           embeddingStamp: await Self.embeddingStamp(for: model),
                                           parser: XPCEmailParser())
            let files = EmlxLocator.scan(accountDirectory: directory)
                .filter { failedIDs.contains($0.sourceID) }
                .sorted { $0.sourceID < $1.sourceID }
            let summary = try await ingestor.ingestNew(files) { update in
                Task { @MainActor in
                    let v = Vectorizer.shared
                    if v.isRunning { v.progress = update }
                }
            }
            settings.lastVectorized = Date()
            status = "Retried \(files.count): \(summary.ingested + summary.empty) now ok, \(summary.failed) still failing."
            RollingLog.shared.log(
                "retry vectorize done: \(summary.ingested) now ok, \(summary.failed) still failing", level: .info)
            return summary
        } catch let error as IngestError {
            switch error {
            case .embedderUnreachable:
                RollingLog.shared.log("retry vectorize stopped: Ollama unreachable", level: .error)
                status = "Stopped: Ollama isn\u{2019}t running. Start it (\u{2018}ollama serve\u{2019}), then retry \u{2014} it resumes where it left off."
            case .embeddingModelMissing(let model):
                RollingLog.shared.log("retry vectorize stopped: embedding model \(model) not installed", level: .error)
                status = "Stopped: the embedding model \u{2018}\(model)\u{2019} isn\u{2019}t installed. Download it above in Local engine, then retry \u{2014} it resumes where it left off."
            case .embeddingModelMismatch(let configured, let indexed):
                RollingLog.shared.log("retry vectorize refused: index stamped \(indexed), configured \(configured)", level: .error)
                status = "Stopped: this index was built with \u{2018}\(indexed)\u{2019} but \u{2018}\(configured)\u{2019} is selected. Use Delete & rebuild to re-index, or switch the embedding model back."
            }
            return nil
        } catch {
            RollingLog.shared.log("retry vectorize failed: \(error)", level: .error)
            status = "Retry failed: \(error)"
            return nil
        }
    }

    /// The stamp for a run: the configured model plus its authoritative
    /// dimension from `/api/show`, falling back to the registry when the
    /// daemon can't answer (the stamp still guards by model name alone).
    static func embeddingStamp(for model: String) async -> EmbeddingStamp {
        if let info = try? await OllamaControl().showModel(model),
           let dimension = info.embeddingLength {
            return EmbeddingStamp(model: model, dimensions: dimension)
        }
        let fallback = ModelCatalog.embedding
            .first { OllamaStatus.modelName($0.id, matches: model) }?
            .embeddingDimensions
        return EmbeddingStamp(model: model, dimensions: fallback)
    }
}

/// Drives scheduled vectorization: hourly while the app runs, plus a catch-up at
/// launch and whenever the Mac is plugged in, plus a fast FSEvents-driven path
/// so newly-arrived mail is searchable in about a minute instead of waiting up
/// to an hour. The AC-power gate lives in `Vectorizer.run(.scheduled)` (and is
/// checked a second time, up front, by the watcher path below so it can tell a
/// battery drop apart from an already-running re-arm), so a run that fires on
/// battery is skipped, not queued (FR-5). Best-effort: the timer does not fire
/// while the Mac is asleep, but wake-from-sleep raises a power-source change
/// that triggers a catch-up.
@MainActor
final class VectorizationScheduler {
    /// Hourly, per the user's requirement (docs default is 6 h).
    static let interval: TimeInterval = 3600
    /// Ignore plug-in catch-ups within this window of the last run, so rapid
    /// unplug/replug doesn't launch back-to-back runs.
    private static let plugInDebounce: TimeInterval = 300
    /// Coalesces a burst of filesystem writes (Mail writes several files per
    /// incoming message) into one trigger. Longer than `DraftScheduler`'s 5s
    /// `fsEventsDebounce` since "searchable in about a minute" has no tight
    /// SLA the way a draft suggestion does.
    static let watchDebounce: TimeInterval = 60
    /// Top-level Apple Mail mailboxes worth FSEvents-watching for indexing:
    /// must stay in sync with `EmlxLocator.indexedMailboxNames`
    /// (`AskMailCore`, internal to that module so not importable here). Sent
    /// matters alongside Inbox because Draft-Modus's `StyleLearner` reads the
    /// user's own sent replies out of this same index.
    private static let watchedMailboxNames: Set<String> = [
        "inbox", "sent", "sent messages", "sent items",
    ]

    private var timer: Timer?
    private var powerSource: CFRunLoopSource?
    private var mailboxWatchers: [MailboxWatcher] = []
    private var watchTrigger: IncrementalIndexWatchTrigger?

    func start() {
        guard timer == nil else { return }  // already started

        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in await Vectorizer.shared.run(.scheduled) }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        observePowerChanges()
        startMailboxWatch()
        RollingLog.shared.log("scheduler started: hourly vectorization on AC power")
        // Catch up now in case the Mac was asleep or the app was closed.
        Task { await Vectorizer.shared.run(.scheduled) }
    }

    /// Tears down the timer, power observer, and mailbox watchers so nothing
    /// outlives the scheduler. Not currently called by `AppDelegate` (the
    /// scheduler lives for the app's lifetime, mirroring `start()`'s existing
    /// shape), but kept symmetric with `start()`'s guard so repeated
    /// start/stop pairs — including from tests — never leak file descriptors
    /// or double-register the power observer/timer.
    func stop() {
        timer?.invalidate()
        timer = nil
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode)
        }
        powerSource = nil
        mailboxWatchers.forEach { $0.stop() }
        mailboxWatchers.removeAll()
        watchTrigger = nil
    }

    /// Registers for IOKit power-source changes (plug in/out, wake) so plugging
    /// in kicks off a due run rather than waiting for the next hourly tick.
    private func observePowerChanges() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { rawContext in
            guard let rawContext else { return }
            let scheduler = Unmanaged<VectorizationScheduler>.fromOpaque(rawContext)
                .takeUnretainedValue()
            Task { @MainActor in scheduler.powerChanged() }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?
            .takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }

    private func powerChanged() {
        guard PowerState.isOnACPower else { return }
        if let last = SettingsStore.shared.lastVectorized,
           Date().timeIntervalSince(last) < Self.plugInDebounce {
            return
        }
        Task { await Vectorizer.shared.run(.scheduled) }
    }

    /// Arms one `MailboxWatcher` per indexed top-level mailbox directory
    /// (Inbox, Sent). `MailboxWatcher` only watches a single, non-recursive
    /// directory (see its header doc) and messages live several directories
    /// deep (`INBOX.mbox/<uuid>/Data/…/Messages/*.emlx`), so a single
    /// account-root watcher would not "support" catching new-mail writes the
    /// way DraftScheduler's per-mailbox watch already doesn't for the same
    /// structural reason — hence one watcher per mailbox here too, mirroring
    /// that precedent, rather than one at the root.
    private func startMailboxWatch() {
        guard let accountDirectory = SettingsStore.shared.accountDirectoryURL else { return }

        let trigger = IncrementalIndexWatchTrigger(
            debounce: Self.watchDebounce,
            isRunning: { Vectorizer.shared.isBusy },
            run: { Task { @MainActor in await Vectorizer.shared.run(.scheduled) } })
        watchTrigger = trigger

        let directories = Self.topLevelMailboxDirectories(in: accountDirectory)
        mailboxWatchers = directories.map { directory in
            // Weak capture of `trigger`: once `stop()` drops `watchTrigger`,
            // an in-flight FSEvents callback becomes a harmless no-op instead
            // of resurrecting a scheduler that's supposed to be torn down.
            let watcher = MailboxWatcher(debounce: Self.watchDebounce) { [weak trigger] in
                Task { @MainActor in trigger?.fire() }
            }
            watcher.start(watching: directory.path)
            return watcher
        }
        if !directories.isEmpty {
            RollingLog.shared.log(
                "mailbox watch armed: \(directories.count) mailbox(es), \(Int(Self.watchDebounce))s debounce",
                level: .info)
        }
    }

    /// Lists `accountDirectory`'s immediate `.mbox` children whose name (case-
    /// insensitively, suffix stripped) is one of `watchedMailboxNames`. Shallow
    /// by design — submailboxes nest (`Archive.mbox/2023.mbox/…`), but only
    /// top-level Inbox/Sent are ever indexed, so there's nothing useful to
    /// find deeper than one level. `internal` (not `private`) so tests can
    /// exercise it directly against a synthetic directory tree. `nonisolated`
    /// since it touches no scheduler state — pure `FileManager` I/O — so
    /// tests can call it synchronously without hopping onto the main actor.
    nonisolated static func topLevelMailboxDirectories(in accountDirectory: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: accountDirectory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { url in
            guard url.pathExtension == "mbox" else { return false }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false else { return false }
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            return watchedMailboxNames.contains(name)
        }
    }
}

/// Decides what a debounced mailbox-watch signal should do, and — when a
/// vectorization run is already in progress — re-arms itself rather than
/// dropping the signal, so a burst that lands mid-run still gets indexed once
/// that run finishes. Each `MailboxWatcher` already coalesces its own burst of
/// file writes into a single call after `debounce` seconds of quiet, so this
/// only has to decide what to do with one already-debounced signal at a time.
///
/// All timing runs through the injectable `scheduleRetry` closure (default:
/// a real delay hopping back onto the main actor) so tests can drive the
/// re-arm path deterministically instead of waiting on a real 60s debounce —
/// mirrors `DraftEngine.concurrency(for:isOnACPower:allowOnBattery:)`, the
/// existing precedent in this codebase for pulling a scheduling decision out
/// into something directly testable.
@MainActor
final class IncrementalIndexWatchTrigger {
    enum Outcome: Equatable { case ran, reArmed, droppedOnBattery }

    private let debounce: TimeInterval
    private let isOnACPower: @MainActor () -> Bool
    private let isRunning: @MainActor () -> Bool
    private let run: @MainActor () -> Void
    private let scheduleRetry: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

    init(debounce: TimeInterval,
         isOnACPower: @escaping @MainActor () -> Bool = { PowerState.isOnACPower },
         isRunning: @escaping @MainActor () -> Bool,
         run: @escaping @MainActor () -> Void,
         scheduleRetry: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, block in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                 Task { @MainActor in block() }
             }
         }) {
        self.debounce = debounce
        self.isOnACPower = isOnACPower
        self.isRunning = isRunning
        self.run = run
        self.scheduleRetry = scheduleRetry
    }

    /// Pure decision, pulled out for direct unit testing without any timers
    /// or FSEvents. A signal that arrives on battery is dropped outright, not
    /// re-armed (FR-5: no battery burn from watcher-driven runs — the hourly
    /// tick or a plug-in catch-up will pick the change up later, same as
    /// `Vectorizer.run(.scheduled)`'s own battery gate). The battery check
    /// wins even when a run also happens to be in progress: there is nothing
    /// useful to re-arm toward if the Mac is unplugged when the retry fires.
    nonisolated static func outcome(isRunning: Bool, isOnACPower: Bool) -> Outcome {
        if !isOnACPower { return .droppedOnBattery }
        return isRunning ? .reArmed : .ran
    }

    /// Evaluates one already-debounced signal from a `MailboxWatcher` and
    /// acts on it: runs the normal incremental vectorization, re-arms for
    /// another `debounce`-second wait, or drops it silently.
    func fire() {
        switch Self.outcome(isRunning: isRunning(), isOnACPower: isOnACPower()) {
        case .droppedOnBattery:
            RollingLog.shared.log(
                "mailbox watch trigger dropped: on battery (FR-5); hourly/plug-in catch-up covers it later")
        case .reArmed:
            RollingLog.shared.log(
                "mailbox watch trigger re-armed: a vectorization run is already in progress", level: .info)
            scheduleRetry(debounce) { [weak self] in self?.fire() }
        case .ran:
            run()
        }
    }
}
