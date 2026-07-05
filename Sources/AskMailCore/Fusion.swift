import Foundation

/// Reciprocal Rank Fusion of the vector and keyword result lists (docs/defaults.md).
public enum Fusion {

    /// Fuses ranked lists. Ranks are 1-based; each list contributes
    /// `1 / (k + rank)` per item. Ties break by first appearance for stability.
    public static func reciprocalRankFusion<ID: Hashable>(
        _ rankings: [[ID]],
        k: Double = Defaults.rrfK
    ) -> [(id: ID, score: Double)] {
        var scores: [ID: Double] = [:]
        var firstSeen: [ID: Int] = [:]
        var counter = 0

        for ranking in rankings {
            for (index, id) in ranking.enumerated() {
                scores[id, default: 0] += 1.0 / (k + Double(index + 1))
                if firstSeen[id] == nil {
                    firstSeen[id] = counter
                    counter += 1
                }
            }
        }

        return scores
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return firstSeen[lhs.key]! < firstSeen[rhs.key]!
            }
            .map { (id: $0.key, score: $0.value) }
    }
}
