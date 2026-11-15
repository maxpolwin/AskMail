import XCTest
@testable import AskMailCore

/// The arithmetic behind the Settings budget panel, the memory model measured
/// against real Ollama runs, the clamps that bound the user's choices, and the
/// sampled chunk size that feeds the per-excerpt figure.
final class ContextBudgetTests: XCTestCase {

    private let gb: Int64 = 1_000_000_000
    private let llama3b = ModelArchitecture(layers: 28, kvHeads: 8, keyLength: 128, valueLength: 128,
                                            maxContextTokens: 131_072)

    private func budget(excerpts: Int = 8, context: Int = 16384, answer: Int = 1000,
                        perExcerpt: Int = 550, memory: ModelMemory? = nil, server: Int? = nil) -> ContextBudget {
        ContextBudget(excerpts: excerpts, contextTokens: context, answerTokens: answer,
                      tokensPerExcerpt: perExcerpt, memory: memory, serverWindowTokens: server)
    }

    // MARK: Segments and statuses

    func testSegmentsAddUpToTheWindow() {
        let b = budget()
        XCTAssertEqual(b.promptTokens, Defaults.promptScaffoldTokens)
        XCTAssertEqual(b.emailUsedTokens, 8 * 550)
        XCTAssertEqual(b.emailUnusedTokens, 16384 - 8 * 550)
        XCTAssertEqual(b.answerTokens, 1000)
        XCTAssertEqual(b.windowTokens, 2048 + 16384 + 1000)
        XCTAssertEqual(b.emailUsedPercent, 27)
    }

    func testExcerptsBeyondTheBudgetAreDroppedNotCounted() {
        let b = budget(excerpts: 40, context: 4096)
        XCTAssertEqual(b.emailUsedTokens, 4096, "used is capped at the budget")
        XCTAssertEqual(b.emailUnusedTokens, 0)
        XCTAssertEqual(b.emailNeededTokens, 22000)
        XCTAssertEqual(b.status, .needsMoreBudget(neededTokens: 22000))
    }

    func testStatusDecisionTable() {
        XCTAssertEqual(budget(excerpts: 8, context: 5000).status, .fits)
        XCTAssertEqual(budget(excerpts: 8, context: 16384).status, .mostlyUnused(percentUsed: 27))
        // A server window smaller than the request outranks everything.
        XCTAssertEqual(budget(server: 8192).status, .aboveServerWindow(serverTokens: 8192))
        XCTAssertEqual(budget(excerpts: 8, context: 5000, server: 32768).status, .fits)
    }

    func testNegativeInputsNeverProduceNegativeSegments() {
        let b = budget(excerpts: -3, context: -5, answer: -1)
        XCTAssertEqual(b.emailUsedTokens, 0)
        XCTAssertEqual(b.emailUnusedTokens, 0)
        XCTAssertEqual(b.answerTokens, 0)
    }

    func testTokensPerExcerptFromTheIndex() {
        XCTAssertEqual(ContextBudget.tokensPerExcerpt(averageChunkChars: nil), Defaults.fallbackTokensPerExcerpt)
        XCTAssertEqual(ContextBudget.tokensPerExcerpt(averageChunkChars: 0), Defaults.fallbackTokensPerExcerpt)
        XCTAssertEqual(ContextBudget.tokensPerExcerpt(averageChunkChars: 2048), 512 + 40)
        XCTAssertEqual(ContextBudget.tokensPerExcerpt(averageChunkChars: 400), 100 + 40)
    }

    func testFallbackMatchesAFullChunk() {
        XCTAssertEqual(Defaults.fallbackTokensPerExcerpt,
                       (Defaults.chunkChars + 3) / 4 + Defaults.excerptOverheadTokens - 2,
                       "the fallback is a full chunk plus overhead, rounded")
    }

    // MARK: Memory model, checked against measured Ollama runs

    /// (context window, Ollama's reported size in GB) from the benchmark on an
    /// Apple M2 (24 GB), Ollama 0.40.16, f16 KV cache. The estimate must never
    /// fall below what Ollama reported, and must stay within 20% of it.
    private static let measured: [(name: String, arch: ModelArchitecture, weightsGB: Double,
                                   runs: [(ctx: Int, gb: Double)])] = [
        ("llama3.2:3b", ModelArchitecture(layers: 28, kvHeads: 8, keyLength: 128, valueLength: 128), 2.02,
         [(2048, 2.32), (4096, 2.56), (8192, 3.12), (16384, 4.08), (32768, 6.05), (65536, 10.01)]),
        ("qwen2.5:7b", ModelArchitecture(layers: 28, kvHeads: 4, keyLength: 128, valueLength: 128), 4.68,
         [(2048, 4.64), (4096, 4.76), (8192, 5.15), (16384, 5.64), (32768, 6.61)]),
        ("qwen2.5:14b", ModelArchitecture(layers: 48, kvHeads: 8, keyLength: 128, valueLength: 128), 8.99,
         [(2048, 9.08), (4096, 9.48), (8192, 10.43), (16384, 12.05), (32768, 15.23)]),
    ]

