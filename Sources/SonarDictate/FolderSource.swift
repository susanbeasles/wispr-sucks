import Foundation

// A drop-folder source: text files placed in a watched directory get ingested.
// No permissions, no network - the simplest possible connector, and the second
// real implementation of Source (proving the protocol generalizes). Default
// owner is PERSONAL (your own dropped notes/docs); the classifier can escalate.
//
// Incremental by modification time: fetch returns files modified after the cursor
// (an ISO-8601 timestamp), so a poller only picks up newly dropped/edited files.
struct FolderSource: Source {
    let id = "folder"
    let defaultOwner: DataOwner
    let dir: URL
    let exts: Set<String>
    let maxBytes: Int

    init(dir: URL, owner: DataOwner = .personal,
         exts: Set<String> = ["txt", "md", "markdown", "text"], maxBytes: Int = 1_000_000) {
        self.dir = dir
        self.defaultOwner = owner
        self.exts = exts
        self.maxBytes = maxBytes
    }

    func fetch(since cursor: String?, limit: Int = 100) throws -> (items: [SourceItem], next: String?) {
        let fm = FileManager.default
        let since = cursor.flatMap(Self.parseDate) ?? Date.distantPast
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles])) ?? []

        var dated: [(url: URL, at: Date)] = []
        for url in urls where exts.contains(url.pathExtension.lowercased()) {
            let vals = try? url.resourceValues(forKeys: Set(keys))
            guard vals?.isRegularFile == true, let mtime = vals?.contentModificationDate, mtime > since,
                  (vals?.fileSize ?? .max) <= maxBytes else { continue }
            dated.append((url, mtime))
        }
        dated.sort { $0.at < $1.at }

        var items: [SourceItem] = []
        var lastAt = since
        for (url, mtime) in dated.prefix(limit) {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            lastAt = mtime
            items.append(SourceItem(source: id, provenance: defaultOwner, at: mtime, text: text,
                                    externalId: "file-\(url.lastPathComponent)-\(Int(mtime.timeIntervalSince1970))"))
        }
        return (items, items.isEmpty ? cursor : Self.formatter.string(from: lastAt))
    }

    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func parseDate(_ s: String) -> Date? { formatter.date(from: s) }
}
