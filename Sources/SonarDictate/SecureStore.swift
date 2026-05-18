import Foundation
import CryptoKit

// On-disk encrypted recording store.
//
// Layout:
//   ~/Library/Application Support/SonarDictate/recordings/
//     device.enclave-key                # Secure Enclave key data representation (0600)
//     .metadata_never_index             # tells Spotlight to skip this dir
//     index.enc                         # encrypted JSON manifest of recordings
//     {uuid}.wav.enc                    # encrypted PCM/WAV audio (0600)
//     {uuid}.txt.enc                    # encrypted transcript (0600)
//
// Crypto:
//   - Per-app Secure Enclave P256 keypair. The private half never leaves the
//     Enclave; only an opaque dataRepresentation lives on disk, useless on
//     any other device.
//   - Each file gets a per-recording symmetric key derived via ECDH between
//     the SE key and a fresh ephemeral keypair, then HKDF-SHA256 (salt =
//     recording ID, info = "sonar-dictate.v1.file"). The ephemeral public
//     key is prepended to the ciphertext. AES-256-GCM via CryptoKit.
//   - Reset wipes the entire directory including the key, making any stale
//     ciphertext permanently unrecoverable.
//
// All files written 0600. Directory 0700.

struct RecordingMetadata: Codable {
    let id: String
    let createdAt: Date
    let durationSeconds: Double
    let appContext: String?
    let transcriptPreview: String
}

enum SecureStoreError: Error, CustomStringConvertible {
    case secureEnclaveUnavailable
    case malformedCiphertext
    case noSuchRecording(String)

    var description: String {
        switch self {
        case .secureEnclaveUnavailable: return "Secure Enclave is not available on this Mac"
        case .malformedCiphertext: return "ciphertext is malformed or truncated"
        case .noSuchRecording(let id): return "no recording with id \(id)"
        }
    }
}

final class SecureStore {
    static let baseDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("SonarDictate/recordings", isDirectory: true)
    }()

    private static let keyFileName = "device.enclave-key"
    private static let indexFileName = "index.enc"
    private static let indexSalt = "__sonar_dictate_index__"

    private let key: SecureEnclave.P256.KeyAgreement.PrivateKey

    init() throws {
        try Self.ensureDir()

        let keyURL = Self.baseDir.appendingPathComponent(Self.keyFileName)
        if FileManager.default.fileExists(atPath: keyURL.path) {
            let rep = try Data(contentsOf: keyURL)
            self.key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: rep)
        } else {
            guard SecureEnclave.isAvailable else {
                throw SecureStoreError.secureEnclaveUnavailable
            }
            let newKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            try newKey.dataRepresentation.write(to: keyURL, options: [.completeFileProtection, .atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
            self.key = newKey
        }
    }

    // MARK: - Public API

    @discardableResult
    func write(audio: Data, transcript: String, appContext: String?, durationSeconds: Double) throws -> String {
        let id = UUID().uuidString.lowercased()
        let audioURL = Self.baseDir.appendingPathComponent("\(id).wav.enc")
        let textURL  = Self.baseDir.appendingPathComponent("\(id).txt.enc")

        let audioBlob = try encrypt(plaintext: audio, salt: id)
        let textBlob  = try encrypt(plaintext: Data(transcript.utf8), salt: id)

        try audioBlob.write(to: audioURL, options: [.completeFileProtection, .atomic])
        try textBlob.write(to: textURL,   options: [.completeFileProtection, .atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audioURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: textURL.path)

        var idx = try loadIndex()
        let preview = String(transcript.prefix(200))
        idx.append(RecordingMetadata(
            id: id,
            createdAt: Date(),
            durationSeconds: durationSeconds,
            appContext: appContext,
            transcriptPreview: preview
        ))
        try saveIndex(idx)
        return id
    }

    func list() throws -> [RecordingMetadata] {
        return try loadIndex().sorted { $0.createdAt > $1.createdAt }
    }

    func read(_ id: String) throws -> (audio: Data, transcript: String) {
        let audioURL = Self.baseDir.appendingPathComponent("\(id).wav.enc")
        let textURL  = Self.baseDir.appendingPathComponent("\(id).txt.enc")
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw SecureStoreError.noSuchRecording(id)
        }
        let audioBlob = try Data(contentsOf: audioURL)
        let textBlob  = try Data(contentsOf: textURL)
        let audio = try decrypt(blob: audioBlob, salt: id)
        let textData = try decrypt(blob: textBlob, salt: id)
        guard let transcript = String(data: textData, encoding: .utf8) else {
            throw SecureStoreError.malformedCiphertext
        }
        return (audio, transcript)
    }

    func delete(_ id: String) throws {
        let audioURL = Self.baseDir.appendingPathComponent("\(id).wav.enc")
        let textURL  = Self.baseDir.appendingPathComponent("\(id).txt.enc")
        try? FileManager.default.removeItem(at: audioURL)
        try? FileManager.default.removeItem(at: textURL)

        var idx = try loadIndex()
        idx.removeAll { $0.id == id }
        try saveIndex(idx)
    }

    // Hardened reset: removes the entire directory including the Secure
    // Enclave key. Any pre-existing ciphertext on backups or snapshots is
    // permanently unrecoverable after this.
    func reset() throws {
        if FileManager.default.fileExists(atPath: Self.baseDir.path) {
            try FileManager.default.removeItem(at: Self.baseDir)
        }
        try Self.ensureDir()
    }

    // MARK: - Internals

    private static func ensureDir() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: baseDir.path) {
            try fm.createDirectory(
                at: baseDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDir.path)
        }
        let marker = baseDir.appendingPathComponent(".metadata_never_index")
        if !fm.fileExists(atPath: marker.path) {
            try Data().write(to: marker)
        }
    }

    private func encrypt(plaintext: Data, salt: String) throws -> Data {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try key.sharedSecretFromKeyAgreement(with: ephemeral.publicKey)
        let derived = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(salt.utf8),
            sharedInfo: Data("sonar-dictate.v1.file".utf8),
            outputByteCount: 32
        )
        let sealed = try AES.GCM.seal(plaintext, using: derived)
        guard let combined = sealed.combined else {
            throw SecureStoreError.malformedCiphertext
        }

        // [4-byte BE eph pub key length][eph pub key raw][AES.GCM.combined]
        let pubBytes = ephemeral.publicKey.rawRepresentation
        var blob = Data()
        var len = UInt32(pubBytes.count).bigEndian
        blob.append(Data(bytes: &len, count: 4))
        blob.append(pubBytes)
        blob.append(combined)
        return blob
    }

    private func decrypt(blob: Data, salt: String) throws -> Data {
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
            salt: Data(salt.utf8),
            sharedInfo: Data("sonar-dictate.v1.file".utf8),
            outputByteCount: 32
        )
        let sealed = try AES.GCM.SealedBox(combined: sealedBytes)
        return try AES.GCM.open(sealed, using: derived)
    }

    private func loadIndex() throws -> [RecordingMetadata] {
        let url = Self.baseDir.appendingPathComponent(Self.indexFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let blob = try Data(contentsOf: url)
        guard !blob.isEmpty else { return [] }
        let plain = try decrypt(blob: blob, salt: Self.indexSalt)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([RecordingMetadata].self, from: plain)
    }

    private func saveIndex(_ records: [RecordingMetadata]) throws {
        let url = Self.baseDir.appendingPathComponent(Self.indexFileName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plain = try encoder.encode(records)
        let blob = try encrypt(plaintext: plain, salt: Self.indexSalt)
        try blob.write(to: url, options: [.completeFileProtection, .atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
