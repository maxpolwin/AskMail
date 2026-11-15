import XCTest
@testable import AskMailCore

/// Hardening H-25: Draft-Modus never drafts through a cloud provider, and a
/// local server only ever on loopback.
final class DraftChatFactoryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func settings(_ provider: ProviderChoice,
                          serverURL: String = "http://localhost:1234/v1",
                          serverModel: String = "qwen") -> QuerySettings {
        QuerySettings(provider: provider, localModel: "llama3.2:3b",
                      localServerURL: serverURL, localServerModel: serverModel)
    }

    func testNoProviderChoiceDraftsThroughTheCloud() {
        for choice in ProviderChoice.allCases {
            let provider = DraftChatFactory.make(settings: settings(choice))
            XCTAssertNil(provider.egressHost, "\(choice) must draft on this Mac")
        }
    }

    func testOllamaUnlessAskUsesTheLocalServer() {
        for choice in [ProviderChoice.ollamaLocal, .ollamaCloud, .mistral] {
            let provider = DraftChatFactory.make(settings: settings(choice))
            XCTAssertTrue(provider is OllamaClient, "\(choice)")
            XCTAssertFalse(DraftChatFactory.usesLocalServer(choice))
        }
        XCTAssertTrue(DraftChatFactory.make(settings: settings(.localServer)) is OpenAIChatClient)
        XCTAssertTrue(DraftChatFactory.usesLocalServer(.localServer))
    }

    func testNonLoopbackOrModelLessServerFailsClosed() async {
        let refused = [settings(.localServer, serverURL: "http://192.168.1.20:1234/v1"),
                       settings(.localServer, serverURL: "https://api.mistral.ai/v1"),
                       settings(.localServer, serverModel: "  ")]
        for config in refused {
            let provider = DraftChatFactory.make(settings: config)
            XCTAssertTrue(provider is FailingChatProvider, config.localServerURL)
            do {
                for try await _ in provider.stream(ChatRequest(system: "s", user: "u")) {}
                XCTFail("expected an error for \(config.localServerURL)")
            } catch {}
        }
    }

    /// The draft pipeline works unchanged through an OpenAI-style server.
    func testRegenerateDraftThroughALocalServer() async throws {
        StubURLProtocol.enqueue(status: 200, body: """
        data: {"choices":[{"delta":{"content":"Friday "}}]}
        data: {"choices":[{"delta":{"content":"works for me!"}}]}
        data: [DONE]
        """)
        let client = OpenAIChatClient(baseURL: URL(string: "http://localhost:1234/v1")!, model: "qwen",
                                      session: LocalServerSession.make(protocolClasses: [StubURLProtocol.self]))
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ThreadResolver.resolveThread(messageID: "m1@x", inReplyTo: nil, references: [], store: askStore)
        try askStore.upsertMessage(messageID: "m1@x", account: "acc", subject: "Catch up", sender: "alice@example.com",
                                   threadID: threadID, bodyText: "How's Friday looking?", dateUnix: 1)

        let record = try await DraftJobProcessor.regenerateDraft(
            threadID: threadID, draftStore: draftStore, askStore: askStore,
            chatProvider: client, embedder: StubEmbedder())

        XCTAssertEqual(record.draftText, "Friday works for me!")
        XCTAssertEqual(record.status, .ready)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }
}
