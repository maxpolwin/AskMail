import XCTest
@testable import AskMailCore

/// Hardening H-7/H-8/H-9 (docs/hardening.md): size caps enforced before
/// read/decode, MIME recursion depth limit, and bounded regex passes over
/// attacker-controlled HTML. All adversarial inputs here are built at test
/// time (string concatenation), never committed as fixture files.
final class ParserHardeningTests: XCTestCase {

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("askmail-parser-hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds the on-disk `.emlx` byte shape (byte-count line + raw RFC 5322
    /// message) that `EmlxParser.parse` expects, mirroring
    /// DraftPipelineIntegrationTests' helper.
    func emlxData(_ message: String) -> Data {
        let messageData = Data(message.utf8)
        return Data("\(messageData.count)\n".utf8) + messageData
    }

    // MARK: H-7 — size caps before read / before decode

    // The size guard must fire from FileManager attributes, before
    // Data(contentsOf:) is ever called — proven here by injecting a tiny
    // cap against a file whose *content* isn't even a valid .emlx. If the
    // guard didn't run first, parsing would fail with a content error
    // ("no byte-count line"), not a size error.
    func testOversizeEmlxFileRejectedBeforeItIsRead() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("oversize.emlx")
        try Data("this content is longer than five bytes".utf8).write(to: path)

        XCTAssertThrowsError(try EmlxParser.parse(fileURL: path, maxEmlxBytes: 5)) { error in
            guard case EmlxParseError.malformed(let reason) = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
            XCTAssertTrue(reason.contains("exceeds max"), "expected a size-cap error, got: \(reason)")
        }
    }

    // A file within the injected cap parses normally -- the guard doesn't
    // over-reject.
    func testFileWithinCapStillParses() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("ok.emlx")
        let message = """
        From: a@example.com
        To: b@example.com
        Subject: fine
        Date: Mon, 02 Mar 2026 09:00:00 +0100
        Message-ID: <ok@example.com>
        Content-Type: text/plain; charset=utf-8

        hello world
        """
        try emlxData(message).write(to: path)

