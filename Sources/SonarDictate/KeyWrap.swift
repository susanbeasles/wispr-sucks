import Foundation
import CryptoKit

// How a per-record data key gets sealed in the ledger - the ONE thing that
// differs by owner (see .claude/plans/iris-sealed-ledger-offsite.md). The chain,
// framing, hashing, and verify() are identical across owners; only the wrap
// changes, which is what makes "one brain, partitioned raw" a small generalization
// rather than two ledgers.
protocol KeyWrap {
    func wrap(_ data: Data) throws -> Data     // seal a data key
    func unwrap(_ blob: Data) throws -> Data   // recover it
}

// PERSONAL raw + the BRAIN/LEARNINGS. AES-256-GCM under the recoverable KEK
// (LedgerKey, passphrase-derived). Recoverable on a new device with the
// passphrase -> these chains can be backed up off-device.
struct RecoverableWrap: KeyWrap {
    let kek: SymmetricKey

    func wrap(_ data: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: kek).combined else {
            throw LedgerError.sealFailed
        }
        return combined
    }

    func unwrap(_ blob: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: kek)
    }
}

// COMPANY raw (Sonar's). Sealed to the Secure Enclave (SEP) key via EnclaveBox -
// the SEP key cannot leave the chip, so these chains are device-bound and NEVER
// replicated. Zero new crypto: EnclaveBox already does per-record ECDH seal/open.
struct EnclaveWrap: KeyWrap {
    let box: EnclaveBox

    func wrap(_ data: Data) throws -> Data { try box.seal(data) }
    func unwrap(_ blob: Data) throws -> Data { try box.open(blob) }
}
