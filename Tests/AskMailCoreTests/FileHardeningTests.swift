import XCTest
@testable import AskMailCore

/// Verifies `FileHardening.lockDown` actually locks down real on-disk
/// database files — exercised here via `SQLiteStore.init`/`DraftStore.init`
/// (both call it), rather than testing the helper in isolation, since what
/// matters is that opening either store produces a hardened file (closing
/// H-18 for `askmail.db` as a side effect of building it for `drafts.db`).
final class FileHardeningTests: XCTestCase {

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("askmail-hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func permissions(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testSQLiteStoreLocksDownAskmailDB() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("askmail.db").path

        _ = try SQLiteStore(path: path)

        XCTAssertEqual(try permissions(path), 0o600)
        XCTAssertEqual(try permissions(dir.path), 0o700)
        let resourceValues = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(resourceValues.isExcludedFromBackup, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".metadata_never_index").path))
    }

    func testDraftStoreLocksDownDraftsDB() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("drafts.db").path

        _ = try DraftStore(path: path)

        XCTAssertEqual(try permissions(path), 0o600)
        XCTAssertEqual(try permissions(dir.path), 0o700)
        let resourceValues = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(resourceValues.isExcludedFromBackup, true)
    }

    func testInMemoryStoresSkipFileHardening() throws {
        // ":memory:" has no real file to lock down -- must not attempt it
        // (chmod/setResourceValues on a literal path named ":memory:" would
        // either fail or, worse, silently create a bogus file).
        XCTAssertNoThrow(try SQLiteStore.inMemory())
        XCTAssertNoThrow(try DraftStore.inMemory())
    }
}