        let email = try EmlxParser.parse(fileURL: path, maxEmlxBytes: 10_000)
        XCTAssertEqual(email.messageID, "ok@example.com")
        XCTAssertTrue(email.bodyText.contains("hello world"))
    }

    // Mime.Part.maxDecodedByteEstimate is the pre-decode bound the H-7
    // attachment guard relies on: base64 decodes to <= encoded * 3/4,
    // quoted-printable and identity decode to <= encoded size.
    func testMaxDecodedByteEstimateBoundsPerEncoding() {
        let base64Part = Mime.Part(
            headers: [("Content-Transfer-Encoding", "base64")],
            rawBody: String(repeating: "A", count: 100))
        XCTAssertEqual(base64Part.maxDecodedByteEstimate, 75)

        let qpPart = Mime.Part(
            headers: [("Content-Transfer-Encoding", "quoted-printable")],
            rawBody: String(repeating: "A", count: 100))
        XCTAssertEqual(qpPart.maxDecodedByteEstimate, 100)

        let identityPart = Mime.Part(headers: [], rawBody: String(repeating: "A", count: 100))
        XCTAssertEqual(identityPart.maxDecodedByteEstimate, 100)
    }

    // The defining behavior of "before decode": an attachment whose base64
    // body is syntactically invalid (so decoding it yields empty Data, via
    // the `?? Data()` fallback in Mime.Part.decodedBody) is still rejected
    // and recorded in `skippedAttachments`, purely on its encoded length.
    // A post-decode-only check would see decodedBody.count == 0 (never
    // > cap) and silently drop the attachment with no record at all --
    // that would prove the check ran after a (failed) decode, not before.
    func testAttachmentCapEnforcedOnEncodedSizeBeforeDecodeSucceedsOrFails() throws {
        let garbageEncoded = String(repeating: "!", count: 2000)  // not valid base64 alphabet
        let message = """
        From: a@example.com
        To: b@example.com
        Subject: bomb
        Date: Mon, 02 Mar 2026 09:00:00 +0100
        Message-ID: <bomb@example.com>
        Content-Type: multipart/mixed; boundary=BOUNDARY

        --BOUNDARY
        Content-Type: application/pdf
        Content-Disposition: attachment; filename="bomb.pdf"
        Content-Transfer-Encoding: base64

        \(garbageEncoded)
        --BOUNDARY--
        """
        let parsed = try EmlxParser.parse(data: emlxData(message), maxAttachmentBytes: 100)
        XCTAssertTrue(parsed.pdfAttachments.isEmpty)
        XCTAssertEqual(parsed.skippedAttachments, ["bomb.pdf"],
                       "an oversize-encoded attachment must be recorded as skipped even when it would decode to nothing")
    }

    // A legitimately-sized (valid, decodable) base64 PDF attachment within
    // the cap still makes it through -- the pre-decode guard doesn't
    // over-reject real attachments.
    func testValidAttachmentWithinCapIsKept() throws {
        let payload = Data(repeating: 0x41, count: 60)  // "AAAA..." -- well under any cap
        let encoded = payload.base64EncodedString()
        let message = """
        From: a@example.com
        To: b@example.com
        Subject: attachment
        Date: Mon, 02 Mar 2026 09:00:00 +0100
        Message-ID: <ok-attach@example.com>
        Content-Type: multipart/mixed; boundary=BOUNDARY

        --BOUNDARY
        Content-Type: application/pdf
        Content-Disposition: attachment; filename="ok.pdf"
        Content-Transfer-Encoding: base64

        \(encoded)
        --BOUNDARY--
        """
        let parsed = try EmlxParser.parse(data: emlxData(message), maxAttachmentBytes: 1000)
        XCTAssertTrue(parsed.skippedAttachments.isEmpty)
        XCTAssertEqual(parsed.pdfAttachments.first?.data.count, 60)
    }

    // MARK: H-8 — MIME recursion depth limit

    /// Builds a "header\n\nbody" block for a part nested `depth` levels of
    /// `multipart/mixed`, bottoming out in a `text/plain` leaf. Each level
    /// gets a distinct boundary name so nested boundaries never collide.
    private func nestedPart(depth: Int, leaf: String) -> String {
        if depth == 0 {
            return "Content-Type: text/plain\n\n\(leaf)"
        }
        let boundary = "B\(depth)"
        let inner = nestedPart(depth: depth - 1, leaf: leaf)
        return "Content-Type: multipart/mixed; boundary=\(boundary)\n\n--\(boundary)\n\(inner)\n--\(boundary)--"
    }

    /// Wraps `nestedPart(depth:)`'s block into a full RFC 5322 message: its
    /// first line is the Content-Type header (merged with the standard
    /// headers), everything after the first blank line is the body.
    private func nestedMultipartMessage(depth: Int, leaf: String = "leaf text") -> String {
        let block = nestedPart(depth: depth, leaf: leaf)
        let blankRange = block.range(of: "\n\n")!
        let contentTypeHeader = String(block[..<blankRange.lowerBound])
        let body = String(block[blankRange.upperBound...])
        return """
        From: a@example.com
        To: b@example.com
        Subject: deep nesting
        Date: Mon, 02 Mar 2026 09:00:00 +0100
        Message-ID: <deep@example.com>
        \(contentTypeHeader)

        \(body)
        """
    }

    // A 64-deep nested multipart tree (well past the default 32-deep cap)
    // fails closed with a parse error instead of recursing unboundedly.
    func testDeeplyNestedMultipartExceedsDefaultDepthLimit() throws {
        let message = nestedMultipartMessage(depth: 64)

        XCTAssertThrowsError(try EmlxParser.parse(data: emlxData(message))) { error in
            guard case EmlxParseError.malformed(let reason) = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
            XCTAssertTrue(reason.lowercased().contains("depth"), "expected a depth-limit error, got: \(reason)")
        }
    }

    // Exact boundary check with an injected cap: nesting exactly at the
    // cap succeeds and still recovers the leaf text; one level less than
    // the actual nesting fails.
    func testMimeDepthLimitBoundaryIsInclusive() throws {
        let message = nestedMultipartMessage(depth: 3)

        let ok = try EmlxParser.parse(data: emlxData(message), maxMimeDepth: 3)
        XCTAssertTrue(ok.bodyText.contains("leaf text"))

        XCTAssertThrowsError(try EmlxParser.parse(data: emlxData(message), maxMimeDepth: 2))
    }

    // MARK: H-9 — bounded HTML regex passes

    // Input beyond Defaults.maxHtmlBytes is truncated before any regex
    // pass runs: content past the cap never surfaces in the output, while
    // content within the cap (the "head" of a giant newsletter) still
    // does.
    func testHtmlBeyondCapIsTruncatedNotRejected() {
        let head = "<p>HEAD_MARKER stays</p>"
        let filler = String(repeating: "x", count: Defaults.maxHtmlBytes)
        let tail = "<p>TAIL_MARKER_SHOULD_BE_GONE</p>"
        let html = head + filler + tail

        let text = HtmlText.plainText(html: html)
        XCTAssertTrue(text.contains("HEAD_MARKER"))
        XCTAssertFalse(text.contains("TAIL_MARKER_SHOULD_BE_GONE"),
                       "content beyond the byte cap must be truncated away, not processed")
    }

    func testTruncatedHelperCutsOnUtf8ByteBoundary() {
        // "é" is 2 UTF-8 bytes; cutting mid-scalar must not crash and must
        // not exceed the byte cap.
        let html = String(repeating: "é", count: 10)  // 20 bytes
        let truncated = HtmlText.truncated(html, maxBytes: 5)
        XCTAssertLessThanOrEqual(truncated.utf8.count, 5)
    }

    // Adversarial: tens of thousands of unmatched `<` characters. Before
    // the H-9 fix (`[^>]+` -> `[^<>]+` in the catch-all tag stripper) this
    // pattern re-scanned to the end of the string on every `<`, an O(n^2)
    // blowup. Measured with ContinuousClock against a generous budget.
    func testAdversarialAngleBracketRunCompletesUnderTimeBudget() {
        let adversarial = String(repeating: "<", count: 50_000) + " TAIL_MARKER"
        let clock = ContinuousClock()
        let start = clock.now
        let result = HtmlText.plainText(html: adversarial)
        let elapsed = clock.now - start

        XCTAssertLessThan(elapsed, .seconds(5), "unmatched '<' run must not cause quadratic blowup")
        XCTAssertTrue(result.contains("TAIL_MARKER"))
    }

    // Adversarial: many repeated *unclosed* `<script>` openers. Before the
    // H-9 fix (lookahead-bounded interior in the block-stripping patterns)
    // every occurrence restarted a full scan to the end of the string
    // hunting for a `</script>` that never appears -- O(n * k) for k
    // occurrences, confirmed experimentally to take >2s at just 5,000
    // repeats pre-fix. This exercises exactly that shape at a much larger
    // scale.
    func testAdversarialUnclosedScriptTagRunCompletesUnderTimeBudget() {
        let adversarial = String(repeating: "<script>", count: 20_000) + "<p>TAIL_MARKER</p>"
        let clock = ContinuousClock()
        let start = clock.now
        let result = HtmlText.plainText(html: adversarial)
        let elapsed = clock.now - start

        XCTAssertLessThan(elapsed, .seconds(5), "unclosed <script> run must not cause quadratic blowup")
        XCTAssertTrue(result.contains("TAIL_MARKER"))
    }

    // Adversarial: many repeated unclosed HTML comment openers, the same
    // shape as <script> above but for `<!--`.
    func testAdversarialUnclosedCommentRunCompletesUnderTimeBudget() {
        let adversarial = String(repeating: "<!--", count: 20_000) + "<p>TAIL_MARKER</p>"
        let clock = ContinuousClock()
        let start = clock.now
        let result = HtmlText.plainText(html: adversarial)
        let elapsed = clock.now - start

        XCTAssertLessThan(elapsed, .seconds(5), "unclosed comment run must not cause quadratic blowup")
        XCTAssertTrue(result.contains("TAIL_MARKER"))
    }

    // Adversarial: long runs of ambiguous numeric-entity-like text (many
    // "&#x" prefixes without a closing ";").
    func testAdversarialEntityRunCompletesUnderTimeBudget() {
        let adversarial = String(repeating: "&#x", count: 50_000) + "TAIL_MARKER"
        let clock = ContinuousClock()
        let start = clock.now
        let result = HtmlText.plainText(html: adversarial)
        let elapsed = clock.now - start

        XCTAssertLessThan(elapsed, .seconds(5), "ambiguous entity run must not cause quadratic blowup")
        XCTAssertTrue(result.contains("TAIL_MARKER"))
    }

    // Legitimate content still round-trips correctly through the
    // rewritten (lookahead-bounded) block-stripping patterns.
    func testScriptStyleAndCommentBlocksStillStrippedCorrectly() {
        let html = """
        <html><head><title>Hi</title><style>body{color:red}</style></head>
        <body>
        <script>alert('should be gone')</script>
        <!-- a comment -->
        <p>Real content survives</p>
        </body></html>
        """
        let text = HtmlText.plainText(html: html)
        XCTAssertTrue(text.contains("Real content survives"))
        XCTAssertFalse(text.contains("alert"))
        XCTAssertFalse(text.contains("color:red"))
        XCTAssertFalse(text.contains("a comment"))
        XCTAssertFalse(text.contains("Hi"))
    }
}
