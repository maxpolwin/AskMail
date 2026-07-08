import XCTest
@testable import AskMailCore

/// Hardening H-10/H-13: the compiled-in egress allowlist and the
/// provider-error redaction that keeps a cloud 4xx body from reaching a log
/// line or a UI-facing "\(error)" interpolation unbounded.
final class EgressPolicyTests: XCTestCase {

    // MARK: H-10 allowlist

    func testLoopbackHostsAllowed() throws {
        try EgressPolicy.check(URL(string: "http://localhost:11434/api/chat")!)
        try EgressPolicy.check(URL(string: "http://127.0.0.1:11434/api/chat")!)
        try EgressPolicy.check(URL(string: "http://[::1]:11434/api/chat")!)
    }

    func testAllowlistedCloudHostsAllowed() throws {
        try EgressPolicy.check(URL(string: "https://ollama.com/api/chat")!)
        try EgressPolicy.check(URL(string: "https://api.mistral.ai/v1/chat/completions")!)
    }

    // A non-allowlisted host is refused before any bytes are sent — `check`
    // is a pure function of the URL, so reaching this assertion at all
    // already proves no network I/O occurred.
    func testNonAllowlistedHostBlocked() {
        XCTAssertThrowsError(try EgressPolicy.check(URL(string: "https://evil.tld/api/chat")!)) { error in
            guard case ProviderError.egressBlocked(let host) = error else {
                return XCTFail("expected egressBlocked, got \(error)")
            }
            XCTAssertEqual(host, "evil.tld")
        }
    }

    // A user pointing the (configurable) Ollama host at a LAN address must
    // also be refused, not just public internet hosts.
    func testLANHostBlocked() {
        XCTAssertThrowsError(try EgressPolicy.check(URL(string: "http://192.168.1.50:11434/api/chat")!)) { error in
            guard case ProviderError.egressBlocked(let host) = error else {
                return XCTFail("expected egressBlocked, got \(error)")
            }
            XCTAssertEqual(host, "192.168.1.50")
        }
    }

    // MARK: OllamaEmbedder is stricter (loopback-only)

    func testCheckLoopbackOnlyAllowsLoopback() throws {
        try EgressPolicy.checkLoopbackOnly(URL(string: "http://localhost:11434/api/embed")!)
    }

    // Stricter than the general allowlist: even ollama.com, otherwise
    // allowlisted for chat, is refused for embeddings — mailbox embeddings
    // must never leave the device (SECURITY.md).
    func testCheckLoopbackOnlyRejectsAllowlistedCloudHost() {
        XCTAssertThrowsError(try EgressPolicy.checkLoopbackOnly(URL(string: "https://ollama.com/api/embed")!))
    }

    func testEmbedderRefusesNonLoopbackHostBeforeAnyNetworkIO() async {
        let embedder = OllamaEmbedder(host: URL(string: "https://ollama.com")!)
        do {
            _ = try await embedder.embed(["hello"])
            XCTFail("expected egressBlocked before any network I/O")
        } catch ProviderError.egressBlocked(let host) {
            XCTAssertEqual(host, "ollama.com")
        } catch {
            XCTFail("expected egressBlocked, got \(error)")
        }
    }

    // MARK: H-13 error-body redaction

    func testHTTPErrorDescriptionIsCappedAndSingleLine() {
        let body = Array(repeating: "line with some prompt content\n", count: 200).joined()
        XCTAssertGreaterThan(body.count, 5000)
        let error = ProviderError.http(status: 400, body: body)
        let printed = "\(error)"

        XCTAssertLessThanOrEqual(printed.count, 350, printed)
        XCTAssertFalse(printed.contains("\n"), "the printed form must collapse to one line")
        XCTAssertTrue(printed.hasPrefix("HTTP 400: "))
        XCTAssertTrue(printed.hasSuffix("[truncated]"))
    }

    // The full body must still be reachable programmatically (e.g. for
    // isOllamaModelMissing's substring check) — only the *printed* form is bounded.
    func testHTTPErrorAssociatedValueKeepsFullBody() {
        let body = String(repeating: "x", count: 5000)
        guard case ProviderError.http(_, let storedBody) = ProviderError.http(status: 500, body: body) else {
            return XCTFail("expected .http")
        }
        XCTAssertEqual(storedBody.count, 5000)
    }

    func testShortSingleLineBodyIsUnchanged() {
        let error = ProviderError.http(status: 404, body: "model not found")
        XCTAssertEqual("\(error)", "HTTP 404: model not found")
    }
}
