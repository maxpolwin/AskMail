import Foundation

/// Watches a directory for changes via a `DispatchSourceFileSystemObject`,
/// debounced — a fast (best-effort) trigger for `DraftScheduler` rather than
/// waiting for its 2-minute floor `Timer`. No third-party dependency and no
/// classic FSEvents API (which needs its own run loop): `DispatchSource` is
/// the idiomatic Foundation-only equivalent. New to this codebase — no
/// existing precedent to mirror, so this is exercised directly by
/// `MailboxWatcherTests` against a real temporary directory.
///
/// All mutation of `source`/`debounceWorkItem`/`reopenWorkItem` is confined
/// to `queue` — including `start()`/`stop()` themselves, which hop onto it
/// synchronously — so a caller on any thread (`DraftScheduler` is
/// `@MainActor`) can never race the watcher's own event handler or reopen
/// logic, which also run on `queue`. An earlier version mutated these
/// properties directly from the caller's thread with no synchronization at
/// all; confirmed via ThreadSanitizer to be a real data race.
final class MailboxWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?
    private var reopenWorkItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.askmail.mailbox-watch")
    private let debounce: TimeInterval
    private let onChange: () -> Void

    init(debounce: TimeInterval, onChange: @escaping () -> Void) {
        self.debounce = debounce
        self.onChange = onChange
    }

    /// `path` need not exist yet (a not-yet-synced account) — `open` simply
    /// fails and the caller's floor `Timer` covers detection until the
    /// directory appears; there is no retry-until-it-exists loop here.
    func start(watching path: String) {
        queue.sync { openSource(path: path) }
    }

    /// Must only ever run on `queue` — called from `start()` (hopped via
    /// `queue.sync`) and from `reopenAfterDirectoryChange` (already on `queue`).
    private func openSource(path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // The source is bound to the open fd/inode, not the path: if
                // the directory is deleted and recreated (e.g. re-syncing an
                // account), this fd's source will never fire for the new
                // directory's future changes, so re-open explicitly.
                self.reopenAfterDirectoryChange(path: path)
                return
            }
            self.debounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.onChange() }
            self.debounceWorkItem = work
            self.queue.asyncAfter(deadline: .now() + self.debounce, execute: work)
        }
        // Closing only inside the cancel handler (guaranteed to run once all
        // pending events have drained) avoids a use-after-close race against
        // an event still being delivered.
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    /// Runs on `queue` (called only from the event handler above, itself
    /// scheduled on `queue`). The reopen is a stored, cancelable work item —
    /// not a bare `asyncAfter` closure — specifically so `stop()` can call it
    /// off before it fires; an earlier version scheduled a bare closure here,
    /// so `stop()` during the 1-second reopen window could still silently
    /// re-arm the watch afterward (confirmed by reproduction).
    private func reopenAfterDirectoryChange(path: String) {
        source?.cancel()
        source = nil
        let work = DispatchWorkItem { [weak self] in self?.openSource(path: path) }
        reopenWorkItem = work
        queue.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func stop() {
        queue.sync {
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            reopenWorkItem?.cancel()
            reopenWorkItem = nil
            source?.cancel()
            source = nil
        }
    }

    deinit {
        debounceWorkItem?.cancel()
        reopenWorkItem?.cancel()
        source?.cancel()
    }
}
