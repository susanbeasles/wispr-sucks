import Foundation

// Voice-unlock demo (tier 2): seal a secret, reveal it only when the speaker matches
// the enrolled owner voiceprint. The secret is encrypted with the device Secure
// Enclave key (EnclaveBox); the voiceprint is a VERIFIER that gates revealing it
// (app-enforced - voices are fuzzy, not key material). Matches the voiceprint-build
// design. No system-audio grant: mic only.

@available(macOS 14.0, *)
struct VoiceVault {
    private let box: EnclaveBox
    private let url: URL

    init() throws {
        let key = try EnclaveKey.loadOrCreate()
        self.box = EnclaveBox(key: key, salt: "sonar-dictate.voicevault", info: "voice-locked-secret-v1")
        self.url = SecureStore.baseDir.appendingPathComponent("voiceprint/vault.secret.enc")
    }

    var hasSecret: Bool { FileManager.default.fileExists(atPath: url.path) }

    func lock(_ secret: String) throws {
        let sealed = try box.seal(Data(secret.utf8))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sealed.write(to: url, options: [.completeFileProtection, .atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func reveal() throws -> String {
        let data = try box.open(try Data(contentsOf: url))
        return String(decoding: data, as: UTF8.self)
    }

    // Match captured 16k mono audio against the enrolled template. Returns the cosine
    // and whether it clears the owner threshold.
    static func match(_ audio: [Float], embedder: VoiceEmbedder, template: [Float]) throws -> (cosine: Float, ok: Bool) {
        let emb = try embedder.embed(audio)
        let cos = VoiceEmbedder.cosine(emb, template)
        return (cos, cos >= VoiceprintStore.threshold)
    }
}
