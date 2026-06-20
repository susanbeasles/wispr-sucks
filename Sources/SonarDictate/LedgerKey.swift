import Foundation
import CommonCrypto
import CryptoKit

// The recoverable master key (KEK) for the sealed ledger.
//
// Unlike the device Secure Enclave key (EnclaveKey/EnclaveBox), which can never
// leave the chip, this key is DERIVED from a passphrase via PBKDF2-HMAC-SHA256
// over a persisted random salt and a high iteration count. The same passphrase
// reproduces the same key on any device - which is the whole basis for off-device
// RECOVERY: lose the Mac, restore from the ciphertext backup with the passphrase.
//
// The passphrase is the highest-order secret. It arrives via op (1Password) at
// the call site; this type only turns a passphrase into a key and NEVER stores,
// logs, or echoes it. Only the non-secret KDF params (salt + iterations) persist.
enum LedgerKey {
    struct Params: Codable { let version: Int; let salt: Data; let iterations: Int }

    private static let fileName = "kdf.json"
    // Cost factor. PBKDF2 is the dependency-free choice (CommonCrypto); Argon2id
    // would be stronger and is noted as later hardening in the plan.
    private static let iterations = 600_000

    // Load the persisted KDF params, or create them (random salt) on first use.
    static func loadOrCreateParams(dir: URL) throws -> Params {
        let url = dir.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: url),
           let p = try? JSONDecoder().decode(Params.self, from: data) {
            return p
        }
        var salt = Data(count: 16)
        let ok = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) == errSecSuccess
        }
        guard ok else { throw LedgerError.kdfFailed }
        let params = Params(version: 1, salt: salt, iterations: iterations)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(params).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return params
    }

    // Derive the 256-bit KEK from a passphrase + params. Deterministic: same
    // inputs -> same key (the recovery property).
    static func deriveKEK(passphrase: String, params: Params) throws -> SymmetricKey {
        guard !passphrase.isEmpty else { throw LedgerError.emptyPassphrase }
        let pw = [UInt8](passphrase.utf8)
        let salt = [UInt8](params.salt)
        var derived = [UInt8](repeating: 0, count: 32)
        let rc = pw.withUnsafeBytes { pwPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwPtr.baseAddress!.assumingMemoryBound(to: CChar.self), pw.count,
                    saltPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(params.iterations),
                    &derived, derived.count)
            }
        }
        guard rc == kCCSuccess else { throw LedgerError.kdfFailed }
        return SymmetricKey(data: Data(derived))
    }
}
