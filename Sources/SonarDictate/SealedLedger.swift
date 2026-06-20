import Foundation
import CryptoKit

// The sealed ledger: an append-only, hash-CHAINED, envelope-encrypted record
// store - one chain per JURISDICTION (work / personal / learning). The spine the
// whole off-site backup hangs off (see .claude/plans/iris-sealed-ledger-offsite.md).
//
// Each record is a link:
//   prefix   = seq | atMs | prevHash | kind | wrappedDataKey | sealedPayload
//   thisHash = SHA-256(prefix)
//   record   = prefix | thisHash
// and on disk each record is framed [4-byte BE length][record]. Because every
// record commits to the previous record's hash, altering or dropping ANY record
// breaks the chain from that point on - verify() walks it and fails at the first
// broken link. Tamper-evident by construction.
//
// Envelope encryption: a fresh random data key seals each payload (AES-256-GCM);
// that data key is itself wrapped by the recoverable KEK (LedgerKey). The KEK
// never persists; only ciphertext does - so a backup of this file is opaque to
// anyone without the passphrase, yet fully recoverable WITH it.
final class SealedLedger {
    private let kek: SymmetricKey
    private let url: URL
    private let queue = DispatchQueue(label: "sonar-dictate.ledger")
    private var lastHash: Data
    private var lastSeq: UInt64
    private static let genesis = Data(repeating: 0, count: 32)

    // dir is injected (not hard-wired to SecureStore) so the ledger is unit
    // testable against a temp directory.
    init(jurisdiction: String, kek: SymmetricKey, dir: URL) throws {
        self.kek = kek
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("\(jurisdiction).chain")

        var seq: UInt64 = 0
        var head = Self.genesis
        if let blob = try? Data(contentsOf: url) {
            for rec in Self.frames(blob) {
                let f = try Self.parse(rec)
                seq = f.seq
                head = f.thisHash
            }
        }
        self.lastSeq = seq
        self.lastHash = head
    }

    var height: UInt64 { queue.sync { lastSeq } }

    // Seal a payload and append it as the next link in the chain.
    @discardableResult
    func append(kind: String, payload: Data) throws -> UInt64 {
        try queue.sync {
            let dataKey = SymmetricKey(size: .bits256)
            guard let sealed = try AES.GCM.seal(payload, using: dataKey).combined,
                  let wrapped = try AES.GCM.seal(Self.raw(dataKey), using: kek).combined else {
                throw LedgerError.sealFailed
            }
            let seq = lastSeq + 1
            let atMs = Int64(Date().timeIntervalSince1970 * 1000)
            let prefix = Self.prefix(seq: seq, atMs: atMs, prevHash: lastHash,
                                     kind: kind, wrapped: wrapped, sealed: sealed)
            let thisHash = Data(SHA256.hash(data: prefix))
            let record = prefix + thisHash

            var frame = Data()
            frame.appendBE(UInt32(record.count))
            frame.append(record)

            let handle = try Self.appendHandle(url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: frame)

            lastSeq = seq
            lastHash = thisHash
            return seq
        }
    }

    // Walk the chain and prove it is unbroken: every recomputed hash matches,
    // every link points at its predecessor, sequence is dense from 1. Throws
    // chainBroken(seq) at the first failure.
    func verify() throws {
        let blob = (try? Data(contentsOf: url)) ?? Data()
        var prev = Self.genesis
        var expected: UInt64 = 1
        for rec in Self.frames(blob) {
            let f = try Self.parse(rec)
            guard Data(SHA256.hash(data: f.prefix)) == f.thisHash else {
                throw LedgerError.chainBroken(seq: f.seq)
            }
            guard f.prevHash == prev, f.seq == expected else {
                throw LedgerError.chainBroken(seq: f.seq)
            }
            prev = f.thisHash
            expected += 1
        }
    }

    // Decrypt the whole chain back to plaintext entries (the restore path).
    func entries() throws -> [LedgerEntry] {
        let blob = (try? Data(contentsOf: url)) ?? Data()
        var out: [LedgerEntry] = []
        for rec in Self.frames(blob) {
            let f = try Self.parse(rec)
            let dataKeyData = try AES.GCM.open(AES.GCM.SealedBox(combined: f.wrapped), using: kek)
            let dataKey = SymmetricKey(data: dataKeyData)
            let payload = try AES.GCM.open(AES.GCM.SealedBox(combined: f.sealed), using: dataKey)
            out.append(LedgerEntry(seq: f.seq,
                                   at: Date(timeIntervalSince1970: Double(f.atMs) / 1000),
                                   kind: f.kind, payload: payload))
        }
        return out
    }

