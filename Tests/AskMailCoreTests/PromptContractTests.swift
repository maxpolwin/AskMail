import XCTest
@testable import AskMailCore

/// Locks the assembler to docs/prompt-contract.md. If these fail after a
/// deliberate contract change, update the contract and re-run the generation
/// eval set (§8 change control).
final class PromptContractTests: XCTestCase {

    func chunk(_ id: Int64, message: String, sender: String = "sender@example.com",
               dateUnix: Int64 = 1_772_439_240, source: ChunkSource = .body,
               text: String) -> ContextChunk {
        ContextChunk(chunkID: id, messageID: message, subject: "Subject \(message)",
                     sender: sender, dateUnix: dateUnix, source: source, text: text)
    }

    // §3: numbers are per distinct email; two chunks of one email share one N.
    func testNumberingIsPerDistinctEmail() {
        let assembler = PromptAssembler()
        let prompt = assembler.assemble(
            question: "q",
            chunks: [
                chunk(1, message: "a@x", text: "first chunk of email A"),
                chunk(2, message: "a@x", text: "second chunk of email A"),
                chunk(3, message: "b@x", text: "chunk of email B"),
            ],
            session: []
        )
        XCTAssertEqual(prompt.sourceMap.count, 2)
        XCTAssertEqual(prompt.sourceMap[1]?.messageID, "a@x")
        XCTAssertEqual(prompt.sourceMap[2]?.messageID, "b@x")
        // Both chunks of email A render under [1]; email B under [2]. No [3].
        XCTAssertEqual(prompt.user.components(separatedBy: "--- [1] ").count - 1, 2)
        XCTAssertEqual(prompt.user.components(separatedBy: "--- [2] ").count - 1, 1)
        XCTAssertFalse(prompt.user.contains("--- [3]"))
    }

    // A source's relevance is the best (first, since fused-ranked) chunk score
    // of its email; unscored chunks leave relevance nil.
    func testSourceRelevanceUsesBestChunkScore() {
        let assembler = PromptAssembler()
        let scored = { (id: Int64, message: String, score: Double) in
            ContextChunk(chunkID: id, messageID: message, subject: "S", sender: "s",
                         dateUnix: 0, source: .body, text: "t", score: score)
        }
        let prompt = assembler.assemble(
            question: "q",
            chunks: [scored(1, "a@x", 0.9), scored(2, "a@x", 0.5), scored(3, "b@x", 0.4)],
            session: []
        )
        XCTAssertEqual(prompt.sourceMap[1]?.relevance, 0.9)  // A's top chunk
        XCTAssertEqual(prompt.sourceMap[2]?.relevance, 0.4)

        let unscored = assembler.assemble(
            question: "q", chunks: [chunk(1, message: "a@x", text: "t")], session: [])
        XCTAssertNil(unscored.sourceMap[1]?.relevance)
    }

    // §3: exact delimiter format, date rendered YYYY-MM-DD, source label.
    func testContextBlockFormat() {
        let assembler = PromptAssembler()
        let prompt = assembler.assemble(
            question: "q",
            chunks: [chunk(1, message: "a@x", sender: "ACME <billing@acme.example>",
                           dateUnix: 1_770_291_000, source: .pdf, text: "Total due 1,340.00 EUR.")],
            session: []
        )
        XCTAssertTrue(prompt.user.contains(
            "--- [1] from: ACME <billing@acme.example> | date: 2026-02-05 | source: pdf ---\nTotal due 1,340.00 EUR."
        ), "context unit must match the contract byte for byte:\n\(prompt.user)")
    }

    // §5: assembly order and section labels; no session block on first turn.
    func testFinalAssemblyFirstTurn() {
        let assembler = PromptAssembler(systemPrompt: "SYSTEM")
        let prompt = assembler.assemble(question: "When is the webinar?",
                                        chunks: [chunk(1, message: "a@x", text: "text")],
                                        session: [])
        XCTAssertEqual(prompt.system, "SYSTEM")
        XCTAssertFalse(prompt.user.contains("Earlier in this conversation:"))
        XCTAssertTrue(prompt.user.hasPrefix("CONTEXT:\n"))
        XCTAssertTrue(prompt.user.hasSuffix("QUESTION:\nWhen is the webinar?"))
    }

    // §4: session block above the context, capped at the 3 most recent turns,
    // oldest first.
    func testSessionBlockCapAndOrder() {
        let assembler = PromptAssembler()
        let session = (1...5).map { SessionTurn(question: "q\($0)", answer: "a\($0)") }
        let prompt = assembler.assemble(question: "next",
                                        chunks: [chunk(1, message: "a@x", text: "text")],
                                        session: session)
        XCTAssertTrue(prompt.user.hasPrefix("Earlier in this conversation:"))
        XCTAssertFalse(prompt.user.contains("q1"))
        XCTAssertFalse(prompt.user.contains("q2"))
        for turn in 3...5 {
            XCTAssertTrue(prompt.user.contains("Q: q\(turn)\nA: a\(turn)"))
        }
        XCTAssertLessThan(prompt.user.range(of: "q3")!.lowerBound,
                          prompt.user.range(of: "q5")!.lowerBound)
        XCTAssertLessThan(prompt.user.range(of: "q5")!.lowerBound,
                          prompt.user.range(of: "CONTEXT:")!.lowerBound)
    }

