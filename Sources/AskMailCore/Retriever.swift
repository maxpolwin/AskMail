import Foundation

/// Shared hybrid-retrieval core, extracted from `QueryService.retrieve` so
/// `DraftAssembler`'s grounding lookup can reuse it. Covers embed (done by
/// the caller, which owns the `EmbeddingProvider`) → vector/keyword search →
/// RRF fuse → relevance-floor filter → chunk load with scores attached.
///
/// Deliberately stops there, before any date-scoping or `topK` cut:
/// `QueryService` layers its own date-filter merge (`DateFilter`) and `topK`
/// on top of this unchanged, since a date-scoped question has no equivalent
/// in draft grounding — `DraftAssembler` just takes its own `prefix(topK)`
/// directly from what this returns.
public enum Retriever {

    public static func hybridRetrieve(embedding: [Float], keywordQuery: String, store: SQLiteStore,
                                      vectorTopN: Int, keywordTopN: Int, relevanceFloor: Double,
                                      excludingMessageIDs: Set<String> = [],
                                      log: (String, RollingLog.LogLevel) -> Void = { _, _ in }) throws -> [ContextChunk] {
        let vectorIDs = embedding.isEmpty ? [] : try store.vectorSearch(embedding, topN: vectorTopN)
        let keywordIDs = try store.keywordSearch(keywordQuery, topN: keywordTopN)

        let fused = Fusion.reciprocalRankFusion([vectorIDs, keywordIDs])
        let aboveFloor = fused.filter { $0.score > relevanceFloor }
        log("retrieval vector=\(vectorIDs.count) keyword=\(keywordIDs.count) fused=\(fused.count) aboveFloor=\(aboveFloor.count) top=\(aboveFloor.prefix(3).map { "\($0.id):\(String(format: "%.4f", $0.score))" }.joined(separator: ","))", .debug)
        // Rollup only, not a per-item dump — see QueryService's matching comment.
        log("retrieval droppedByFloor=\(fused.count - aboveFloor.count) floor=\(relevanceFloor)", .debug)

        let scoreForID = Dictionary(uniqueKeysWithValues: aboveFloor.map { ($0.id, $0.score) })
        return try store.chunks(ids: aboveFloor.map(\.id))
            .map { chunk -> ContextChunk in
                var scored = chunk
                scored.score = scoreForID[chunk.chunkID] ?? 0
                return scored
            }
            .filter { !excludingMessageIDs.contains($0.messageID) }
    }
}
