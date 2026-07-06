import XCTest
@testable import AskMailApp
@testable import AskMailCore

final class SourceFormattingTests: XCTestCase {

    func ref(excerpt: String = "") -> SourceRef {
        SourceRef(messageID: "a@x", subject: "Subject", sender: "sender@example.com",
                  dateUnix: 1_772_439_240, excerpt: excerpt)
    }

    func testQuotedExcerptFlattensNewlinesAndWraps() {
        let source = ref(excerpt: "First line.\n\nSecond   line.")
        XCTAssertEqual(quotedExcerpt(source), "\"First line. Second line.\"")
    }

    func testQuotedExcerptNilWhenEmpty() {
        XCTAssertNil(quotedExcerpt(ref(excerpt: "")))
    }

    func testFormatSourceUnaffectedByExcerpt() {
        // formatSource itself stays the number+domain+date+subject line;
        // the excerpt is appended separately by clipboardText.
        let line = formatSource(1, ref(excerpt: "some chunk text"))
        XCTAssertFalse(line.contains("some chunk text"))
    }

    @MainActor
    func testClipboardTextIncludesQuotedExcerpt() {
        let model = AskViewModel()
        model.answer = "Answer text."
        model.sources = [(number: 1, ref: ref(excerpt: "Exact chunk text shown to the model."))]
        let clipboard = model.clipboardText()
        XCTAssertTrue(clipboard.contains("\"Exact chunk text shown to the model.\""))
    }

    @MainActor
    func testClipboardTextOmitsQuoteMarkerWhenExcerptEmpty() {
        let model = AskViewModel()
        model.answer = "Answer text."
        model.sources = [(number: 1, ref: ref(excerpt: ""))]
        XCTAssertFalse(model.clipboardText().contains("\""))
    }
}
