import Foundation
import CryptoKit

// Encrypted, append-only diagnostic log.
//
// Replaces the old plaintext stderr redirect (~/Library/Logs/SonarDictate.log),
// which left every NSLog line in cleartext on a PHI machine. stderr - where
// NSLog writes - is piped through an in-process reader that seals each chunk
// with the same Keychain-held AES-256-GCM key the corpus DB uses, then appends
// it to ~/Library/Logs/SonarDictate.log.enc (0600, complete file protection).
//
// We use the KeychainStore key, NOT the SecureStore Secure-Enclave key: the
// Enclave key triggers Touch ID prompts from background contexts (see
// KeychainStore's own header), and the sink installs at app launch.
//
// On-disk format: a sequence of framed records, each
//   [4-byte big-endian length N][N bytes AES.GCM.combined]
// Each record is an independent GCM seal (random nonce per record), so a partial
// trailing record from a crash is detected by the length prefix and skipped on
// read. Decrypt with: sonar-dictate logs [--follow]

enum EncryptedLog {
    static let url = logsDir().appendingPathComponent("SonarDictate.log.enc")
    private static let plaintextURL = logsDir().appendingPathComponent("SonarDictate.log")

    private static let queue = DispatchQueue(label: "sonar-dictate.enc-log")
    // Retained so the pipe and its read handler are not torn down after install().
    private static var pipe: Pipe?

    private static func logsDir() -> URL {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs")
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - Sink (background app)

    // Install the encrypted sink: migrate any existing plaintext log, then route
    // stderr (fd 2, where NSLog writes) into a reader that seals + appends.
    static func install() {
        let key: SymmetricKey
        do {
            key = try KeychainStore.loadOrCreateDBKey()
            try FileManager.default.createDirectory(at: logsDir(), withIntermediateDirectories: true)
        } catch {
            // Fail SAFE: do NOT fall back to a plaintext file (that is the leak we
            // are closing). Drop diagnostics to the unified log only.
            NSLog("SonarDictate: encrypted log unavailable (\(error)); diagnostics go to unified log only")
            return
        }

        migratePlaintext(using: key)

        let p = Pipe()
        pipe = p
        dup2(p.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        p.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            queue.async { append(data, using: key) }
        }
        // First post-install line: goes through the pipe and lands encrypted.
        NSLog("SonarDictate: --- launch \(timestamp()) --- (encrypted log)")
    }

    // One-time conversion of a pre-existing plaintext log into an encrypted record.
    // After this, the cleartext file is removed. Idempotent: nothing to do once gone.
    private static func migratePlaintext(using key: SymmetricKey) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: plaintextURL.path) else { return }
        do {
            let existing = try Data(contentsOf: plaintextURL)
            if !existing.isEmpty {
                var blob = Data("--- migrated plaintext log, encrypted at \(timestamp()) ---\n".utf8)
                blob.append(existing)
                appendFrame(try seal(blob, using: key))
            }
            // Truncate then remove. (True secure-erase is not achievable at app
            // level on APFS; this removes the live cleartext, no more.)
            try? Data().write(to: plaintextURL, options: [.atomic])
            try fm.removeItem(at: plaintextURL)
        } catch {
            NSLog("SonarDictate: plaintext log migration failed: \(error)")
        }
    }

    // Runs on `queue`. Never call NSLog here: it would write to the same stderr
    // pipe and recurse.
    private static func append(_ data: Data, using key: SymmetricKey) {
        guard let frame = try? seal(data, using: key) else { return }
        appendFrame(frame)
    }

    private static func appendFrame(_ frame: Data) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? frame.write(to: url, options: [.completeFileProtection, .atomic])
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return
        }
        guard let fh = try? FileHandle(forWritingTo: url) else { return }
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: frame)
    }

    // MARK: - Read (CLI)

    // Decrypt the whole log into a string. Stops at the first malformed/partial
    // record so a crash-truncated tail does not abort the readable history.
    static func readAll() throws -> String {
        let key = try KeychainStore.loadOrCreateDBKey()
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        let blob = try Data(contentsOf: url)
        var out = Data()
        _ = decode(Array(blob), from: 0, using: key) { out.append($0) }
        return String(data: out, encoding: .utf8) ?? ""
    }

    // Print the log, then live-tail new records as the running app appends them.
    static func follow() throws -> Never {
        let key = try KeychainStore.loadOrCreateDBKey()
        var offset = 0
        while true {
            let blob = (try? Data(contentsOf: url)) ?? Data()
            if blob.count > offset {
                offset = decode(Array(blob), from: offset, using: key) {
                    FileHandle.standardOutput.write($0)
                }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    // Decode framed records starting at byte `start`, emitting decrypted bytes via
    // `emit`. Returns the offset just past the last COMPLETE record (a safe resume
    // point: records are written as whole atomic appends, so the file always ends
    // on a record boundary unless a crash truncated the final write).
    private static func decode(_ bytes: [UInt8], from start: Int, using key: SymmetricKey, emit: (Data) -> Void) -> Int {
        var off = start
        while off + 4 <= bytes.count {
            let n = (Int(bytes[off]) << 24) | (Int(bytes[off + 1]) << 16) | (Int(bytes[off + 2]) << 8) | Int(bytes[off + 3])
            let recordStart = off + 4
            guard n > 0, recordStart + n <= bytes.count else { break }
            let record = Data(bytes[recordStart ..< recordStart + n])
            guard
                let box = try? AES.GCM.SealedBox(combined: record),
                let plain = try? AES.GCM.open(box, using: key)
            else { break }
            emit(plain)
            off = recordStart + n
        }
        return off
    }

    // MARK: - Internals

    private static func seal(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw KeychainStoreError.unexpectedKeySize(0)  // reuse existing error type; combined is nil only on a CryptoKit invariant break
        }
        var frame = Data()
        var len = UInt32(combined.count).bigEndian
        frame.append(Data(bytes: &len, count: 4))
        frame.append(combined)
        return frame
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
