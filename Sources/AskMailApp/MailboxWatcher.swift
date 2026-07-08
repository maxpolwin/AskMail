import Foundation
import CoreServices

/// Watches a mailbox directory *tree* for changes via FSEvents, debounced —
/// a fast (best-effort) trigger for `DraftScheduler` and
/// `VectorizationScheduler` rather than waiting for their floor `Timer`s.
///
/// FSEvents, not a kqueue `DispatchSourceFileSystemObject`: a kqueue source
/// watches a single directory's *own entries*, but Apple Mail writes new
/// `.emlx` files several levels below the watched `.mbox` root
/// (`INBOX.mbox/<UUID>/Data/…/Messages/*.emlx`), which a kqueue on the root
/// never sees. FSEvents monitors the whole subtree by path prefix. The
/// classic objection to FSEvents — needing its own run loop — doesn't apply:
/// `FSEventStreamSetDispatchQueue` delivers straight onto our private queue.
/// Being path-based (not fd/inode-based) also removes the old
/// reopen-after-delete dance: a deleted-and-recreated mailbox directory
/// (e.g. a re-syncing account) keeps reporting events with no re-arm needed,
/// and a path that doesn't exist yet simply starts reporting when it appears
/// (the floor `Timer` covers detection either way).
///
/// All mutation of `stream`/`debounceWorkItem` is confined to `queue` —
/// including `start()`/`stop()` themselves, which hop onto it synchronously —
/// so a caller on any thread (both schedulers are `@MainActor`) can never
/// race the watcher's own event delivery, which also runs on `queue`.
final class MailboxWatcher {
    private var stream: FSEventStreamRef?
    /// Retained context handed to the C callback. A weak box, not `self`:
    /// the callback must never be able to resurrect or dangle a watcher
    /// whose owner already dropped it.
    private var contextBox: Unmanaged<WeakBox>?
    private var debounceWorkItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.askmail.mailbox-watch")
    private let debounce: TimeInterval
    private let onChange: () -> Void

    private final class WeakBox {
        weak var watcher: MailboxWatcher?
        init(_ watcher: MailboxWatcher) { self.watcher = watcher }
    }

    init(debounce: TimeInterval, onChange: @escaping () -> Void) {
        self.debounce = debounce
        self.onChange = onChange
    }

    /// `path` need not exist yet (a not-yet-synced account) — FSEvents
    /// watches by path prefix, so events begin flowing if/when the
    /// directory appears; there is no retry loop and no failure mode here
    /// beyond the stream not starting (logged fail-quiet, floor `Timer`
    /// covers it).
    func start(watching path: String) {
        queue.sync { openStream(path: path) }
    }

    /// Must only ever run on `queue` (called from `start()`, hopped via
    /// `queue.sync`).
    private func openStream(path: String) {
        guard stream == nil else { return }

        let box = Unmanaged.passRetained(WeakBox(self))
        var context = FSEventStreamContext(version: 0,
                                           info: box.toOpaque(),
                                           retain: nil,
                                           release: nil,
                                           copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            // Already on `queue` (FSEventStreamSetDispatchQueue below).
            Unmanaged<WeakBox>.fromOpaque(info).takeUnretainedValue()
                .watcher?.scheduleDebouncedChange()
        }
        guard let created = FSEventStreamCreate(
            nil, callback, &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,  // kernel-side coalescing; our own `debounce` does the real gating
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else {
            box.release()
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            box.release()
            return
        }
        stream = created
        contextBox = box
    }

    /// Runs on `queue` (event delivery is scheduled there).
    private func scheduleDebouncedChange() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    func stop() {
        queue.sync { teardown() }
    }

    /// Must only ever run on `queue`. `queue.sync` from `stop()`/`deinit`
    /// doubles as the barrier that guarantees no callback is mid-flight when
    /// the stream and its context box are released.
    private func teardown() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        contextBox?.release()
        contextBox = nil
    }

    deinit {
        // Safe: the last reference can't be dropped from `queue` itself
        // (nothing on `queue` retains the watcher — the context box is weak,
        // the work item captures weak self), so this never deadlocks.
        queue.sync { teardown() }
    }
}
