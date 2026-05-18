import Foundation
import NaturalLanguage
import CryptoKit

// Local RAG index over the user's encrypted recording corpus.
//
// Apple does the work:
//   - NLContextualEmbedding (on-device, free, fast) produces a vector per
//     transcript. We mean-pool the per-token vectors into one document vector.
//   - Cosine similarity over the (small, in-memory) index is sub-millisecond
//     for tens of thousands of recordings.
//
// What "getting better" means in practice:
//   - At the start of each dictation session, we look up similar past
//     transcripts and feed their proper-nouns + identifiers into the
//     recognizer's `contextualStrings`. The recognizer biases toward
//     words the user has actually said before. No training, no telemetry,
//     just retrieval from their own data.
//   - Downstream layers (Foundation Models cleanup, action expansion)
//     can also query the index for few-shot context.
//
// Index storage: one encrypted JSON file (rag-index.enc) alongside the
// recordings, under the same Secure Enclave key. Vectors are doubles.
// For 10k recordings × 512 dims × 8 bytes ≈ 40MB on disk, fits easily
// in memory.

struct RAGEntry: Codable {
    let id: String              // matches RecordingMetadata.id
    let vector: [Double]        // mean-pooled NLContextualEmbedding vector
    let preview: String         // short snippet for surfacing in queries
    let appContext: String?     // bundle ID, for context-aware retrieval
    let createdAt: Date
}

struct RAGHit {
    let entry: RAGEntry
    let score: Double           // cosine similarity, [-1, 1]
}

enum RAGError: Error, CustomStringConvertible {
    case embeddingUnavailable
    case embeddingAssetsNotReady
    case embeddingFailed

    var description: String {
        switch self {
        case .embeddingUnavailable:     return "NLContextualEmbedding is not available for this language on this OS"
        case .embeddingAssetsNotReady:  return "NLContextualEmbedding assets are still downloading; try again shortly"
        case .embeddingFailed:          return "failed to compute embedding"
        }
    }
}

final class RAGIndex {
    private static let indexFileName = "rag-index.enc"
    private static let indexSalt = "__sonar_dictate_rag_index__"

    private let embedding: NLContextualEmbedding
    private let key: SecureEnclave.P256.KeyAgreement.PrivateKey
    private let indexURL: URL
    private let queue = DispatchQueue(label: "sonar-dictate.rag", qos: .utility)

    private var entries: [RAGEntry] = []

