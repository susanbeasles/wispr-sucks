import Foundation

// Owner-routed sealed ledgers - the structural wall between Sonar's data and
// Susan's (see .claude/plans/iris-sealed-ledger-offsite.md). ONE brain, but raw
// is partitioned by OWNER, and the owner picks the SEAL:
//   - company  -> Enclave seal (device-bound, never replicated)
//   - personal -> recoverable seal (his, backed up)
//   - brain    -> recoverable seal (the learnings - Susan's, backed up)
// Routing is total and explicit: a record cannot land in the wrong seal.
enum DataOwner: String, Codable, CaseIterable {
    case company    // Sonar's raw: secrets / PHI / business-ops. Enclave-sealed.
    case personal   // his own raw. Recoverable-sealed, backed up.
    case brain      // the one brain's learnings (abstractions only). Recoverable.
}

// What ingest serializes as a record's payload, so provenance ("where it came
// from") is stored and is available to the RAG index later. The ledger itself
// stays generic; this is the agreed shape of what rides inside.
struct TaggedRecord: Codable {
    let at: Date
    let owner: DataOwner       // routes the seal
    let source: String         // provenance: "dictation" | "eye" | "slack" | ...
    let kind: String           // observation | action | fact | question
    let topic: String?
    let tags: [String]
    let text: String           // the already-scrubbed content
}

final class Ledgers {
    private let chains: [DataOwner: SealedLedger]

    init(dir: URL, enclave: EnclaveWrap, recoverable: RecoverableWrap) throws {
        // company -> Enclave; personal + brain -> recoverable.
        chains = [
            .company:  try SealedLedger(name: "company",  wrap: enclave,     dir: dir),
            .personal: try SealedLedger(name: "personal", wrap: recoverable, dir: dir),
            .brain:    try SealedLedger(name: "brain",     wrap: recoverable, dir: dir),
        ]
    }

    private func chain(_ owner: DataOwner) -> SealedLedger {
        // Total over DataOwner - every case is constructed in init.
        chains[owner]!
    }

    // Append a tagged record to the chain its OWNER selects.
    @discardableResult
    func append(_ record: TaggedRecord) throws -> UInt64 {
        let payload = try Self.encoder.encode(record)
        return try chain(record.owner).append(kind: record.kind, payload: payload)
    }

    func verify(_ owner: DataOwner) throws { try chain(owner).verify() }

    func height(_ owner: DataOwner) -> UInt64 { chain(owner).height }

    func head(_ owner: DataOwner) -> ChainHead { chain(owner).head }

    // Verify a chain ends at exactly an anchored head (truncation/fork detection).
    func verify(_ owner: DataOwner, expecting anchor: ChainHead) throws {
        try chain(owner).verify(expecting: anchor)
    }

    // Decode the chain back to its tagged records (the restore/read path).
    func records(_ owner: DataOwner) throws -> [TaggedRecord] {
        try chain(owner).entries().map { try Self.decoder.decode(TaggedRecord.self, from: $0.payload) }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
