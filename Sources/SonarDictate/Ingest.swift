import Foundation

// The ONE ingest pipeline every source funnels through (see
// .claude/plans/iris-sources-ingest.md). A source's only job is to produce
// SourceItems; this does the rest: scrub -> classify -> route to the owner's
// sealed chain. No per-source workflow.

struct SourceItem {
    let source: String          // provenance label: "dictation" | "eye" | "slack" | ...
    let provenance: DataOwner   // origin owner (the source knows: SonarMD-Slack = company)
    let at: Date
    let text: String
    let externalId: String?     // for dedup / cursors later
}

// Removes PHI before anything persists - the mandatory gate. Identity is a TEST
// DOUBLE only; prod wires phi-mask here. Ingest takes a Scrubber as a REQUIRED
// argument (never defaulted), so the gate can never be silently skipped.
protocol Scrubber {
    func scrub(_ text: String) -> String
}

struct IdentityScrubber: Scrubber {   // tests only - NOT a prod default
    func scrub(_ text: String) -> String { text }
}

enum Ingest {
    // scrub -> classify -> route by owner -> persist. Returns the Verdict so the
    // caller can drive memory / learning. The owner the classifier returns picks
    // the seal (Enclave for company, recoverable for personal) - fail-toward-
    // protection means a personal item with a sensitive marker lands in company.
    @discardableResult
    static func ingest(_ item: SourceItem, scrub: Scrubber, into ledgers: Ledgers) throws -> Verdict {
        let clean = scrub.scrub(item.text)
        let v = Classifier.verdict(text: clean, source: item.source, provenance: item.provenance)
        let record = TaggedRecord(
            at: item.at, owner: v.owner, source: item.source,
            kind: v.kind.label, topic: v.topic, tags: v.tags, text: clean
        )
        try ledgers.append(record)
        return v
    }
}
