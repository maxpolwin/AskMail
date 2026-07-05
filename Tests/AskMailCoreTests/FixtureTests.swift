import XCTest
@testable import AskMailCore

/// Ingestion tests against the synthetic .emlx fixtures in Tests/Fixtures.
/// Assertions mirror Tests/Fixtures/README.md exactly.
final class FixtureTests: XCTestCase {

    static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // AskMailCoreTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures")

    func fixture(_ name: String) -> URL {
        Self.fixturesDirectory.appendingPathComponent(name)
    }

    // msg-0001: baseline plain-text English body.
    func testPlainTextBaseline() throws {
        let email = try EmlxParser.parse(fileURL: fixture("msg-0001-plain.emlx"))
        XCTAssertEqual(email.messageID, "fixture-0001@acme.example")
        XCTAssertEqual(email.subject, "Pricing webinar rescheduled")
        XCTAssertTrue(email.sender.contains("events@acme.example"))
        XCTAssertTrue(email.bodyText.contains("April 9 at 15:00 CET"))
        XCTAssertTrue(email.pdfAttachments.isEmpty)
        XCTAssertNotNil(email.date)
        // RFC 5322 header: Mon, 02 Mar 2026 09:14:00 +0100 == 08:14 UTC.
        XCTAssertEqual(email.dateUnix, 1_772_439_240)
    }

    // msg-0002: German HTML with unsubscribe link and tracking pixel.
    func testHtmlBoilerplateStripping() throws {
        let email = try EmlxParser.parse(fileURL: fixture("msg-0002-html-de.emlx"))
        XCTAssertEqual(email.messageID, "fixture-0002@anbieter.example")
        XCTAssertTrue(email.bodyText.contains("EU-Omnibus-Zeitplan"),
                      "content paragraph must survive HTML-to-text")
        XCTAssertFalse(email.bodyText.lowercased().contains("abmelden"),
                       "unsubscribe block must be stripped")
        XCTAssertFalse(email.bodyText.contains("pixel.gif"),
                       "tracking pixel must not leak into text")
        XCTAssertFalse(email.bodyText.contains("<"), "no residual HTML tags")
    }

    // msg-0003: multipart/mixed with base64 PDF attachment.
    func testPdfAttachmentExtraction() throws {
        let email = try EmlxParser.parse(fileURL: fixture("msg-0003-pdf.emlx"))
        XCTAssertEqual(email.messageID, "fixture-0003@acme.example")
        XCTAssertTrue(email.bodyText.contains("INV-2026-0473"))
        XCTAssertEqual(email.pdfAttachments.count, 1)
        XCTAssertEqual(email.pdfAttachments.first?.filename, "invoice.pdf")

        let pdfText = PdfText.extract(data: email.pdfAttachments[0].data)
        XCTAssertNotNil(pdfText, "PDFKit must extract text from the attachment")
        XCTAssertTrue(pdfText?.contains("INV-2026-0473") ?? false)
        XCTAssertTrue(pdfText?.contains("1,340.00 EUR") ?? false)
    }

    // End-to-end: fixture -> ingestor -> store, PDF chunks attach to the
    // parent Message-ID with source=pdf (fixtures README).
    func testIngestionAttachesPdfChunksToParentMessage() async throws {
        let store = try SQLiteStore.inMemory()
        let ingestor = MailboxIngestor(store: store,
                                       embedder: StubEmbedder(),
                                       account: "test",
                                       log: { _ in })
        let summary = try await ingestor.ingest(files: [
            fixture("msg-0001-plain.emlx"),
            fixture("msg-0002-html-de.emlx"),
            fixture("msg-0003-pdf.emlx"),
        ])
        XCTAssertEqual(summary.ingested, 3)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(try store.messageCount(), 3)

        let invoiceHits = try store.keywordSearch("INV-2026-0473")
        XCTAssertFalse(invoiceHits.isEmpty, "FTS must find the exact invoice number")
        let chunks = try store.chunks(ids: invoiceHits)
        XCTAssertTrue(chunks.allSatisfy { $0.messageID == "fixture-0003@acme.example" })
        XCTAssertTrue(chunks.contains { $0.source == .pdf },
                      "invoice figure must be retrievable from the PDF chunk")

        // Re-ingest is idempotent (FR-5: upsert without duplicates).
        let before = try store.chunkCount()
        _ = try await ingestor.ingest(files: [fixture("msg-0003-pdf.emlx")])
        XCTAssertEqual(try store.chunkCount(), before)
        XCTAssertEqual(try store.messageCount(), 3)
    }
}

/// Deterministic embedder so ingestion tests never need a running Ollama.
struct StubEmbedder: EmbeddingProvider {
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            // Cheap bag-of-characters projection: stable, distinguishes texts.
            var vector = [Float](repeating: 0, count: 32)
            for scalar in text.unicodeScalars {
                vector[Int(scalar.value) % 32] += 1
            }
            let norm = vector.map { $0 * $0 }.reduce(0, +).squareRoot()
            return norm > 0 ? vector.map { $0 / norm } : vector
        }
    }
}
