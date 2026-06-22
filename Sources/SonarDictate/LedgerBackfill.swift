import Foundation

// One-time backfill: seal her EXISTING perception history into the owner-routed
// ledger, so what she already knew gets the same protection as new intake
// (tamper-evident, recoverable, backup-eligible). Idempotent via a marker file -
// runs at most once.
//
// Uses the SYNCHRONOUS Ingest (no model enrichment, no learning derivation): a
// bulk pass over up to a few thousand entries must not hammer the local model;
// it just scrubs, classifies by owner, and seals the raw. Sequential so it does
// not spawn a swarm of scrubber subprocesses at once. Best-effort.
enum LedgerBackfill {
    // History item shape, decoupled from PerceptionMemory for testability.
    struct Item { let at: Date; let summary: String; let kind: String? }

    // A perception entry's kind decides provenance: screen observations are
    // company-by-default (the safe seal); everything else (what you said/asked) is
    // personal. The classifier can still escalate personal -> company.
    static func provenance(forKind kind: String?) -> DataOwner {
        kind == "observation" ? .company : .personal
    }

    // Seal each item; returns how many were sealed. Synchronous + sequential.
    @discardableResult
    static func seal(_ items: [Item], into ledgers: Ledgers, scrub: Scrubber) -> Int {
        var sealed = 0
        for it in items {
            let text = it.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let item = SourceItem(
                source: "history-\(it.kind ?? "note")",
                provenance: provenance(forKind: it.kind),
                at: it.at, text: text, externalId: nil)
            if (try? Ingest.ingest(item, scrub: scrub, into: ledgers)) != nil { sealed += 1 }
        }
        return sealed
    }

    // Run once: guarded by a marker in the ledger dir. Returns the count sealed
    // (0 if already run). Best-effort - any failure leaves the marker unset so a
    // later launch can retry.
    @discardableResult
    static func runOnce(_ items: [Item], into ledgers: Ledgers, scrub: Scrubber, dir: URL) -> Int {
        let marker = dir.appendingPathComponent(".history-backfilled")
        if FileManager.default.fileExists(atPath: marker.path) { return 0 }
        let n = seal(items, into: ledgers, scrub: scrub)
        try? Data().write(to: marker)
        return n
    }
}
