import CryptoKit
import Foundation

// The owner's enrolled voiceprint template (tier 2): a 192-dim L2-normalized ECAPA
// embedding that runtime audio is matched against by cosine similarity. BIOMETRIC -
// sealed to the device Secure Enclave key via EnclaveBox (AES-256-GCM, never
// plaintext, never logged), in its own crypto scope. Single file under the encrypted
// store; reset wipes it.

@available(macOS 14.0, *)
struct VoiceprintStore {
    private let box: EnclaveBox
    private let url: URL

    // Recommended decision threshold (README proof: same 0.72-0.88, diff 0.03-0.37).
    // Conservative so a stranger/music is never accepted as the owner; env-tunable.
    static var threshold: Float {
        Float(ProcessInfo.processInfo.environment["IRIS_VOICEPRINT_THRESHOLD"] ?? "") ?? 0.55
    }

    init() throws {
        let key = try EnclaveKey.loadOrCreate()
        self.box = EnclaveBox(key: key, salt: "sonar-dictate.voiceprint", info: "owner-template-v1")
        self.url = SecureStore.baseDir.appendingPathComponent("voiceprint/owner.template.enc")
    }

    var isEnrolled: Bool { FileManager.default.fileExists(atPath: url.path) }

    func save(_ template: [Float]) throws {
        var data = Data(capacity: template.count * 4)
        for f in template { withUnsafeBytes(of: f.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        let sealed = try box.seal(data)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sealed.write(to: url, options: [.completeFileProtection, .atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func load() throws -> [Float]? {
        guard isEnrolled else { return nil }
        let data = try box.open(try Data(contentsOf: url))
        let count = data.count / 4
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let bits = raw.load(fromByteOffset: i * 4, as: UInt32.self)
                out[i] = Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        return out
    }

    func reset() throws {
        guard isEnrolled else { return }
        // Move to Trash rather than unlink (non-destructive); the file is sealed.
        let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
        if let trash = trash {
            let dst = trash.appendingPathComponent("sonar-dictate-voiceprint-\(UUID().uuidString).enc")
            try? FileManager.default.moveItem(at: url, to: dst)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // Average L2-normalized embeddings into one template (mean, then renormalize).
    // Averaging across windows/utterances is more stable than a single embedding.
    static func template(from embeddings: [[Float]]) -> [Float] {
        guard let dim = embeddings.first?.count, dim > 0 else { return [] }
        var acc = [Float](repeating: 0, count: dim)
        for e in embeddings where e.count == dim {
            for i in 0..<dim { acc[i] += e[i] }
        }
        var norm: Float = 0
        for v in acc { norm += v * v }
        norm = max(norm.squareRoot(), 1e-12)
        return acc.map { $0 / norm }
    }
}
