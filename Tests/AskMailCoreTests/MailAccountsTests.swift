import XCTest
@testable import AskMailCore

/// Account discovery over a synthetic ~/Library/Mail/V10 tree: directory
/// enumeration is the source of truth, Accounts.plist supplies friendly labels.
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

    private func writeAccountsPlist(_ accounts: [[String: Any]]) throws -> URL {
        let mailData = root.appendingPathComponent("MailData", isDirectory: true)
        try FileManager.default.createDirectory(at: mailData, withIntermediateDirectories: true)
        let url = mailData.appendingPathComponent("Accounts.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["MailAccounts": accounts], format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    // Plist enriches each directory; EmailAddresses vs Username both resolve;
    // results sort by label; MailData is never treated as an account.
    func testEnrichesAndSortsAccounts() throws {
        try makeAccountDir(uuidA)
        try makeAccountDir(uuidB)
        let plist = try writeAccountsPlist([
            ["UniqueId": uuidA, "AccountName": "Personal", "EmailAddresses": ["alice@example.com"]],
            ["UniqueId": uuidB, "AccountName": "Work", "Username": "bob@work.example"],
        ])

        let accounts = MailAccountsReader.list(mailRoot: root, accountsPlist: plist)

        XCTAssertEqual(accounts.map(\.id), [uuidA, uuidB], "sorted by label: Personal < Work")
        XCTAssertFalse(accounts.contains { $0.id == "MailData" }, "MailData is not an account")

        let personal = try XCTUnwrap(accounts.first { $0.id == uuidA })
        XCTAssertEqual(personal.email, "alice@example.com")
        XCTAssertEqual(personal.displayName, "Personal")
        XCTAssertEqual(personal.label, "Personal (alice@example.com)")
        XCTAssertEqual(personal.storageKey, "alice@example.com")
        // resolvingSymlinksInPath: enumeration canonicalises /var -> /private/var.
        XCTAssertEqual(personal.directory.resolvingSymlinksInPath(),
                       root.appendingPathComponent(uuidA, isDirectory: true).resolvingSymlinksInPath())

        let work = try XCTUnwrap(accounts.first { $0.id == uuidB })
        XCTAssertEqual(work.email, "bob@work.example", "Username falls back to email when it looks like one")
    }

    // A directory with no plist entry still lists, labelled by its id.
    func testUnmatchedDirectoryDegradesToId() throws {
        try makeAccountDir(uuidC)
        let plist = try writeAccountsPlist([
            ["UniqueId": uuidA, "AccountName": "Personal", "EmailAddresses": ["alice@example.com"]],
        ])

        let accounts = MailAccountsReader.list(mailRoot: root, accountsPlist: plist)

        XCTAssertEqual(accounts.map(\.id), [uuidC])
        let only = try XCTUnwrap(accounts.first)
        XCTAssertEqual(only.email, "")
        XCTAssertEqual(only.displayName, "")
        XCTAssertEqual(only.label, uuidC, "no name or email -> label is the directory id")
        XCTAssertEqual(only.storageKey, uuidC, "no email -> storage key is the directory id")
    }

    // Missing plist: accounts still discovered from directories alone.
    func testMissingPlistStillListsDirectories() throws {
        try makeAccountDir(uuidA)
        try makeAccountDir(uuidB)
        let missing = root.appendingPathComponent("MailData/Accounts.plist")

        let accounts = MailAccountsReader.list(mailRoot: root, accountsPlist: missing)

        XCTAssertEqual(Set(accounts.map(\.id)), [uuidA, uuidB])
        XCTAssertTrue(accounts.allSatisfy { $0.email.isEmpty && $0.displayName.isEmpty })
    }

    // Missing mail root is not an error: empty list, no throw.
    func testMissingMailRootReturnsEmpty() {
        let absent = root.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertEqual(MailAccountsReader.list(mailRoot: absent,
                                               accountsPlist: absent).count, 0)
    }
}
