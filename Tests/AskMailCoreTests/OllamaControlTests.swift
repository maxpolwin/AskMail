import XCTest
@testable import AskMailCore

/// Ollama runtime control: pure decoders for /api/tags, /api/show, and the
/// /api/pull NDJSON stream, plus the status derivation the Settings engine
/// section renders. All headless — no live daemon (see spec constraints).
final class OllamaControlTests: XCTestCase {

    // MARK: /api/tags decoding

    func testParseTagsExtractsNameSizeCapabilitiesAndDimension() throws {
        // Verbatim shape from a live Ollama 0.31.1 /api/tags response.
        let json = """
        {"models":[
          {"name":"nomic-embed-text:latest","model":"nomic-embed-text:latest",
           "size":274302450,"digest":"0a109f",
           "details":{"family":"nomic-bert","parameter_size":"137M",
                      "context_length":2048,"embedding_length":768},
           "capabilities":["embedding"]},
          {"name":"llama3.2:latest","size":2019393189,
           "details":{"family":"llama","parameter_size":"3.2B",
                      "embedding_length":3072},
           "capabilities":["completion","tools"]}
        ]}
        """.data(using: .utf8)!

        let models = try OllamaControl.parseTags(json)
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0], InstalledModel(name: "nomic-embed-text:latest",
                                                 sizeBytes: 274_302_450,
                                                 capabilities: ["embedding"],
                                                 embeddingLength: 768))
        XCTAssertEqual(models[1].capabilities, ["completion", "tools"])
    }

    func testParseTagsToleratesOlderDaemonsWithoutCapabilities() throws {
        // Pre-capabilities daemons only report name/size/details.
        let json = """
        {"models":[{"name":"phi3:latest","size":42,"details":{"family":"phi3"}}]}
        """.data(using: .utf8)!

        let models = try OllamaControl.parseTags(json)
        XCTAssertEqual(models, [InstalledModel(name: "phi3:latest", sizeBytes: 42,
                                               capabilities: [], embeddingLength: nil)])
    }

    func testParseTagsRejectsMalformedPayload() {
        XCTAssertThrowsError(try OllamaControl.parseTags(Data("{}".utf8)))
        XCTAssertThrowsError(try OllamaControl.parseTags(Data("not json".utf8)))
    }

    // MARK: /api/show decoding

    func testParseShowFindsArchitecturePrefixedEmbeddingLength() throws {
        // The dimension key is prefixed by the architecture ("nomic-bert.",
        // "llama.", …), so the decoder must match by suffix, not exact key.
        let json = """
        {"capabilities":["embedding"],
         "model_info":{"general.architecture":"nomic-bert",
                       "nomic-bert.context_length":2048,
                       "nomic-bert.embedding_length":768}}
        """.data(using: .utf8)!

        let info = try OllamaControl.parseShow(json)
        XCTAssertEqual(info, OllamaModelInfo(capabilities: ["embedding"], embeddingLength: 768))
    }

    func testParseShowToleratesMissingFields() throws {
        let info = try OllamaControl.parseShow(Data("{}".utf8))
        XCTAssertEqual(info, OllamaModelInfo(capabilities: [], embeddingLength: nil))
    }

    // MARK: /api/pull NDJSON progress

    func testParsePullLineAcrossAPullLifecycle() throws {
        let manifest = try OllamaControl.parsePullLine(#"{"status":"pulling manifest"}"#)
        XCTAssertEqual(manifest, PullProgress(status: "pulling manifest"))
        XCTAssertNil(manifest?.fraction, "no totals yet, no fraction")

        let downloading = try OllamaControl.parsePullLine(
            #"{"status":"downloading","digest":"sha256:abc","total":1000,"completed":250}"#)
        XCTAssertEqual(downloading, PullProgress(status: "downloading", completed: 250, total: 1000))
        XCTAssertEqual(downloading?.fraction, 0.25)
        XCTAssertFalse(downloading!.isSuccess)

        let success = try OllamaControl.parsePullLine(#"{"status":"success"}"#)
        XCTAssertTrue(success!.isSuccess)
    }

    func testParsePullLineSkipsBlankAndNonJSONLines() throws {
        XCTAssertNil(try OllamaControl.parsePullLine(""))
        XCTAssertNil(try OllamaControl.parsePullLine("   "))
        XCTAssertNil(try OllamaControl.parsePullLine("not json"))
        XCTAssertNil(try OllamaControl.parsePullLine(#"{"no_status":true}"#))
    }

    func testParsePullLineThrowsOnMidStreamError() {
        // An unknown model reports its failure as an NDJSON error line, which
        // must surface as a thrown error, not a silent stream end.
        XCTAssertThrowsError(
            try OllamaControl.parsePullLine(#"{"error":"pull model manifest: file does not exist"}"#))
    }

    // MARK: Status derivation table

    func testStatusDerivationTable() {
        let embed = InstalledModel(name: "nomic-embed-text:latest", sizeBytes: 1)
        let chat = InstalledModel(name: "qwen2.5:7b", sizeBytes: 1)

        // (reachable, binaryPresent, installed) → status
        XCTAssertEqual(OllamaStatus.derive(reachable: false, binaryPresent: false, installed: []),
                       .notInstalled)
        XCTAssertEqual(OllamaStatus.derive(reachable: false, binaryPresent: true, installed: []),
                       .stopped)
        XCTAssertEqual(OllamaStatus.derive(reachable: true, binaryPresent: true, installed: [chat]),
                       .runningModelMissing(model: Defaults.embeddingModel))
        XCTAssertEqual(OllamaStatus.derive(reachable: true, binaryPresent: true,
                                           installed: [embed, chat]),
                       .ready(modelCount: 2))
        // Reachable wins over a failed disk probe: a daemon that answers is
        // running, whether or not we spotted the binary.
        XCTAssertEqual(OllamaStatus.derive(reachable: true, binaryPresent: false, installed: [embed]),
                       .ready(modelCount: 1))
    }

    func testModelNameMatchingNormalizesLatestTag() {
        // /api/tags reports "name:latest"; settings store untagged names.
        XCTAssertTrue(OllamaStatus.modelName("nomic-embed-text:latest", matches: "nomic-embed-text"))
        XCTAssertTrue(OllamaStatus.modelName("qwen2.5:7b", matches: "qwen2.5:7b"))
        XCTAssertFalse(OllamaStatus.modelName("nomic-embed-text:v1.5", matches: "nomic-embed-text"))
        XCTAssertFalse(OllamaStatus.modelName("mxbai-embed-large:latest", matches: "nomic-embed-text"))
    }

    // MARK: Reporter over a stubbed control (no network)

    func testReporterComposesReachabilityAndTags() async {
        let embed = InstalledModel(name: "nomic-embed-text:latest", sizeBytes: 1)

        var status = await OllamaStatusReporter.current(
            control: StubOllamaControl(reachable: false), binaryPresent: false)
        XCTAssertEqual(status, .notInstalled)

        status = await OllamaStatusReporter.current(
            control: StubOllamaControl(reachable: false), binaryPresent: true)
        XCTAssertEqual(status, .stopped)

        status = await OllamaStatusReporter.current(
            control: StubOllamaControl(reachable: true, models: .success([])),
            binaryPresent: true)
        XCTAssertEqual(status, .runningModelMissing(model: Defaults.embeddingModel))

        status = await OllamaStatusReporter.current(
            control: StubOllamaControl(reachable: true, models: .success([embed])),
            binaryPresent: true)
        XCTAssertEqual(status, .ready(modelCount: 1))
    }

    func testReporterTreatsTagsFailureAsModelMissingNotReady() async {
        // Daemon up but /api/tags erroring: show the actionable state, never
        // claim readiness that wasn't observed.
        let status = await OllamaStatusReporter.current(
            control: StubOllamaControl(reachable: true,
                                       models: .failure(ProviderError.http(status: 500, body: ""))),
            binaryPresent: true)
        XCTAssertEqual(status, .runningModelMissing(model: Defaults.embeddingModel))
    }

    // MARK: Install locator

    func testBinaryPresenceChecksKnownLocations() {
        XCTAssertTrue(OllamaInstallLocator.binaryPresent { $0 == "/Applications/Ollama.app" })
        XCTAssertTrue(OllamaInstallLocator.binaryPresent { $0 == "/opt/homebrew/bin/ollama" })
        XCTAssertFalse(OllamaInstallLocator.binaryPresent { _ in false })
        XCTAssertNil(OllamaInstallLocator.appURL { _ in false })
        XCTAssertEqual(OllamaInstallLocator.cliURL { $0 == "/usr/local/bin/ollama" }?.path,
                       "/usr/local/bin/ollama")
    }
}

/// Canned-response control for driving status logic without a socket, in the
/// spirit of StubEmbedder/UnreachableEmbedder.
private struct StubOllamaControl: OllamaControlling {
    var reachable: Bool
    var models: Result<[InstalledModel], Error> = .success([])

    func reachable() async -> Bool { reachable }

    func installedModels() async throws -> [InstalledModel] { try models.get() }

    func showModel(_ id: String) async throws -> OllamaModelInfo { OllamaModelInfo() }

    func pull(_ id: String) -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