    // MARK: - Wire format

    private struct Fields {
        let seq: UInt64; let atMs: Int64; let prevHash: Data; let kind: String
        let wrapped: Data; let sealed: Data; let thisHash: Data; let prefix: Data
    }

    private static func prefix(seq: UInt64, atMs: Int64, prevHash: Data,
                               kind: String, wrapped: Data, sealed: Data) -> Data {
        var d = Data()
        d.appendBE(seq)
        d.appendBE(UInt64(bitPattern: atMs))
        d.append(prevHash)                       // 32 bytes
        let k = [UInt8](kind.utf8)
        d.appendBE(UInt16(k.count)); d.append(contentsOf: k)
        d.appendBE(UInt32(wrapped.count)); d.append(wrapped)
        d.appendBE(UInt32(sealed.count)); d.append(sealed)
        return d
    }

    private static func parse(_ r: [UInt8]) throws -> Fields {
        guard r.count >= 8 + 8 + 32 + 2 + 4 + 4 + 32 else { throw LedgerError.badFrame }
        var p = 0
        func u64() -> UInt64 { var v: UInt64 = 0; for _ in 0..<8 { v = (v << 8) | UInt64(r[p]); p += 1 }; return v }
        func u16() -> Int { let v = (Int(r[p]) << 8) | Int(r[p + 1]); p += 2; return v }
        func u32() -> Int { let v = (Int(r[p]) << 24) | (Int(r[p + 1]) << 16) | (Int(r[p + 2]) << 8) | Int(r[p + 3]); p += 4; return v }
        func take(_ n: Int) throws -> [UInt8] { guard p + n <= r.count else { throw LedgerError.badFrame }; let s = Array(r[p..<p + n]); p += n; return s }

        let seq = u64()
        let atMs = Int64(bitPattern: u64())
        let prevHash = try take(32)
        let kind = String(decoding: try take(u16()), as: UTF8.self)
        let wrapped = try take(u32())
        let sealed = try take(u32())
        let thisHash = try take(32)
        guard p == r.count else { throw LedgerError.badFrame }
        return Fields(seq: seq, atMs: atMs, prevHash: Data(prevHash), kind: kind,
                      wrapped: Data(wrapped), sealed: Data(sealed),
                      thisHash: Data(thisHash), prefix: Data(r[0..<(r.count - 32)]))
    }

    // Split the file into record byte-blobs; a truncated trailing frame (a crash
    // mid-append) is detected by the length prefix and dropped.
    private static func frames(_ data: Data) -> [[UInt8]] {
        let b = [UInt8](data)
        var out: [[UInt8]] = []
        var i = 0
        while i + 4 <= b.count {
            let len = (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3])
            let start = i + 4
            if len <= 0 || start + len > b.count { break }
            out.append(Array(b[start..<start + len]))
            i = start + len
        }
        return out
    }

    private static func raw(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    private static func appendHandle(_ url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        return try FileHandle(forWritingTo: url)
    }
}

struct LedgerEntry {
    let seq: UInt64
    let at: Date
    let kind: String
    let payload: Data
}

enum LedgerError: Error, CustomStringConvertible {
    case chainBroken(seq: UInt64)
    case badFrame
    case sealFailed
    case emptyPassphrase
    case kdfFailed

    var description: String {
        switch self {
        case .chainBroken(let seq): return "ledger chain broken at seq \(seq)"
        case .badFrame:             return "ledger record malformed"
        case .sealFailed:           return "ledger AES-GCM seal failed"
        case .emptyPassphrase:      return "ledger passphrase is empty"
        case .kdfFailed:            return "ledger key derivation failed"
        }
    }
}

private extension Data {
    mutating func appendBE(_ v: UInt16) {
        append(UInt8(truncatingIfNeeded: v >> 8)); append(UInt8(truncatingIfNeeded: v))
    }
    mutating func appendBE(_ v: UInt32) {
        for s in stride(from: 24, through: 0, by: -8) { append(UInt8(truncatingIfNeeded: v >> UInt32(s))) }
    }
    mutating func appendBE(_ v: UInt64) {
        for s in stride(from: 56, through: 0, by: -8) { append(UInt8(truncatingIfNeeded: v >> UInt64(s))) }
    }
}
