import CryptoKit
import Foundation

// Shared device-local encryption envelope, extracted from RAGIndex so the eyes'
// PerceptionMemory and the dictation RAG index use ONE crypto implementation
// (not two copies of security-sensitive code).
//
// EnclaveKey: load-or-create the device Secure Enclave key (the same
// device.enclave-key file the rest of the encrypted store uses).
// EnclaveBox: AES-256-GCM with a per-record ephemeral ECDH to that SE key, framed
// as [4-byte BE pubkey length][ephemeral pubkey][GCM combined]. The salt + info
// scope the derived key per store, so different stores never share a keyspace.

enum EnclaveKey {
    static func loadOrCreate() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
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
            return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: rep)
        }
        guard SecureEnclave.isAvailable else { throw SecureStoreError.secureEnclaveUnavailable }
        let newKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
        try newKey.dataRepresentation.write(to: keyURL, options: [.completeFileProtection, .atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return newKey
    }
}

struct EnclaveBox {
    private let key: SecureEnclave.P256.KeyAgreement.PrivateKey
    private let salt: Data
    private let info: Data

    init(key: SecureEnclave.P256.KeyAgreement.PrivateKey, salt: String, info: String) {
        self.key = key
        self.salt = Data(salt.utf8)
        self.info = Data(info.utf8)
    }

    func seal(_ plaintext: Data) throws -> Data {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try key.sharedSecretFromKeyAgreement(with: ephemeral.publicKey)
        let derived = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32
        )
        let sealed = try AES.GCM.seal(plaintext, using: derived)
        guard let combined = sealed.combined else { throw SecureStoreError.malformedCiphertext }
        let pubBytes = ephemeral.publicKey.rawRepresentation
        var blob = Data()
        var len = UInt32(pubBytes.count).bigEndian
        blob.append(Data(bytes: &len, count: 4))
        blob.append(pubBytes)
        blob.append(combined)
        return blob
    }

    func open(_ blob: Data) throws -> Data {
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
            using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32
        )
        let sealed = try AES.GCM.SealedBox(combined: sealedBytes)
        return try AES.GCM.open(sealed, using: derived)
    }
}
