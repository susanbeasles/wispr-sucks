import Foundation

// The learning gate: the wall is not just storage, it is what may BECOME a
// learning. A learning is a bounded, typed ABSTRACTION - never raw. This gate is
// what makes "she learns from the work side, the company's raw never becomes
// personal bytes" structural: only gate-admitted abstractions reach the brain
// chain. (See .claude/plans/iris-sealed-ledger-offsite.md.)

enum LearningKind: String, Codable {
    case gist        // a one-line summary
    case keyPhrase   // a salient phrase / term
    case preference  // "Tony prefers X"
    case relation    // "project A relates to B"
    case weight      // a salience adjustment
}

struct Learning: Codable {
    let kind: LearningKind
    let text: String           // the abstraction - short, bounded
    let about: [String]        // entities it concerns
    let sourceOwner: DataOwner // provenance (where it was learned), NOT the data
}

// What proposes learnings (an LLM / Apple model later; injected so it is fakeable
// in tests). The deriver only PROPOSES; the gate decides what crosses.
protocol LearningDeriver {
    func learnings(from record: TaggedRecord) -> [Learning]
}

enum LearningGate {
    // A learning longer than this is suspicious - abstractions are short.
    static let maxChars = 200
    // A contiguous lift of this many words from the source is too verbatim.
    static let maxRunWords = 6
    // ...or this fraction of the learning being a contiguous lift - but only once
    // the run is at least minRunForFraction, so naming the same subject (a 1-2
    // word entity overlap) is allowed; a substantial partial lift is not.
    static let maxRunFraction = 0.5
    static let minRunForFraction = 3

    // Admit only genuine abstractions of `raw`; drop anything that reproduces it.
    // Conservative: when in doubt, DROP.
    static func admit(_ proposed: [Learning], from raw: TaggedRecord) -> [Learning] {
        proposed.filter { isAbstraction($0, of: raw.text) }
    }

    // True iff `learning` is a bounded abstraction, not a lift of `rawText`.
    static func isAbstraction(_ learning: Learning, of rawText: String) -> Bool {
        let text = learning.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxChars else { return false }

        let normLearn = normalize(text)
        let normRaw = normalize(rawText)
        // Direct substring lift -> not an abstraction.
        if !normLearn.isEmpty, normRaw.contains(normLearn) { return false }

        // Longest contiguous run of words shared with the source.
        let lw = words(text)
        guard !lw.isEmpty else { return false }
        let run = longestContiguousRun(lw, in: words(rawText))
        if run >= maxRunWords { return false }
        if run >= minRunForFraction, Double(run) >= maxRunFraction * Double(lw.count) { return false }
        return true
    }

    // MARK: - Helpers

    private static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    // Longest run of consecutive `needle` words that appears consecutively in
    // `haystack`. O(needle * haystack) - inputs are small (learnings are short).
    private static func longestContiguousRun(_ needle: [String], in haystack: [String]) -> Int {
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
        var best = 0
        for i in needle.indices {
            for j in haystack.indices where haystack[j] == needle[i] {
                var run = 0
                while i + run < needle.count, j + run < haystack.count,
                      needle[i + run] == haystack[j + run] {
                    run += 1
                }
                if run > best { best = run }
            }
        }
        return best
    }
}