    init() throws {
        // Embedding model. macOS 14+ ships NLContextualEmbedding. Assets are
        // provisioned opportunistically by the OS — we don't force a download
        // here; we just gate on `hasAvailableAssets` and gracefully no-op
        // until the system has the model loaded.
        guard let emb = NLContextualEmbedding(language: .english) else {
            throw RAGError.embeddingUnavailable
        }
        try? emb.load()
        self.embedding = emb

        // Reuse the same encrypted store + Secure Enclave key.
        let baseDir = SecureStore.baseDir
        if !FileManager.default.fileExists(atPath: baseDir.path) {
            try FileManager.default.createDirectory(
                at: baseDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let keyURL = baseDir.appendingPathComponent("device.enclave-key")
        if FileManager.default.fileExists(atPath: keyURL.path) {
            let rep = try Data(contentsOf: keyURL)
            self.key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: rep)
        } else {
            guard SecureEnclave.isAvailable else { throw SecureStoreError.secureEnclaveUnavailable }
            let newKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            try newKey.dataRepresentation.write(to: keyURL, options: [.completeFileProtection, .atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
            self.key = newKey
        }

        self.indexURL = baseDir.appendingPathComponent(Self.indexFileName)
        self.entries = (try? loadAll()) ?? []
    }

    // MARK: - Public API

    var count: Int { entries.count }

    var assetsReady: Bool { embedding.hasAvailableAssets }

    // Ingest a recording. Embeds the transcript, appends to the in-memory
    // index, and persists encrypted to disk. Designed to be called from
    // the background persistence path.
    func add(id: String, transcript: String, appContext: String?, createdAt: Date) throws {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let vector = try meanPooledEmbedding(of: transcript)
        let preview = String(transcript.prefix(160))
        let entry = RAGEntry(
            id: id,
            vector: vector,
            preview: preview,
            appContext: appContext,
            createdAt: createdAt
        )
        queue.sync {
            self.entries.append(entry)
        }
        try persist()
    }

    // Top-K nearest entries by cosine similarity. Optionally filtered by
    // app context (bundle ID) so vocabulary biasing stays scoped to the
    // app the user is currently dictating into.
    func query(_ text: String, k: Int = 8, appContext: String? = nil) throws -> [RAGHit] {
        guard !entries.isEmpty else { return [] }
        let q = try meanPooledEmbedding(of: text)
        let pool: [RAGEntry]
        if let appContext = appContext {
            let scoped = entries.filter { $0.appContext == appContext }
            // Fall back to the global pool if the per-app pool is too thin.
            pool = scoped.count >= k ? scoped : entries
        } else {
            pool = entries
        }
        let scored = pool.map { RAGHit(entry: $0, score: Self.cosine(q, $0.vector)) }
        return scored.sorted { $0.score > $1.score }.prefix(k).map { $0 }
    }

    // Extract a vocabulary-bias list from the K nearest past transcripts.
    // Heuristic: capitalized tokens + tokens containing digits. Captures
    // proper nouns, acronyms (caps), instance IDs, version strings, etc.
    // Cheap, dictionary-free, no NLTagger overhead.
    func vocabularyBias(forContext appContext: String?, k: Int = 8) throws -> [String] {
        let hits = try query("", k: k, appContext: appContext)  // empty query → fall through to recent
        // For an empty query we get noisy similarity; just use the most-recent
        // entries in the scoped pool as the bias source.
        let scoped: [RAGEntry]
        if let appContext = appContext {
            let s = entries.filter { $0.appContext == appContext }
            scoped = s.count >= k ? s : entries
        } else {
            scoped = entries
        }
        let recent = scoped.sorted { $0.createdAt > $1.createdAt }.prefix(k)
        let texts = recent.map { $0.preview } + hits.map { $0.entry.preview }
        return Self.extractTerms(from: texts)
    }

    // Drops the entire index. The recordings themselves stay; only the
    // RAG cache is rebuilt on next add(). Useful for testing or if the
    // index gets corrupted.
    func reset() throws {
        queue.sync { self.entries.removeAll() }
        try? FileManager.default.removeItem(at: indexURL)
    }

    // MARK: - Embedding

    private func meanPooledEmbedding(of text: String) throws -> [Double] {
        guard embedding.hasAvailableAssets else {
            throw RAGError.embeddingAssetsNotReady
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RAGError.embeddingFailed }

        let result = try embedding.embeddingResult(for: trimmed, language: .english)
        var sum: [Double] = []
        var n = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vec, _ in
            if sum.isEmpty { sum = Array(repeating: 0, count: vec.count) }
            for i in 0..<min(sum.count, vec.count) {
                sum[i] += vec[i]
            }
            n += 1
            return true
        }
        guard n > 0 else { throw RAGError.embeddingFailed }
        for i in 0..<sum.count { sum[i] /= Double(n) }
        return sum
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        let len = min(a.count, b.count)
        guard len > 0 else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<len {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }

    private static func extractTerms(from transcripts: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for transcript in transcripts {
            let raw = transcript.split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" }
            for token in raw {
                let s = String(token)
                guard s.count >= 2 else { continue }
                let firstIsUpper = s.first?.isUppercase == true
                let containsDigit = s.contains(where: { $0.isNumber })
                guard firstIsUpper || containsDigit else { continue }
                if seen.insert(s).inserted { ordered.append(s) }
            }
        }
        return Array(ordered.prefix(200))  // cap so we don't bias the recognizer with noise
    }

    // MARK: - Encrypted persistence

    private func loadAll() throws -> [RAGEntry] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        let blob = try Data(contentsOf: indexURL)
        guard !blob.isEmpty else { return [] }
        let plain = try decrypt(blob: blob)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([RAGEntry].self, from: plain)
    }

    private func persist() throws {
        let snapshot: [RAGEntry] = queue.sync { self.entries }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plain = try encoder.encode(snapshot)
        let blob = try encrypt(plaintext: plain)
        try blob.write(to: indexURL, options: [.completeFileProtection, .atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    private func encrypt(plaintext: Data) throws -> Data {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try key.sharedSecretFromKeyAgreement(with: ephemeral.publicKey)
        let derived = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(Self.indexSalt.utf8),
            sharedInfo: Data("sonar-dictate.v1.rag".utf8),
            outputByteCount: 32
        )
        let sealed = try AES.GCM.seal(plaintext, using: derived)
        guard let combined = sealed.combined else {
            throw SecureStoreError.malformedCiphertext
        }
        let pubBytes = ephemeral.publicKey.rawRepresentation
        var blob = Data()
        var len = UInt32(pubBytes.count).bigEndian
        blob.append(Data(bytes: &len, count: 4))
        blob.append(pubBytes)
        blob.append(combined)
        return blob
    }

    private func decrypt(blob: Data) throws -> Data {
        guard blob.count > 4 else { throw SecureStoreError.malformedCiphertext }
        let lenBE: UInt32 = blob.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        let pubLen = Int(UInt32(bigEndian: lenBE))
        let pubEnd = 4 + pubLen
        guard blob.count > pubEnd else { throw SecureStoreError.malformedCiphertext }
        let pubBytes = blob.subdata(in: 4..<pubEnd)
        let sealedBytes = blob.subdata(in: pubEnd..<blob.count)
        let ephPub = try P256.KeyAgreement.PublicKey(rawRepresentation: pubBytes)
        let shared = try key.sharedSecretFromKeyAgreement(with: ephPub)
        let derived = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(Self.indexSalt.utf8),
            sharedInfo: Data("sonar-dictate.v1.rag".utf8),
            outputByteCount: 32
        )
        let sealed = try AES.GCM.SealedBox(combined: sealedBytes)
        return try AES.GCM.open(sealed, using: derived)
    }
}
