import Foundation

/// Locks down a local SQLite database file so it's no more exposed than the
/// mailbox content it mirrors (hardening H-18): owner-only file permissions,
/// excluded from Time Machine, excluded from Spotlight indexing. Applied to
/// both `askmail.db` and the separate `drafts.db`.
public enum FileHardening {

    /// `fileURL` need not exist yet; existing `-wal`/`-shm` siblings (if any)
    /// are locked down too since SQLite's WAL mode can leave mailbox content
    /// in them between checkpoints.
    public static func lockDown(fileURL: URL) {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()

        chmod(directory.path, 0o700)
        for suffix in ["", "-wal", "-shm"] {
            let path = fileURL.path + suffix
            guard fileManager.fileExists(atPath: path) else { continue }
            chmod(path, 0o600)
            excludeFromBackup(path: path)
        }

        // Spotlight/mdworker skips indexing anything inside a directory that
        // contains this empty marker file — the standard per-directory
        // exclusion mechanism (no running `mdutil` call needed, and no
        // per-file equivalent exists). One marker covers every file this
        // directory ever holds (askmail.db and/or drafts.db).
        let marker = directory.appendingPathComponent(".metadata_never_index")
        if !fileManager.fileExists(atPath: marker.path) {
            fileManager.createFile(atPath: marker.path, contents: nil)
        }
    }

    private static func excludeFromBackup(path: String) {
        var url = URL(fileURLWithPath: path)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? url.setResourceValues(resourceValues)
    }
}
