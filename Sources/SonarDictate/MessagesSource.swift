import Foundation
import SQLite3

// Reads macOS Messages (iMessage/SMS) from the local chat.db - a personal source,
// no credentials, no network. iMessage is the owner's personal life, so it routes
// to the PERSONAL chain (the classifier can still escalate a sensitive thread to
// company). Incremental by message ROWID: each fetch returns messages newer than
// the last cursor, so a poller only ever sees new texts.
//
// Requires Full Disk Access (a TCC grant the user gives the app) to open chat.db.
// Opened READ-ONLY; this never writes to Messages. Rows whose body lives only in
// attributedBody (a binary plist, newer macOS) are skipped for now - plain `text`
// covers the common case; attributedBody decoding is a follow-up.
struct MessagesSource: Source {
    let id = "messages"
    let defaultOwner: DataOwner = .personal
    let dbPath: String

    init(dbPath: String? = nil) {
        self.dbPath = dbPath
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Messages/chat.db")
    }

    func fetch(since cursor: String?, limit: Int = 200) throws -> (items: [SourceItem], next: String?) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw MessagesError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }

        let afterRowId = Int64(cursor ?? "") ?? 0
        // No text/attributedBody filter in SQL - modern messages keep the body only
        // in attributedBody; we derive the body in code and skip rows with neither.
        let sql = """
        SELECT m.ROWID, m.text, m.date, m.is_from_me, h.id, m.attributedBody
        FROM message m LEFT JOIN handle h ON m.handle_id = h.ROWID
        WHERE m.ROWID > ?
        ORDER BY m.ROWID ASC LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MessagesError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, afterRowId)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var items: [SourceItem] = []
        var lastRowId = afterRowId
        var scanned = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            scanned = true
            lastRowId = sqlite3_column_int64(stmt, 0)   // advance past scanned rows even if skipped
            // Body: the plain text column, else decode attributedBody.
            var body = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            if body.isEmpty, let blob = sqlite3_column_blob(stmt, 5) {
                let n = Int(sqlite3_column_bytes(stmt, 5))
                body = Self.decodeAttributedBody(Data(bytes: blob, count: n)) ?? ""
            }
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let at = Self.appleDate(sqlite3_column_int64(stmt, 2))
            let fromMe = sqlite3_column_int(stmt, 3) == 1
            let who = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "unknown"
            let text = fromMe ? "(me) \(body)" : "(\(who)) \(body)"
            items.append(SourceItem(source: id, provenance: defaultOwner, at: at,
                                    text: text, externalId: "msg-\(lastRowId)"))
        }
        return (items, scanned ? String(lastRowId) : cursor)
    }

    // Extract the message text from an attributedBody blob - an NSAttributedString
    // archived in the old `typedstream` format (NSArchiver), which NSKeyedUnarchiver
    // cannot read. The documented heuristic the iMessage tooling uses: find the
    // "NSString" class marker, skip its 5 class/version bytes, then read a
    // length-prefixed UTF-8 string (a 0x81 prefix means a 2-byte little-endian
    // length, otherwise a single length byte). Returns nil if it does not match -
    // the caller then skips the row rather than emitting garbage.
    static func decodeAttributedBody(_ data: Data) -> String? {
        let b = [UInt8](data)
        guard let r = firstRange(of: Array("NSString".utf8), in: b) else { return nil }
        var i = r + 5                                  // past "NSString" + 5 class bytes
        guard i < b.count else { return nil }
        let length: Int
        if b[i] == 0x81 {
            guard i + 2 < b.count else { return nil }
            length = Int(b[i + 1]) | (Int(b[i + 2]) << 8)
            i += 3
        } else {
            length = Int(b[i]); i += 1
        }
        guard length > 0, i + length <= b.count else { return nil }
        return String(bytes: b[i..<i + length], encoding: .utf8)
    }

    // Index just PAST the first occurrence of `pattern` in `b`, or nil.
    private static func firstRange(of pattern: [UInt8], in b: [UInt8]) -> Int? {
        guard !pattern.isEmpty, b.count >= pattern.count else { return nil }
        for start in 0...(b.count - pattern.count) where Array(b[start..<start + pattern.count]) == pattern {
            return start + pattern.count
        }
        return nil
    }

    // chat.db `date` is nanoseconds since the 2001-01-01 reference date (modern
    // macOS). Older DBs used seconds; both are handled by magnitude.
    static func appleDate(_ raw: Int64) -> Date {
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}

enum MessagesError: Error, CustomStringConvertible {
    case openFailed(String)
    case queryFailed(String)
    var description: String {
        switch self {
        case .openFailed(let m): return "messages chat.db open failed: \(m)"
        case .queryFailed(let m): return "messages query failed: \(m)"
        }
    }
}
