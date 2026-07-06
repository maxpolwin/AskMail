import XCTest
@testable import AskMailCore

// Hardening H-14: LinkPolicy is the single gate every answer-link sink
// (rendered Markdown link, citation button) routes through, so a
// prompt-injected email can't turn model output into a silently-followed
// arbitrary-scheme link. These cases are exactly what an indirect-
// prompt-injection attempt would try.
final class LinkPolicyTests: XCTestCase {

    func testMessageSchemeOpensImmediately() {
        let url = URL(string: "message://%3Cabc%40x%3E")!
        XCTAssertEqual(LinkPolicy.action(for: url), .open)
    }

    func testHttpsRequiresConfirmation() {
        XCTAssertEqual(LinkPolicy.action(for: URL(string: "https://example.com")!), .confirmThenOpen)
    }

    func testHttpRequiresConfirmation() {
        XCTAssertEqual(LinkPolicy.action(for: URL(string: "http://example.com")!), .confirmThenOpen)
    }

    func testJavascriptSchemeIsBlocked() {
        XCTAssertEqual(LinkPolicy.action(for: URL(string: "javascript:alert(1)")!), .block)
    }

    func testFileSchemeIsBlocked() {
        XCTAssertEqual(LinkPolicy.action(for: URL(string: "file:///etc/passwd")!), .block)
    }

    func testDataSchemeIsBlocked() {
        XCTAssertEqual(LinkPolicy.action(for: URL(string: "data:text/html,<script>1</script>")!), .block)
    }

    func testArbitraryCustomSchemeIsBlocked() {
        XCTAssertEqual(LinkPolicy.action(for: URL(string: "askmail-evil://exfiltrate")!), .block)
    }

    func testSchemeMatchIsCaseInsensitive() {
        XCTAssertEqual(LinkPolicy.action(for: URL(string: "MESSAGE://%3Cabc%3E")!), .open)
        XCTAssertEqual(LinkPolicy.action(for: URL(string: "HTTPS://example.com")!), .confirmThenOpen)
    }
}
