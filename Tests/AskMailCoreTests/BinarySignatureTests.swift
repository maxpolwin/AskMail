import XCTest
@testable import AskMailCore

/// `BinarySignature.isTrusted` gates spawning the `ollama` CLI (H-20): an
/// Apple-signed or Developer-ID-signed binary is trusted, everything else —
/// missing file, unsigned, ad-hoc-signed — is refused.
final class BinarySignatureTests: XCTestCase {

    func testAppleSignedSystemBinaryIsTrusted() {
        // /bin/ls ships signed by Apple on every macOS install.
        XCTAssertTrue(BinarySignature.isTrusted(url: URL(fileURLWithPath: "/bin/ls")))
    }

    func testMissingFileIsNotTrusted() {
        let missing = URL(fileURLWithPath: "/nonexistent/path/\(UUID().uuidString)/ollama")
        XCTAssertFalse(BinarySignature.isTrusted(url: missing))
    }

    func testUnsignedShellScriptIsNotTrusted() throws {
        // A plain shell script has no embedded code signature at all —
        // exactly the shape of a planted binary dropped into an
        // admin-writable directory like /usr/local/bin.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("askmail-binarysig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = dir.appendingPathComponent("ollama")
        try "#!/bin/sh\necho pwned\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        XCTAssertFalse(BinarySignature.isTrusted(url: script))
    }

    func testAdHocSignedCopyOfSignedBinaryIsNotTrusted() throws {
        // Copy a real Apple-signed Mach-O and strip/replace its signature
        // with an ad-hoc one (no identity) -- simulates a locally-built or
        // re-signed impostor sitting at the expected install path.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("askmail-binarysig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let copy = dir.appendingPathComponent("ollama")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: copy)

        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", copy.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else {
            throw XCTSkip("codesign unavailable in this environment; can't ad-hoc sign the fixture")
        }

        XCTAssertFalse(BinarySignature.isTrusted(url: copy))
    }
}
