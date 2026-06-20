import Foundation

// Iris's ranking core - the "rank" half of the one classify-and-rank primitive
// (see .claude/plans/iris-signals-classify-rank.md and DECISIONS.md 2026-06-20).
//
// Salience answers one question for every piece of info: how much should this
// rise right now? It folds the magnitudes the senses were each computing alone -
// novelty (is this new vs what I just saw?), base importance (what KIND of thing
// is it, and how stale?), and query relevance (does it touch what is live now?) -
// into ONE ranking implementation instead of four scattered ones.
//
// Pure, deterministic, on-device. The eye loop's change gate calls novelty() in
// here (folded out of Eye); the day-brief orders the agenda by base() salience.
enum Salience {

    // The KIND of thing a signal carries. An action (something to do) outranks a
    // fact (something to remember) outranks a passive observation, all else equal.
    enum Kind {
        case action       // a task - something to do
        case question     // a query awaiting an answer
        case fact         // a note - something worth remembering
        case observation  // something seen/heard, making no demand

        var weight: Double {
            switch self {
            case .action:      return 0.60
            case .question:    return 0.45
            case .fact:        return 0.35
            case .observation: return 0.25
            }
        }
    }

    // Base importance, precomputed at ingest: KIND weight plus a mild staleness
    // boost (an open task nags harder the longer it sits). In [0, 1]. halfLifeDays
    // sets how fast the staleness boost saturates; it never overwhelms the kind.
    static func base(kind: Kind, age: TimeInterval, halfLifeDays: Double = 7) -> Double {
        let days = max(0, age) / 86_400
        let staleness = 1 - pow(0.5, days / max(0.0001, halfLifeDays))
        return clamp(kind.weight + 0.25 * staleness)
    }

    // Query-time relevance: how close is this to what is live right now. Reuses the
    // one cosine every vector store shares (TextEmbedder.cosine). A negative cosine
    // clamps to 0 ("unrelated", not "anti-related"). In [0, 1].
    static func relevance(of vector: [Double], to context: [Double]) -> Double {
        clamp(TextEmbedder.cosine(vector, context))
    }

    // Novelty = 1 - cosine(current, centroid of recent). 1.0 when there is no
    // history yet, so the first thing always reads as new. Folded out of Eye so the
    // change gate and any future signal share ONE definition.
    static func novelty(of vector: [Double], against recent: [[Double]]) -> Double {
        guard !recent.isEmpty else { return 1.0 }
        let dims = vector.count
        guard dims > 0 else { return 1.0 }
        var centroid = [Double](repeating: 0, count: dims)
        for v in recent {
            for i in 0..<min(dims, v.count) { centroid[i] += v[i] }
        }
        for i in 0..<dims { centroid[i] /= Double(recent.count) }
        return 1 - TextEmbedder.cosine(vector, centroid)
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
}