    func testEstimateTracksMeasuredOllamaSizes() {
        for model in Self.measured {
            let memory = ModelMemory(weightsBytes: Int64(model.weightsGB * 1e9), architecture: model.arch,
                                     gpuLimitBytes: 19 * gb)
            for run in model.runs {
                let estimate = gigabytes(memory.estimatedBytes(windowTokens: run.ctx))
                XCTAssertGreaterThanOrEqual(estimate, run.gb, "\(model.name) @\(run.ctx) must not under-estimate")
                XCTAssertLessThanOrEqual(estimate, run.gb * 1.2, "\(model.name) @\(run.ctx) too pessimistic")
            }
        }
    }

    func testKvCostPerTokenMatchesTheKnownArchitectures() {
        XCTAssertEqual(llama3b.kvBytesPerToken, 114_688)   // 112 KiB, as measured
        XCTAssertEqual(ModelArchitecture(layers: 28, kvHeads: 4, keyLength: 128, valueLength: 128).kvBytesPerToken,
                       57_344)
        XCTAssertEqual(ModelArchitecture(layers: 48, kvHeads: 8, keyLength: 128, valueLength: 128).kvBytesPerToken,
                       196_608)
    }

    func testTheUsersWindowOnLlama3bIsNotAMemoryWarning() {
        // 18,944 context + 2,000 answer + 2,048 prompt = 22,992 tokens on llama3.2:3b with the
        // 17.76 GiB (19.07 GB) GPU limit of a 24 GB M2: about 4.9 GB, nowhere near the limit.
        let memory = ModelMemory(weightsBytes: Int64(2.02e9), architecture: llama3b, gpuLimitBytes: 19_070_000_000)
        let b = budget(excerpts: 13, context: 18_944, answer: 2000, memory: memory)
        XCTAssertEqual(try XCTUnwrap(b.estimatedMemoryGB), 5.1, accuracy: 0.3)
        if case .aboveMemory = b.status { XCTFail("this window is far inside the GPU limit") }
    }

    func testWarnsOnlyWhenTheEstimatePassesNinetyPercentOfTheGpuLimit() {
        let memory = ModelMemory(weightsBytes: 9 * gb,
                                 architecture: ModelArchitecture(layers: 48, kvHeads: 8, keyLength: 128,
                                                                 valueLength: 128, maxContextTokens: 131_072),
                                 gpuLimitBytes: 19_070_000_000)
        // 9 GB + 192 KiB/token: 32k tokens ~ 15.6 GB (fine), 48k ~ 19 GB (over the limit).
        XCTAssertNotEqual(budget(excerpts: 13, context: 30_000, memory: memory).status.isMemoryWarning, true)
        XCTAssertEqual(budget(excerpts: 13, context: 48_000, memory: memory).status.isMemoryWarning, true)
    }

    func testModelAndServerWindowsOutrankMemory() {
        let shortModel = ModelMemory(weightsBytes: 2 * gb,
                                     architecture: ModelArchitecture(layers: 28, kvHeads: 8, keyLength: 128,
                                                                     valueLength: 128, maxContextTokens: 8192),
                                     gpuLimitBytes: 19 * gb)
        XCTAssertEqual(budget(excerpts: 8, context: 8000, memory: shortModel).status,
                       .aboveModelWindow(maxTokens: 8192))
    }

    func testNoArchitectureMeansNoMemoryFigure() {
        let b = budget()
        XCTAssertNil(b.estimatedMemoryGB)
        XCTAssertNil(b.gpuLimitGB)
    }

    func testMaxWindowKeepsTheEstimateInsideTheWarnFraction() {
        let memory = ModelMemory(weightsBytes: 9 * gb,
                                 architecture: ModelArchitecture(layers: 48, kvHeads: 8, keyLength: 128, valueLength: 128),
                                 gpuLimitBytes: 19_070_000_000)
        let window = memory.maxWindowTokens()
        XCTAssertLessThanOrEqual(memory.estimatedBytes(windowTokens: window),
                                 Double(memory.gpuLimitBytes) * ModelMemory.warnFraction)
        XCTAssertGreaterThan(memory.estimatedBytes(windowTokens: window + 1000),
                             Double(memory.gpuLimitBytes) * ModelMemory.warnFraction)
        // A model that alone exceeds the limit leaves no window at all.
        let huge = ModelMemory(weightsBytes: 30 * gb, architecture: llama3b, gpuLimitBytes: 19 * gb)
        XCTAssertEqual(huge.maxWindowTokens(), 0)
    }

