import Foundation
import CryptoKit

// Resolves the recoverable KEK for the personal + brain ledger chains. Priority:
//
//   1. A KEK already cached in the Keychain (fast, prompt-free, mode-stable).
//   2. Else, if the recovery passphrase is injected via IRIS_LEDGER_PASSPHRASE
//      (the one-time `op run` setup) -> derive the KEK from it + the persisted
//      KDF salt (LedgerKey), CACHE it, and use it. This is the portable-recovery
//      path: the same 1Password passphrase reproduces this KEK on any device.
//   3. Else the legacy device key (KeychainStore corpus key) - the non-breaking
//      default so the app always has a working key even before setup.
//
// One-time setup (caches the passphrase-derived KEK; do it BEFORE real data
// accumulates so the chains are sealed with the recoverable key from the start):
//   IRIS_LEDGER_PASSPHRASE='op://Personal/iris-ledger-credential/password' \
//     op run --account my.1password.com -- open dist/SonarDictate.app
// After that first launch the KEK is cached; normal launches need neither op nor
// the passphrase. Recovery on a new device: restore the backup (which carries the
// KDF salt) and re-run the setup with the same 1Password item.
enum LedgerSecret {
    private static let kekAccount = "ledger-recoverable-kek"
    private static let passEnv = "IRIS_LEDGER_PASSPHRASE"

    static func recoverableKEK(dir: URL) -> SymmetricKey {
        if let cached = try? KeychainStore.loadKey(account: kekAccount) {
            return cached
        }
        if let pass = ProcessInfo.processInfo.environment[passEnv], !pass.isEmpty,
           let params = try? LedgerKey.loadOrCreateParams(dir: dir),
           let kek = try? LedgerKey.deriveKEK(passphrase: pass, params: params) {
            try? KeychainStore.storeKey(kek, account: kekAccount)
            NSLog("SonarDictate: ledger KEK derived from the recovery passphrase and cached")
            return kek
        }
        // Fallback: the existing device key. Encrypted + device-local, but NOT
        // passphrase-recoverable - set up the passphrase before real data lands.
        return (try? KeychainStore.loadOrCreateDBKey()) ?? SymmetricKey(size: .bits256)
    }
}
