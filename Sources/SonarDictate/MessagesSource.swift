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
        let sql = """
        SELECT m.ROWID, m.text, m.date, m.is_from_me, h.id
        FROM message m LEFT JOIN handle h ON m.handle_id = h.ROWID
        WHERE m.ROWID > ? AND m.text IS NOT NULL AND m.text != ''
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
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            lastRowId = rowId
            guard let cText = sqlite3_column_text(stmt, 1) else { continue }
            let body = String(cString: cText)
            let at = Self.appleDate(sqlite3_column_int64(stmt, 2))
            let fromMe = sqlite3_column_int(stmt, 3) == 1
            let who = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "unknown"
            // Light direction prefix so "who said it" survives into her memory.
            let text = fromMe ? "(me) \(body)" : "(\(who)) \(body)"
            items.append(SourceItem(source: id, provenance: defaultOwner, at: at,
                                    text: text, externalId: "msg-\(rowId)"))
        }
        return (items, items.isEmpty ? cursor : String(lastRowId))
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
