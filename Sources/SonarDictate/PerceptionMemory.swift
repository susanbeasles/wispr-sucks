import Foundation

// The eyes' perceptual memory: an encrypted, on-device vector store of what the
// eyes have noticed. Each ESCALATED tick (a meaningful change) is embedded and
// stored with its situational summary. This is the "cheat code" the owner asked
// for - retrieval by MEANING ("when did that error first appear") instead of
// replaying the timeline linearly. Semantic nearest-neighbor is associative, so
// it jumps straight to the relevant moment; time is not an ordered axis you can
// bisect.
//
// Posture: sealed with the device Secure Enclave key (EnclaveBox), same as the
// RAG index and RecordingDatabase. The summary is PHI-bearing and therefore
// lives ONLY inside this encrypted file - never a cleartext log. Bounded to a
// rolling window so the store cannot grow without limit.

struct PerceptionEntry: Codable {
    let at: Date
    let vector: [Double]   // mean-pooled embedding of the content
    let summary: String    // the remembered content (PHI-bearing; encrypted at rest)
    var kind: String?      // "observation" (what she saw) | "utterance" (what you said) | "reply" (what she said)
    var tags: [String]?    // lightweight classification of the content
}

struct PerceptionHit {
    let entry: PerceptionEntry
    let score: Double      // cosine similarity, [-1, 1]
}

final class PerceptionMemory {
    private static let fileName = "perception.enc"
    private static let salt = "__sonar_dictate_perception__"
    private static let info = "sonar-dictate.v1.perception"
    private static let maxEntries = 2000   // rolling window; oldest drop off

    private let box: EnclaveBox
    private let url: URL
    private let queue = DispatchQueue(label: "sonar-dictate.perception", qos: .utility)
    private var entries: [PerceptionEntry] = []

    init() throws {
        let key = try EnclaveKey.loadOrCreate()
        self.box = EnclaveBox(key: key, salt: Self.salt, info: Self.info)
        self.url = SecureStore.baseDir.appendingPathComponent(Self.fileName)
        self.entries = (try? loadAll()) ?? []
    }

    var count: Int { queue.sync { entries.count } }

    // A snapshot of every stored entry (oldest first) - used by the one-time
    // ledger backfill to seal her existing history.
    func all() -> [PerceptionEntry] { queue.sync { entries } }

    // Append a memory and persist. Used by the silent eye loop (observations) and
    // the conversation (utterances + replies).
    func add(at: Date, vector: [Double], summary: String, kind: String, tags: [String] = []) throws {
        let entry = PerceptionEntry(at: at, vector: vector, summary: summary, kind: kind, tags: tags)
        queue.sync {
            entries.append(entry)
            if entries.count > Self.maxEntries {
                entries.removeFirst(entries.count - Self.maxEntries)
            }
        }
        try persist()
    }

    // Top-K moments closest in meaning to the query vector. The recall path.
    func recall(vector: [Double], k: Int = 5) -> [PerceptionHit] {
        let snapshot = queue.sync { entries }
        guard !snapshot.isEmpty else { return [] }
        return snapshot
            .map { PerceptionHit(entry: $0, score: TextEmbedder.cosine(vector, $0.vector)) }
            .sorted { $0.score > $1.score }
            .prefix(k)
            .map { $0 }
    }

    func reset() throws {
        queue.sync { entries.removeAll() }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Encrypted persistence

    private func loadAll() throws -> [PerceptionEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let blob = try Data(contentsOf: url)
        guard !blob.isEmpty else { return [] }
        let plain = try box.open(blob)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PerceptionEntry].self, from: plain)
    }

    private func persist() throws {
        let snapshot = queue.sync { entries }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plain = try encoder.encode(snapshot)
        let blob = try box.seal(plain)
        try blob.write(to: url, options: [.completeFileProtection, .atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