    // MARK: Reading /api/show

    func testArchitectureParsesFromModelInfoAndRefusesToGuess() {
        let info: [String: Any] = [
            "general.architecture": "llama",
            "llama.block_count": 28, "llama.attention.head_count": 24, "llama.attention.head_count_kv": 8,
            "llama.attention.key_length": 128, "llama.attention.value_length": 128,
            "llama.embedding_length": 3072, "llama.context_length": 131_072,
        ]
        XCTAssertEqual(ModelArchitecture.parse(modelInfo: info),
                       ModelArchitecture(layers: 28, kvHeads: 8, keyLength: 128, valueLength: 128,
                                         maxContextTokens: 131_072))

        // Key length falls back to embedding / heads; KV heads to the head count.
        var sparse = info
        sparse.removeValue(forKey: "llama.attention.key_length")
        sparse.removeValue(forKey: "llama.attention.value_length")
        sparse.removeValue(forKey: "llama.attention.head_count_kv")
        XCTAssertEqual(ModelArchitecture.parse(modelInfo: sparse)?.kvBytesPerToken, 28 * 24 * 256 * 2)

        XCTAssertNil(ModelArchitecture.parse(modelInfo: [:]))
        var perLayer = info
        perLayer["llama.attention.head_count_kv"] = [8, 8, 4]       // per-layer arrays: unknown
        XCTAssertNil(ModelArchitecture.parse(modelInfo: perLayer))
        var absurd = info
        absurd["llama.block_count"] = 0
        XCTAssertNil(ModelArchitecture.parse(modelInfo: absurd))
    }

    func testParameterSizeParsing() {
        XCTAssertEqual(OllamaControl.parseParameterBillions("7.6B"), 7.6)
        XCTAssertEqual(OllamaControl.parseParameterBillions("494M"), 0.494)
        XCTAssertEqual(OllamaControl.parseParameterBillions("1.2T"), 1200)
        XCTAssertNil(OllamaControl.parseParameterBillions("big"))
        XCTAssertNil(OllamaControl.parseParameterBillions(""))
    }

    // MARK: Clamps and ranges

    func testClampBoundsEveryBudgetValue() {
        XCTAssertEqual(Defaults.clamp(-5, to: Defaults.contextTokenRange), 512)
        XCTAssertEqual(Defaults.clamp(10_000_000, to: Defaults.contextTokenRange), 131_072)
        XCTAssertEqual(Defaults.clamp(0, to: Defaults.excerptRange), 1)
        XCTAssertEqual(Defaults.clamp(500, to: Defaults.excerptRange), 40)
        XCTAssertEqual(Defaults.clamp(2000, to: Defaults.answerTokenRange), 2000)
    }

    func testRequestedWindowIsCappedEvenForOutOfRangeSettings() {
        var settings = QuerySettings()
        settings.contextTokenLimit = 16384
        settings.answerTokenLimit = 2000
        XCTAssertEqual(QueryService.contextWindow(for: settings), 16384 + 2000 + 2048)

        settings.contextTokenLimit = Int.max / 4
        settings.answerTokenLimit = Int.max / 4
        XCTAssertEqual(QueryService.contextWindow(for: settings), Defaults.maxContextWindow)

        settings.contextTokenLimit = -100
        settings.answerTokenLimit = -100
        XCTAssertEqual(QueryService.contextWindow(for: settings), Defaults.promptScaffoldTokens)
    }

    func testMaxWindowIsTheSumOfTheMaximums() {
        XCTAssertEqual(Defaults.maxContextWindow,
                       Defaults.contextTokenRange.upperBound + Defaults.answerTokenRange.upperBound
                           + Defaults.promptScaffoldTokens)
        XCTAssertLessThanOrEqual(Defaults.excerptRange.upperBound, Defaults.vectorTopN + Defaults.keywordTopN)
    }

    // MARK: Sampled chunk size

    func testAverageChunkCharsIsSampledAndNilWhenEmpty() throws {
        let store = try SQLiteStore.inMemory()
        XCTAssertNil(try store.averageChunkChars())
        let pk = try store.upsertMessage(messageID: "m@x", account: "a", subject: "s", sender: "x@y", dateUnix: 1)
        try store.replaceChunks(messagePk: pk, chunks: [
            (.body, String(repeating: "a", count: 100), nil),
            (.body, String(repeating: "b", count: 300), nil),
        ])
        XCTAssertEqual(try store.averageChunkChars(), 200)
        XCTAssertEqual(try store.averageChunkChars(sample: 1), 100, "only the sampled rows count")
    }
}

private extension ContextBudget.Status {
    var isMemoryWarning: Bool {
        if case .aboveMemory = self { return true }
        return false
    }
}
