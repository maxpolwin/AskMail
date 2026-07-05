import SQLite3
import XCTest
@testable import AskMailCore

/// Account discovery over a synthetic ~/Library/Mail/V10 tree: directory
/// enumeration is the source of truth, the Internet Accounts database
/// (ZACCOUNT table) supplies friendly labels.
final class MailAccountsTests: XCTestCase {
    private let uuidA = "AAAAAAAA-1111-2222-3333-444444444444"
    private let uuidB = "BBBBBBBB-1111-2222-3333-444444444444"
    private let uuidC = "CCCCCCCC-1111-2222-3333-444444444444"

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("askmail-mailroot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeAccountDir(_ id: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(id, isDirectory: true),
            withIntermediateDirectories: true)
    }

    /// Drops a single dummy `.emlx` into an account directory, simulating a
    /// mailbox that actually holds a message.
    private func writeDummyMessage(accountID: String, rowID: Int64 = 1) throws {
        let messages = root.appendingPathComponent(accountID, isDirectory: true)
            .appendingPathComponent("Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        try Data("dummy".utf8).write(to: messages.appendingPathComponent("\(rowID).emlx"))
    }

    /// Builds a synthetic Accounts4.sqlite with just the columns AskMail reads,
    /// mirroring the real ZACCOUNT schema observed on a live macOS 15 install.
    private func writeAccountsDatabase(_ rows: [(id: String, description: String?, username: String?)]) throws -> URL {
        let url = root.appendingPathComponent("Accounts4.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE ZACCOUNT(ZIDENTIFIER TEXT, ZACCOUNTDESCRIPTION TEXT, ZUSERNAME TEXT);
            """, nil, nil, nil), SQLITE_OK)
        for row in rows {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO ZACCOUNT VALUES (?, ?, ?)", -1, &statement, nil)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, row.id, -1, transient)
            if let description = row.description {
                sqlite3_bind_text(statement, 2, description, -1, transient)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            if let username = row.username {
                sqlite3_bind_text(statement, 3, username, -1, transient)
            } else {
                sqlite3_bind_null(statement, 3)
            }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        return url
    }

    // Database enriches each directory; results sort by label; MailData is
    // never treated as an account.
    func testEnrichesAndSortsAccounts() throws {
        try makeAccountDir(uuidA)
        try makeAccountDir(uuidB)
        let database = try writeAccountsDatabase([
            (uuidA, "Personal", "alice@example.com"),
            (uuidB, "Work", "bob@work.example"),
        ])

        let accounts = MailAccountsReader.list(mailRoot: root, accountsDatabase: database)

        XCTAssertEqual(accounts.map(\.id), [uuidA, uuidB], "sorted by label: alice < bob")
        XCTAssertFalse(accounts.contains { $0.id == "MailData" }, "MailData is not an account")

        let personal = try XCTUnwrap(accounts.first { $0.id == uuidA })
        XCTAssertEqual(personal.email, "alice@example.com")
        XCTAssertEqual(personal.displayName, "Personal")
        XCTAssertEqual(personal.label, "alice@example.com", "email alone is the label, not the name")
        XCTAssertEqual(personal.storageKey, "alice@example.com")
        // resolvingSymlinksInPath: enumeration canonicalises /var -> /private/var.
        XCTAssertEqual(personal.directory.resolvingSymlinksInPath(),
                       root.appendingPathComponent(uuidA, isDirectory: true).resolvingSymlinksInPath())

        let work = try XCTUnwrap(accounts.first { $0.id == uuidB })
        XCTAssertEqual(work.email, "bob@work.example")
    }

    // A ZUSERNAME that isn't an email address (e.g. "local", the "On My Mac"
    // account) never surfaces as the email. Needs a message on disk, else the
    // email-less/message-less filter below would hide it entirely.
    func testNonEmailUsernameIsIgnored() throws {
        try makeAccountDir(uuidA)
        try writeDummyMessage(accountID: uuidA)
        let database = try writeAccountsDatabase([
            (uuidA, "On My Mac", "local"),
        ])

        let accounts = MailAccountsReader.list(mailRoot: root, accountsDatabase: database)

        let onMyMac = try XCTUnwrap(accounts.first { $0.id == uuidA })
        XCTAssertEqual(onMyMac.email, "")
        XCTAssertEqual(onMyMac.displayName, "On My Mac")
    }

    // A directory with no database row still lists, labelled by its id, as
    // long as it actually holds a message.
    func testUnmatchedDirectoryDegradesToId() throws {
        try makeAccountDir(uuidC)
        try writeDummyMessage(accountID: uuidC)
        let database = try writeAccountsDatabase([
            (uuidA, "Personal", "alice@example.com"),
        ])

        let accounts = MailAccountsReader.list(mailRoot: root, accountsDatabase: database)

        XCTAssertEqual(accounts.map(\.id), [uuidC])
        let only = try XCTUnwrap(accounts.first)
        XCTAssertEqual(only.email, "")
        XCTAssertEqual(only.displayName, "")
        XCTAssertEqual(only.label, uuidC, "no name or email -> label is the directory id")
        XCTAssertEqual(only.storageKey, uuidC, "no email -> storage key is the directory id")
    }

    // Missing database: accounts with actual messages are still discovered
    // from directories alone.
    func testMissingDatabaseStillListsDirectories() throws {
        try makeAccountDir(uuidA)
        try writeDummyMessage(accountID: uuidA)
        try makeAccountDir(uuidB)
        try writeDummyMessage(accountID: uuidB)
        let missing = root.appendingPathComponent("does-not-exist.sqlite")

        let accounts = MailAccountsReader.list(mailRoot: root, accountsDatabase: missing)

        XCTAssertEqual(Set(accounts.map(\.id)), [uuidA, uuidB])
        XCTAssertTrue(accounts.allSatisfy { $0.email.isEmpty && $0.displayName.isEmpty })
    }

    // An email-less pseudo-account with no messages at all (the common "On My
    // Mac" case) is hidden from the picker entirely rather than shown as a
    // dead-end selection.
    func testEmptyEmaillessAccountIsExcluded() throws {
        try makeAccountDir(uuidA)
        let database = try writeAccountsDatabase([
            (uuidA, "On My Mac", nil),
        ])

        let accounts = MailAccountsReader.list(mailRoot: root, accountsDatabase: database)

        XCTAssertTrue(accounts.isEmpty, "empty, email-less accounts are excluded")
    }

    // The rare case where the user actually filed real mail into "On My Mac":
    // it reappears because it now holds a message.
    func testEmaillessAccountReappearsOnceItHasMessages() throws {
        try makeAccountDir(uuidA)
        try writeDummyMessage(accountID: uuidA)
        let database = try writeAccountsDatabase([
            (uuidA, "On My Mac", nil),
        ])

        let accounts = MailAccountsReader.list(mailRoot: root, accountsDatabase: database)

        XCTAssertEqual(accounts.map(\.id), [uuidA])
    }

    // A real account (has an email) is never hidden for being empty — it may
    // simply be mid-first-sync, not a dead pseudo-account.
    func testEmailedAccountIncludedEvenWithoutMessagesYet() throws {
        try makeAccountDir(uuidA)
        let database = try writeAccountsDatabase([
            (uuidA, "Personal", "alice@example.com"),
        ])

        let accounts = MailAccountsReader.list(mailRoot: root, accountsDatabase: database)

        XCTAssertEqual(accounts.map(\.id), [uuidA])
    }

    // Missing mail root is not an error: empty list, no throw.
    func testMissingMailRootReturnsEmpty() {
        let absent = root.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertEqual(MailAccountsReader.list(mailRoot: absent,
                                               accountsDatabase: absent).count, 0)
    }

    // A readable root reports .ok, even alongside real accounts.
    func testDiscoverReportsOkWhenReadable() throws {
        try makeAccountDir(uuidA)
        let database = try writeAccountsDatabase([
            (uuidA, "Personal", "alice@example.com"),
        ])

        let discovery = MailAccountsReader.discover(mailRoot: root, accountsDatabase: database)

        XCTAssertEqual(discovery.status, .ok)
        XCTAssertEqual(discovery.accounts.map(\.id), [uuidA])
    }

    // A missing root is "not set up", not a permission problem.
    func testDiscoverReportsNotFoundForMissingRoot() {
        let absent = root.appendingPathComponent("does-not-exist", isDirectory: true)
        let discovery = MailAccountsReader.discover(mailRoot: absent, accountsDatabase: absent)
        XCTAssertEqual(discovery.status, .notFound)
        XCTAssertTrue(discovery.accounts.isEmpty)
    }

    // An unreadable root (the Full Disk Access case) is reported distinctly so
    // the UI can point the user at System Settings. Root bypasses file perms, so
    // skip there.
    func testDiscoverReportsPermissionDeniedForUnreadableRoot() throws {
        try XCTSkipIf(geteuid() == 0, "chmod-based permission block is bypassed by root")
        try makeAccountDir(uuidA)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }

        let discovery = MailAccountsReader.discover(
            mailRoot: root, accountsDatabase: root.appendingPathComponent("Accounts4.sqlite"))

        XCTAssertEqual(discovery.status, .permissionDenied)
        XCTAssertTrue(discovery.accounts.isEmpty)
    }

    // Version resolution picks the newest V<n> and ignores non-version entries.
    func testResolvesNewestMailVersionDirectory() throws {
        let fm = FileManager.default
        for name in ["V9", "V10", "V11", "MailData", "Vault"] {
            try fm.createDirectory(at: root.appendingPathComponent(name, isDirectory: true),
                                   withIntermediateDirectories: true)
        }
        XCTAssertEqual(Defaults.resolveMailRoot(container: root).lastPathComponent, "V11")
    }

    // With no version directories (or an unreadable/absent container), fall back
    // to V10 so derived paths stay well-formed.
    func testResolveMailRootFallsBackToV10() {
        XCTAssertEqual(Defaults.resolveMailRoot(container: root).lastPathComponent, "V10")
        let absent = root.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(Defaults.resolveMailRoot(container: absent).lastPathComponent, "V10")
    }
}
