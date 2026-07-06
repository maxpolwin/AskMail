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
            let ingestor = MailboxIngestor(store: store,
                                           embedder: OllamaEmbedder(model: settings.embeddingModel),
                                           account: storageKey)
            let files = EmlxLocator.scan(accountDirectory: directory)
                .sorted { $0.sourceID < $1.sourceID }
            let summary = try await ingestor.ingestNew(files) { update in
                Task { @MainActor in
                    let v = Vectorizer.shared
                    if v.isRunning { v.progress = update }
                }
            }
            settings.lastVectorized = Date()
            status = "Done: \(summary.ingested) new, \(summary.skipped) unchanged, \(summary.failed) failed."
            RollingLog.shared.log(
                "\(trigger.rawValue) vectorize done: \(summary.ingested) new, "
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
            let ingestor = MailboxIngestor(store: store,
                                           embedder: OllamaEmbedder(model: settings.embeddingModel),
                                           account: storageKey)
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
            status = "Retried \(files.count): \(summary.ingested) now ok, \(summary.failed) still failing."
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
            }
            return nil
        } catch {
            RollingLog.shared.log("retry vectorize failed: \(error)", level: .error)
            status = "Retry failed: \(error)"
            return nil
        }
    }
}

/// Drives scheduled vectorization: hourly while the app runs, plus a catch-up at
/// launch and whenever the Mac is plugged in. The AC-power gate lives in
/// `Vectorizer.run(.scheduled)`, so a run that fires on battery is skipped, not
/// queued (FR-5). Best-effort: the timer does not fire while the Mac is asleep,
/// but wake-from-sleep raises a power-source change that triggers a catch-up.
@MainActor
final class VectorizationScheduler {
    /// Hourly, per the user's requirement (docs default is 6 h).
    static let interval: TimeInterval = 3600
    /// Ignore plug-in catch-ups within this window of the last run, so rapid
    /// unplug/replug doesn't launch back-to-back runs.
    private static let plugInDebounce: TimeInterval = 300

    private var timer: Timer?
    private var powerSource: CFRunLoopSource?

    func start() {
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in await Vectorizer.shared.run(.scheduled) }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        observePowerChanges()
        RollingLog.shared.log("scheduler started: hourly vectorization on AC power")
        // Catch up now in case the Mac was asleep or the app was closed.
        Task { await Vectorizer.shared.run(.scheduled) }
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
}
