import XCTest
@testable import AskMailCore

// Hardening H-6: `InProcessEmailParser`/`IngestableEmail` are the boundary
// type and default (test/in-process) implementation of the parsing
// abstraction that lets production swap in `XPCEmailParser` — untrusted
// .emlx/MIME/HTML/PDF parsing running in a sandboxed child process instead
// of in the FDA-holding main app. These tests pin the conversion's behavior
// (PDF text already extracted, nil preserved on extraction failure) and the
// exact JSON shape that crosses the real XPC boundary.
final class EmailParsingTests: XCTestCase {

    static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // AskMailCoreTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures")

    func fixture(_ name: String) -> URL {
        Self.fixturesDirectory.appendingPathComponent(name)
    }

    // The in-process parser must reproduce exactly what EmlxParser.parse +
    // PdfText.extract already do directly (Tests/Fixtures/README.md), just
    // reshaped into IngestableEmail's already-extracted-text form.
    func testInProcessParserExtractsPdfTextForIngestion() async throws {
        let parser = InProcessEmailParser()
        let email = try await parser.parse(fileURL: fixture("msg-0003-pdf.emlx"))

        XCTAssertEqual(email.messageID, "fixture-0003@acme.example")
        XCTAssertEqual(email.pdfAttachments.count, 1)
        XCTAssertEqual(email.pdfAttachments[0].filename, "invoice.pdf")
        let text = try XCTUnwrap(email.pdfAttachments[0].text)
        XCTAssertTrue(text.contains("INV-2026-0473"))
        XCTAssertTrue(text.contains("1,340.00 EUR"))
    }

    func testInProcessParserPreservesEmptyPdfAttachments() async throws {
        let email = try await InProcessEmailParser().parse(fileURL: fixture("msg-0001-plain.emlx"))
        XCTAssertTrue(email.pdfAttachments.isEmpty)
        XCTAssertTrue(email.bodyText.contains("April 9 at 15:00 CET"))
    }

    // PdfText.extract's nil-on-failure contract (unreadable/locked/no text)
    // must survive the ParsedEmail -> IngestableEmail conversion: the
    // filename is kept (for Ingestor's "no extractable text" skip log) but
    // the text is nil, not an empty string or a thrown error.
    func testIngestableConversionPreservesNilOnUnextractablePdf() {
        let garbage = PdfAttachment(filename: "not-a-real.pdf", data: Data("not a pdf".utf8))
        let parsed = ParsedEmail(messageID: "m@x", subject: "s", sender: "from@x",
                                 recipient: "to@x", date: Date(timeIntervalSince1970: 0),
                                 bodyText: "body", pdfAttachments: [garbage], skippedAttachments: [])

        let ingestable = InProcessEmailParser.ingestable(from: parsed)

        XCTAssertEqual(ingestable.pdfAttachments.count, 1)
        XCTAssertEqual(ingestable.pdfAttachments[0].filename, "not-a-real.pdf")
        XCTAssertNil(ingestable.pdfAttachments[0].text)
        XCTAssertEqual(ingestable.bodyText, "body")
        XCTAssertEqual(ingestable.skippedAttachments, [])
    }

    // Exercises the exact JSON shape that crosses the real NSXPCConnection
    // boundary (ParserXPCProtocol.parseEmlx's reply) — a schema mismatch
    // here would silently break production ingestion, not just this test.
    func testIngestableEmailRoundTripsThroughJSON() throws {
        let original = IngestableEmail(
            messageID: "abc@example.com", subject: "Subj \u{00e9}\u{00e4}", sender: "a@b.example",
            dateUnix: 1_772_439_240, bodyText: "line one\nline two",
            pdfAttachments: [
                IngestableEmail.PdfAttachmentText(filename: "one.pdf", text: "extracted"),
                IngestableEmail.PdfAttachmentText(filename: "two.pdf", text: nil),
            ],
            skippedAttachments: ["huge.pdf"])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IngestableEmail.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}
