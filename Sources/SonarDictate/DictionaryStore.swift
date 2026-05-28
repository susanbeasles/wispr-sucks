import Foundation
import CryptoKit

// On-device personal dictionary — the personalization moat. A growing, weighted
// list of the terms THIS user cares about (their jargon, names, acronyms, and —
// the high-value ones — their corrections) that biases the recognizer toward
// getting their words right. This is the half that beats Wispr: not raw speed
// (we already win that), but learning that never leaves the machine.
//
// Two sources feed it:
//   - manual:     `sonar-dictate dict add "<term>"`
//   - correction: an edit to a dictation is an implicit thumbs-down on what we
//     heard; the corrected term gets added with high weight via learnCorrection.
//     (The edit-capture loop that calls this is phase 2; the store is ready now.)
//
// Weight ranks terms so the strongest signals (corrections, repeated use) survive
// when we cap the contextual-bias list handed to the recognizer. Unlike the RAG
// bias — which is half-blind and will happily reinforce a misheard word — the
// dictionary is curated/corrected, so it teaches the RIGHT terms.
//
// Stored encrypted under the same Secure Enclave key as the recordings
// (dictionary.enc), same ECDH + HKDF-SHA256 + AES-GCM envelope as RAGIndex.
// 100% on-device. No network, ever.

struct DictionaryEntry: Codable {
    var term: String
    var weight: Double          // higher = stronger bias; corrections boost it
    var appContext: String?     // optional bundle-ID scope
    var source: String          // DictionarySource raw value
    var addedAt: Date
    var lastUsedAt: Date
}

enum DictionarySource: String {
    case manual
    case correction
    case frequency
}

final class DictionaryStore {
    private static let fileName = "dictionary.enc"
    private static let salt = "__sonar_dictate_dictionary__"
    private static let info = "sonar-dictate.v1.dictionary"

    private let key: SecureEnclave.P256.KeyAgreement.PrivateKey
    private let fileURL: URL
    private let queue = DispatchQueue(label: "sonar-dictate.dictionary")

    // Keyed by lowercased term so adds/removes are case-insensitive.
    private var entries: [String: DictionaryEntry] = [:]

    init() throws {
        // Reuse the recordings' encrypted base dir + Secure Enclave key.
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
        self.fileURL = baseDir.appendingPathComponent(Self.fileName)
        self.entries = (try? loadAll()) ?? [:]
    }

    // MARK: - Public API

    var count: Int { queue.sync { entries.count } }

    // Add or reinforce a term. Repeated adds accumulate weight (so frequency
    // naturally ranks terms up). Returns false only for empty input.
    @discardableResult
    func add(_ term: String, weight: Double = 1, appContext: String? = nil, source: DictionarySource = .manual) -> Bool {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let k = t.lowercased()
        queue.sync {
            if var e = entries[k] {
                e.weight += weight
                e.lastUsedAt = Date()
                if e.appContext == nil { e.appContext = appContext }
                entries[k] = e
            } else {
                entries[k] = DictionaryEntry(
                    term: t,
                    weight: weight,
                    appContext: appContext,
                    source: source.rawValue,
                    addedAt: Date(),
                    lastUsedAt: Date()
                )
            }
        }
        try? persist()
        return true
    }

    // Learn from a correction: the user changed `wrong` → `right`. The corrected
    // term is a strong positive signal (the implicit thumbs-down made concrete),
    // so it lands with high weight. Called by the edit-capture loop (phase 2).
    func learnCorrection(from wrong: String, to right: String, appContext: String? = nil) {
        add(right, weight: 3, appContext: appContext, source: .correction)
    }

    // Top terms for the recognizer's contextual bias, scoped to the app when we
    // have enough context-specific entries, else global. Strongest weight first.
    func terms(forContext appContext: String?, limit: Int = 100) -> [String] {
        queue.sync {
            let all = Array(entries.values)
            let pool: [DictionaryEntry]
            if let appContext = appContext {
                let scoped = all.filter { $0.appContext == appContext }
                pool = scoped.count >= 8 ? scoped : all
            } else {
                pool = all
            }
            return pool.sorted { $0.weight > $1.weight }.prefix(limit).map { $0.term }
        }
    }

    func list() -> [DictionaryEntry] {
        queue.sync { entries.values.sorted { $0.weight > $1.weight } }
    }

    @discardableResult
    func remove(_ term: String) -> Bool {
        let k = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let removed: Bool = queue.sync { entries.removeValue(forKey: k) != nil }
        if removed { try? persist() }
        return removed
    }

    func wipe() {
        queue.sync { entries.removeAll() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Encrypted persistence (same envelope as RAGIndex)

    private func loadAll() throws -> [String: DictionaryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let blob = try Data(contentsOf: fileURL)
        guard !blob.isEmpty else { return [:] }
        let plain = try decrypt(blob: blob)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let arr = try decoder.decode([DictionaryEntry].self, from: plain)
        var map: [String: DictionaryEntry] = [:]
        for e in arr { map[e.term.lowercased()] = e }
        return map
    }

    private func persist() throws {
        let snapshot: [DictionaryEntry] = queue.sync { Array(entries.values) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plain = try encoder.encode(snapshot)
        let blob = try encrypt(plaintext: plain)
        try blob.write(to: fileURL, options: [.completeFileProtection, .atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func encrypt(plaintext: Data) throws -> Data {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try key.sharedSecretFromKeyAgreement(with: ephemeral.publicKey)
        let derived = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(Self.salt.utf8),
            sharedInfo: Data(Self.info.utf8),
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
            salt: Data(Self.salt.utf8),
            sharedInfo: Data(Self.info.utf8),
            outputByteCount: 32
        )
        let sealed = try AES.GCM.SealedBox(combined: sealedBytes)
        return try AES.GCM.open(sealed, using: derived)
    }
}
