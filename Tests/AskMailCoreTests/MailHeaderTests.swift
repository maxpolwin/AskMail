import XCTest
@testable import AskMailCore

/// Locks RFC 2047 header decoding and From-domain extraction used by the
/// source list.
final class MailHeaderTests: XCTestCase {

    func testDecodesQuotedPrintableWord() {
        XCTAssertEqual(
            MailHeader.decode("=?UTF-8?Q?Monthly_report_=E2=80=93_June_2026?="),
            "Monthly report \u{2013} June 2026")
    }

    func testDecodesBase64Word() {
        // "Grüße" in UTF-8, base64.
        XCTAssertEqual(MailHeader.decode("=?UTF-8?B?R3LDvMOfZQ==?="), "Grüße")
    }

    func testFoldsAdjacentEncodedWords() {
        let input = "=?utf-8?Q?Germany=E2=80=99s?= =?utf-8?Q?_waning?="
        XCTAssertEqual(MailHeader.decode(input), "Germany\u{2019}s waning")
    }

    func testPlainTextPassesThrough() {
        XCTAssertEqual(MailHeader.decode("Plain subject, no encoding"),
                       "Plain subject, no encoding")
    }

    func testIsoLatin1Charset() {
        // "Grün" in ISO-8859-1: ü = 0xFC.
        XCTAssertEqual(MailHeader.decode("=?ISO-8859-1?Q?Gr=FCn?="), "Grün")
    }

    func testDomainFromAngleAddress() {
        XCTAssertEqual(
            MailHeader.domain(fromSender: "Bundesbank Newsletter <noreply@newsletter.bundesbank.de>"),
            "bundesbank")
    }

    func testDomainFromBareAddress() {
        XCTAssertEqual(MailHeader.domain(fromSender: "mailservice@oenb.at"), "oenb")
    }

    func testDomainFallsBackToDisplayNameWhenNoAddress() {
        XCTAssertEqual(MailHeader.domain(fromSender: "Internal Memo"), "Internal Memo")
    }

    func testAddressFromAngleAddressIsLowercased() {
        XCTAssertEqual(MailHeader.address(fromSender: "Alice Smith <Alice@Example.COM>"), "alice@example.com")
    }

    func testAddressFromBareAddress() {
        XCTAssertEqual(MailHeader.address(fromSender: "mailservice@oenb.at"), "mailservice@oenb.at")
    }

    func testAddressIsNilWhenNoAddressPresent() {
        XCTAssertNil(MailHeader.address(fromSender: "Internal Memo"))
    }

    func testAddressRecoversFromUnmatchedAngleBracket() {
        // No closing ">" -- must not fall back to the whole raw string
        // (which would include the display name and the stray "<").
        XCTAssertEqual(MailHeader.address(fromSender: "John <john@example.com"), "john@example.com")
    }
}
