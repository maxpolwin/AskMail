import XCTest
@testable import AskMailApp

/// H-20: `OllamaEngine.startOllama()` must refuse to spawn an untrusted
/// `ollama` binary. `launchRefusalReason(for:isTrusted:)` isolates that
/// decision from the actual `Process.run()` call, so it's testable with an
/// injected trust check instead of a real Security-framework probe or a
/// spawned daemon.
final class OllamaEngineLaunchTests: XCTestCase {

    func testTrustedBinaryIsNotRefused() {
        let cli = URL(fileURLWithPath: "/opt/homebrew/bin/ollama")
        let refusal = OllamaEngine.launchRefusalReason(for: cli, isTrusted: { _ in true })
        XCTAssertNil(refusal)
    }

    func testUntrustedBinaryIsRefusedWithActionableMessage() throws {
        let cli = URL(fileURLWithPath: "/usr/local/bin/ollama")
        let refusal = OllamaEngine.launchRefusalReason(for: cli, isTrusted: { _ in false })

        XCTAssertNotNil(refusal)
        let message = try XCTUnwrap(refusal)
        XCTAssertTrue(message.contains(cli.path), "message should name the offending path")
        XCTAssertTrue(message.lowercased().contains("signature"),
                      "message should say what failed")
        XCTAssertTrue(message.contains("ollama.com") || message.lowercased().contains("brew"),
                      "message should tell the user how to fix it")
    }

    func testDefaultTrustCheckUsesBinarySignature() {
        // No injected closure: exercises the real default (BinarySignature)
        // wiring end to end against a binary that is genuinely trusted.
        let refusal = OllamaEngine.launchRefusalReason(for: URL(fileURLWithPath: "/bin/ls"))
        XCTAssertNil(refusal)
    }
}
