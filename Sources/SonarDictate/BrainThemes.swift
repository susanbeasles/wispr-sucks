import Foundation

// A consolidation VIEW over the brain: which themes (the entities a learning is
// about, stored in a brain record's tags) recur most. Deterministic - no model,
// no mutation. Answers "what has she learned about most" at a glance.
enum BrainThemes {
    static func top(_ records: [TaggedRecord], limit: Int = 8) -> [(theme: String, count: Int)] {
        var counts: [String: Int] = [:]
        for r in records {
            for tag in r.tags {
                let t = tag.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                counts[t, default: 0] += 1
            }
        }
        // Most frequent first; ties broken alphabetically for stable output.
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { (theme: $0.key, count: $0.value) }
    }
}
