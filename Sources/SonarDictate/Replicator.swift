import Foundation

// Zero-knowledge off-device backup. The ledger chains are ALREADY ciphertext
// (sealed per-record), so replicating the raw chain bytes to any destination
// hands it opaque data it cannot read. A SYNCED FOLDER (Dropbox's local folder,
// iCloud Drive) is the simplest destination - copy the bytes in, the desktop app
// uploads them. No API, no credentials.
//
// THE WALL, again: only the RECOVERABLE chains (personal + brain) replicate. The
// company chain is Enclave-sealed and device-bound; it is NEVER offered to a sink
// - enforced here, not by convention. Alongside the chains a manifest records each
// chain's head (height + hash) so a restore can verify(expecting:) and detect a
// dropped/rewritten tail (the head anchor, made operational).

protocol ChainSink {
    func put(_ name: String, _ bytes: Data) throws
}

// A synced folder (Dropbox/iCloud Drive) or any directory. Whatever lands here is
// ciphertext + a manifest; the folder's sync client carries it off-device.
struct FolderSink: ChainSink {
    let dir: URL
    init(dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dir = dir
    }
    func put(_ name: String, _ bytes: Data) throws {
        try bytes.write(to: dir.appendingPathComponent(name), options: [.atomic])
    }
}

enum Replicator {
    // ONLY these ever leave the device. company is intentionally absent.
    static let replicable: [DataOwner] = [.personal, .brain]

    @discardableResult
    static func replicate(_ ledgers: Ledgers, dir: URL, to sink: ChainSink) throws -> [String: ChainHead] {
        var manifest: [String: ChainHead] = [:]
        for owner in replicable {
            let name = "\(owner.rawValue).chain"
            let file = dir.appendingPathComponent(name)
            guard let bytes = try? Data(contentsOf: file) else { continue }   // nothing yet
            try sink.put(name, bytes)
            manifest[owner.rawValue] = ledgers.head(owner)
        }
        let mdata = try JSONEncoder().encode(manifest)
        try sink.put("manifest.json", mdata)
        return manifest
    }
}
