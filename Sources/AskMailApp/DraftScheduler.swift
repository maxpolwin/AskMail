import AppKit
import AskMailCore
import Combine
import Foundation

/// Drives Draft-Modus job processing: an FSEvents-equivalent watch on the
/// account's `INBOX.mbox` for a fast trigger, a 2-minute floor `Timer` as a
/// safety net against filesystem-watch flakiness, a launch catch-up, and a
/// wake-from-sleep catch-up. Entirely inert until
/// `SettingsStore.draftModeEnabled` is true — `arm()`/`disarm()` follow that
/// setting directly, so turning Draft-Modus off stops every timer/watch/task
/// this owns, not just the tick's own early-return gate in `DraftEngine`.
@MainActor
final class DraftScheduler {
    /// Safety net against filesystem-watch flakiness — comfortably inside the
    /// 15-minute SLA even with generation time included.
    static let floorInterval: TimeInterval = 120
    /// Coalesces a burst of filesystem events (e.g. a multi-message sync)
    /// into one tick instead of one per file write.
    static let fsEventsDebounce: TimeInterval = 5

    private var timer: Timer?
    private var watcher: MailboxWatcher?
    private var wakeTask: Task<Void, Never>?
    private var enabledObserver: AnyCancellable?

    func start() {
        enabledObserver = SettingsStore.shared.$draftModeEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled { self?.arm() } else { self?.disarm() }
            }
    }

    private func arm() {
        guard timer == nil else { return }  // already armed

        let timer = Timer(timeInterval: Self.floorInterval, repeats: true) { _ in
            Task { @MainActor in await DraftEngine.shared.runTick(.timer) }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        if let inboxDirectory = SettingsStore.shared.accountDirectoryURL?
            .appendingPathComponent("INBOX.mbox", isDirectory: true) {
            let watcher = MailboxWatcher(debounce: Self.fsEventsDebounce) {
                Task { @MainActor in await DraftEngine.shared.runTick(.fsevents) }
            }
            watcher.start(watching: inboxDirectory.path)
            self.watcher = watcher
        }

        wakeTask = Task { @MainActor in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                await DraftEngine.shared.runTick(.wake)
            }
        }

        RollingLog.shared.log("draft scheduler armed: 2-min floor + mailbox watch + wake catch-up", level: .info)
        // Catch up now in case Draft-Modus was just enabled, or the Mac was
        // asleep/the app was closed since it last ran.
        Task { await DraftEngine.shared.runTick(.launch) }
    }

    private func disarm() {
        timer?.invalidate()
        timer = nil
        watcher?.stop()
        watcher = nil
        wakeTask?.cancel()
        wakeTask = nil
        RollingLog.shared.log("draft scheduler disarmed (Draft-Modus turned off)", level: .info)
    }
}