    // §2: over budget, lowest-ranked chunks drop first; numbering stays
    // contiguous because it is assigned after the trim.
    func testBudgetDropsLowestRankedFirst() {
        let assembler = PromptAssembler(contextTokenLimit: 60)
        let prompt = assembler.assemble(
            question: "q",
            chunks: [
                chunk(1, message: "a@x", text: String(repeating: "alpha ", count: 20)),
                chunk(2, message: "b@x", text: String(repeating: "beta ", count: 20)),
                chunk(3, message: "c@x", text: String(repeating: "gamma ", count: 20)),
            ],
            session: []
        )
        XCTAssertTrue(prompt.user.contains("alpha"), "top-ranked chunk always survives")
        XCTAssertFalse(prompt.user.contains("gamma"), "lowest-ranked chunk drops first")
        XCTAssertEqual(prompt.sourceMap.keys.sorted(), Array(1...prompt.sourceMap.count),
                       "numbering must be contiguous after the trim")
    }

    // §1: the shipped default prompt is the contract text.
    func testDefaultSystemPromptPinned() {
        XCTAssertTrue(Defaults.defaultSystemPrompt.hasPrefix(
            "You are an assistant that answers questions about the user's own email."))
        XCTAssertTrue(Defaults.defaultSystemPrompt.contains("Answer ONLY from the CONTEXT"))
        XCTAssertTrue(Defaults.defaultSystemPrompt.contains("SAME LANGUAGE as the QUESTION"))
    }
}

final class CitationRendererTests: XCTestCase {

    let map: [Int: SourceRef] = [
        1: SourceRef(messageID: "a@x", subject: "A", sender: "s1", dateUnix: 0),
        2: SourceRef(messageID: "b@x", subject: "B", sender: "s2", dateUnix: 0),
    ]

    // §6: [N] becomes a superscript; the source list carries matching numbers.
    func testSuperscriptSubstitutionAndSourceList() {
        let rendered = CitationRenderer.render(
            answer: "The webinar moved to April 9 [1]. The discount is 15 percent [2].",
            sourceMap: map
        )
        XCTAssertEqual(rendered.text,
                       "The webinar moved to April 9\u{00b9}. The discount is 15 percent\u{00b2}.")
        XCTAssertEqual(rendered.sources.map(\.number), [1, 2])
        XCTAssertEqual(rendered.sources.map(\.ref.messageID), ["a@x", "b@x"])
        XCTAssertTrue(rendered.droppedMarkers.isEmpty)
    }

    // §6: a marker with no matching source is dropped silently, and logged.
    func testUnknownMarkerDropped() {
        let rendered = CitationRenderer.render(answer: "Fact [1]. Bogus claim [7].",
                                               sourceMap: map)
        XCTAssertEqual(rendered.text, "Fact\u{00b9}. Bogus claim.")
        XCTAssertEqual(rendered.droppedMarkers, [7])
        XCTAssertEqual(rendered.sources.map(\.number), [1])
    }

    // Repeated citations of one source list it once.
    func testRepeatedCitationListedOnce() {
        let rendered = CitationRenderer.render(answer: "A [1]. B [1]. C [2].",
                                               sourceMap: map)
        XCTAssertEqual(rendered.sources.map(\.number), [1, 2])
    }

    // A comma-combined citation renders each number and lists each source.
    func testCombinedCitation() {
        let rendered = CitationRenderer.render(answer: "War strains finances [1, 2].",
                                               sourceMap: map)
        XCTAssertEqual(rendered.text, "War strains finances\u{00b9}\u{2009}\u{00b2}.")
        XCTAssertEqual(rendered.sources.map(\.number), [1, 2])
        XCTAssertTrue(rendered.droppedMarkers.isEmpty)
    }

    // Within a combined marker, unknown numbers drop and the valid ones stay
    // (2 is the only cited source, so it renumbers to 1).
    func testCombinedCitationPartialDrop() {
        let rendered = CitationRenderer.render(answer: "Claim [2,9].", sourceMap: map)
        XCTAssertEqual(rendered.text, "Claim\u{00b9}.")
        XCTAssertEqual(rendered.droppedMarkers, [9])
        XCTAssertEqual(rendered.sources.map(\.number), [1])
        XCTAssertEqual(rendered.sources.map(\.ref.messageID), ["b@x"])
    }

    // Cited sources are renumbered by first appearance in the answer, not by
    // their original retrieval-rank numbers — so the list reads 1, 2 with no
    // gaps even when the model cites the second source first.
    func testRenumbersByAppearance() {
        let rendered = CitationRenderer.render(
            answer: "Second source first [2]. Then the first [1].", sourceMap: map)
        XCTAssertEqual(rendered.text,
                       "Second source first\u{00b9}. Then the first\u{00b2}.")
        XCTAssertEqual(rendered.sources.map(\.number), [1, 2])
        XCTAssertEqual(rendered.sources.map(\.ref.messageID), ["b@x", "a@x"])
    }

    func testMultiDigitSuperscript() {
        XCTAssertEqual(CitationRenderer.superscript(12), "\u{00b9}\u{00b2}")
    }

    // §6: message:// deep link with URL-encoded angle brackets.
    func testMessageURLEncoding() {
        let url = CitationRenderer.messageURL(messageID: "fixture-0003@acme.example")
        XCTAssertEqual(url?.absoluteString, "message://%3Cfixture-0003@acme.example%3E")
    }
}
