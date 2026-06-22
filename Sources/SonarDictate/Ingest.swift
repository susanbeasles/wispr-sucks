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
    // Deterministic ingest: scrub -> verdict (owner/kind) -> persist. No model.
    @discardableResult
    static func ingest(_ item: SourceItem, scrub: Scrubber, into ledgers: Ledgers) throws -> TaggedRecord {
        let clean = scrub.scrub(item.text)
        let v = Classifier.verdict(text: clean, source: item.source, provenance: item.provenance)
        return try persist(clean: clean, verdict: v, item: item, into: ledgers)
    }

    // Enriched ingest (the live path): same deterministic owner/kind, plus
    // best-effort model topic/about/tags filled in BEFORE persist (records are
    // append-only - enrichment cannot happen after). Enrichment never affects
    // owner/kind, so the wall stays deterministic.
    @discardableResult
    static func ingestEnriched(_ item: SourceItem, scrub: Scrubber, into ledgers: Ledgers) async throws -> TaggedRecord {
        let clean = scrub.scrub(item.text)
        var v = Classifier.verdict(text: clean, source: item.source, provenance: item.provenance)
        let meta = await Classifier.enrich(clean)
        v.topic = meta.topic; v.about = meta.about; v.tags = meta.tags
        return try persist(clean: clean, verdict: v, item: item, into: ledgers)
    }

    private static func persist(clean: String, verdict v: Verdict, item: SourceItem,
                                into ledgers: Ledgers) throws -> TaggedRecord {
        let record = TaggedRecord(
            at: item.at, owner: v.owner, source: item.source,
            kind: v.kind.label, topic: v.topic, tags: v.tags, text: clean
        )
        try ledgers.append(record)
        return record
    }

    // Derive learnings from a stored record and admit them into the ONE brain
    // chain - the loop that fills her brain. The deriver proposes; the gate keeps
    // only abstractions (raw - company OR personal - can never cross). Learnings
    // are Susan's regardless of which owner they were learned from, so they land in
    // the recoverable `brain` chain. Returns how many crossed.
    @discardableResult
    static func learn(from record: TaggedRecord, using deriver: LearningDeriver,
                      into ledgers: Ledgers) async throws -> Int {
        let proposed = await deriver.learnings(from: record)
        let admitted = LearningGate.admit(proposed, from: record)
        for l in admitted {
            try ledgers.append(TaggedRecord(
                at: Date(), owner: .brain, source: "learning:\(record.source)",
                kind: "fact", topic: nil, tags: l.about, text: l.text
            ))
        }
        return admitted.count
    }
}
