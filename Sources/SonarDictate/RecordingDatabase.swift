import Foundation
import SQLite3
import CryptoKit

// The corpus database. Backs the long-term moat: every dictation, its raw
// transcript, what we committed, eventually the user's corrections + audio
// features + provenance tags. Open source-of-truth columns are model-agnostic
// (raw WAV path, plain transcript text under encryption) so when we swap
// Apple's recognizer for our own someday, the corpus moves with us untouched.
//
// Storage:
//   - SQLite file at <baseDir>/recordings.db.
//   - Sensitive content columns (transcripts, audio_path) stored as AES-GCM
//     blobs - encrypted at rest at all times. Key lives in Keychain
//     (KeychainStore), readable by this signed app only.
//   - Metadata columns (id, timestamps, durations, app bundle, model name)
//     are plain SQLite so we can index/query/aggregate without decrypting
//     all rows. None of these are PHI on their own.
//
// Schema is versioned via PRAGMA user_version. Migrations live as the
// `migrations` array - to add a new one, append a (version, sql) tuple. The
// migrator applies anything ahead of the DB's current version.
//
// All operations serialized through `queue` so we don't have to fight SQLite's
// threading mode. Volume is tiny (a few writes per session, hundreds per day).

private let SQLITE_TRANSIENT_FN = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum RecordingDBError: Error, CustomStringConvertible {
    case openFailed(code: Int32, message: String)
    case prepareFailed(code: Int32, message: String, sql: String)
    case stepFailed(code: Int32, message: String)
    case encryptionFailed
    case decryptionFailed

    var description: String {
        switch self {
        case .openFailed(let c, let m):     return "sqlite open failed [\(c)]: \(m)"
        case .prepareFailed(let c, let m, let s): return "sqlite prepare failed [\(c)]: \(m) :: \(s)"
        case .stepFailed(let c, let m):     return "sqlite step failed [\(c)]: \(m)"
        case .encryptionFailed:             return "AES-GCM seal failed"
        case .decryptionFailed:             return "AES-GCM open failed"
        }
    }
}

final class RecordingDatabase {
    private var db: OpaquePointer?
    private let key: SymmetricKey
    private let queue = DispatchQueue(label: "sonar-dictate.recording-db")

    // Schema migrations. Append-only - never edit an existing entry; add a
    // new (version, sql) tuple. Migrator runs everything strictly greater
    // than the current PRAGMA user_version.
    private static let migrations: [(version: Int32, sql: String)] = [
        (1, """
        CREATE TABLE IF NOT EXISTS recordings (
            id TEXT PRIMARY KEY NOT NULL,
            created_at INTEGER NOT NULL,        -- unix milliseconds
            duration_ms INTEGER NOT NULL,
            app_bundle TEXT,                    -- frontmost app at session start
            locale TEXT NOT NULL,
            acoustic_model TEXT NOT NULL,       -- e.g. "apple.DictationTranscriber@26.0"
            language_model TEXT,                -- FK into language_models, NULL = Apple builtin
            was_broadcast INTEGER NOT NULL,     -- bool: hit selector targets, not just inject
            fn_held_ms INTEGER,                 -- how long the talk key was held
            audio_path_enc BLOB,                -- AES-GCM(plaintext path)
            raw_transcript_enc BLOB,            -- AES-GCM(model output)
            committed_text_enc BLOB,            -- AES-GCM(what we injected/chip'd)
            corrected_text_enc BLOB             -- AES-GCM(user's edit), NULL until edit-watcher lands
        );
        CREATE INDEX IF NOT EXISTS idx_recordings_created_at ON recordings(created_at);
        CREATE INDEX IF NOT EXISTS idx_recordings_app_bundle  ON recordings(app_bundle);

        CREATE TABLE IF NOT EXISTS language_models (
            id TEXT PRIMARY KEY NOT NULL,
            trained_at INTEGER NOT NULL,
            trained_through_correction_id INTEGER,   -- last correction included in this training run
            trainer TEXT NOT NULL,                   -- "apple.SFCustomLanguageModelData" | future others
            artifact_path TEXT NOT NULL
        );
        """),
        (2, """
        -- corrections: the gold labels. Each row is one (what we typed, what
        -- the user kept) pair, captured by EditWatcher observing the focused
        -- field for ~60s after we inject. This is the training data that lets
        -- a custom LM learn this user's actual vocabulary - the moat.
        CREATE TABLE IF NOT EXISTS corrections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            recording_id TEXT NOT NULL,           -- FK -> recordings.id
            raw_phrase_enc BLOB NOT NULL,         -- AES-GCM(what we typed)
            corrected_phrase_enc BLOB NOT NULL,   -- AES-GCM(what the user kept)
            position INTEGER,                     -- char offset inside the field, optional
            weight REAL NOT NULL DEFAULT 1.0,     -- decays / boosts over time
            created_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_corrections_recording_id ON corrections(recording_id);
        CREATE INDEX IF NOT EXISTS idx_corrections_created_at   ON corrections(created_at);
        """),
    ]

    init(at url: URL) throws {
        self.key = try KeychainStore.loadOrCreateDBKey()

        // Ensure parent dir exists with 0700 perms.
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }

        var raw: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(url.path, &raw, flags, nil)
        guard code == SQLITE_OK, let raw = raw else {
            let msg = raw.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let raw = raw { sqlite3_close(raw) }
            throw RecordingDBError.openFailed(code: code, message: msg)
        }
        self.db = raw

        // 0600 on the file - readable only by this user.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
            ofItemAtPath: url.path)

        try migrate()
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - Public API

    // Record one dictation session. Sensitive fields are encrypted under the
    // Keychain-held key before they touch disk.
    func recordSession(
        id: String,
        createdAt: Date,
        durationSeconds: TimeInterval,
        appBundle: String?,
        locale: String,
        acousticModel: String,
        languageModel: String?,
        wasBroadcast: Bool,
        fnHeldMs: Int?,
        audioPath: String?,
        rawTranscript: String,
        committedText: String,
        correctedText: String? = nil
    ) throws {
        try queue.sync {
            let sql = """
            INSERT INTO recordings (
                id, created_at, duration_ms, app_bundle, locale,
                acoustic_model, language_model, was_broadcast, fn_held_ms,
                audio_path_enc, raw_transcript_enc, committed_text_enc, corrected_text_enc
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
            try execStatement(sql) { stmt in
                sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT_FN)
                sqlite3_bind_int64(stmt, 2, Int64(createdAt.timeIntervalSince1970 * 1000))
                sqlite3_bind_int64(stmt, 3, Int64(durationSeconds * 1000))
                if let appBundle = appBundle {
                    sqlite3_bind_text(stmt, 4, appBundle, -1, SQLITE_TRANSIENT_FN)
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                sqlite3_bind_text(stmt, 5, locale, -1, SQLITE_TRANSIENT_FN)
                sqlite3_bind_text(stmt, 6, acousticModel, -1, SQLITE_TRANSIENT_FN)
                if let lm = languageModel {
                    sqlite3_bind_text(stmt, 7, lm, -1, SQLITE_TRANSIENT_FN)
                } else {
                    sqlite3_bind_null(stmt, 7)
                }
                sqlite3_bind_int(stmt, 8, wasBroadcast ? 1 : 0)
                if let held = fnHeldMs {
                    sqlite3_bind_int64(stmt, 9, Int64(held))
                } else {
                    sqlite3_bind_null(stmt, 9)
                }
                try bindEncrypted(stmt, index: 10, plaintext: audioPath)
                try bindEncrypted(stmt, index: 11, plaintext: rawTranscript)
                try bindEncrypted(stmt, index: 12, plaintext: committedText)
                try bindEncrypted(stmt, index: 13, plaintext: correctedText)
            }
        }
    }

    // Capture a (raw, corrected) pair from the edit-watcher. Both phrases are
    // encrypted under the keychain key before they touch disk. The recording_id
    // links back to the source dictation; weight defaults to 1.0 and can be
    // bumped on repeat occurrences by the trainer later.
    func addCorrection(
        recordingId: String,
        rawPhrase: String,
        correctedPhrase: String,
        position: Int? = nil,
        weight: Double = 1.0,
        createdAt: Date = Date()
    ) throws {
        try queue.sync {
            let sql = """
            INSERT INTO corrections
                (recording_id, raw_phrase_enc, corrected_phrase_enc, position, weight, created_at)
            VALUES (?,?,?,?,?,?)
            """
            try execStatement(sql) { stmt in
                sqlite3_bind_text(stmt, 1, recordingId, -1, SQLITE_TRANSIENT_FN)
                try bindEncrypted(stmt, index: 2, plaintext: rawPhrase)
                try bindEncrypted(stmt, index: 3, plaintext: correctedPhrase)
                if let position = position {
                    sqlite3_bind_int64(stmt, 4, Int64(position))
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                sqlite3_bind_double(stmt, 5, weight)
                sqlite3_bind_int64(stmt, 6, Int64(createdAt.timeIntervalSince1970 * 1000))
            }
        }
    }

    // Update the corrected_text_enc column on a recording row after the
    // edit-watcher captures the user's final text. Idempotent - latest write
    // wins; we don't preserve history because corrections (above) capture the
    // diff explicitly.
    func updateCorrectedText(recordingId: String, correctedText: String) throws {
        try queue.sync {
            let sql = "UPDATE recordings SET corrected_text_enc = ? WHERE id = ?"
            try execStatement(sql) { stmt in
                try bindEncrypted(stmt, index: 1, plaintext: correctedText)
                sqlite3_bind_text(stmt, 2, recordingId, -1, SQLITE_TRANSIENT_FN)
            }
        }
    }

    // Stats - count + total duration. Useful for the menu bar status item and
    // the CLI. Plain metadata only, no decryption needed.
    func stats() throws -> (count: Int, totalDurationMs: Int64) {
        try queue.sync {
            let sql = "SELECT COUNT(*), COALESCE(SUM(duration_ms), 0) FROM recordings"
            var c = 0; var dur: Int64 = 0
            try readStatement(sql) { stmt in
                c = Int(sqlite3_column_int64(stmt, 0))
                dur = sqlite3_column_int64(stmt, 1)
            }
            return (c, dur)
        }
    }

    // MARK: - Internals

    private func migrate() throws {
        let current = try queue.sync { () -> Int32 in
            var v: Int32 = 0
            try readStatement("PRAGMA user_version") { stmt in
                v = sqlite3_column_int(stmt, 0)
            }
            return v
        }
        for (version, sql) in Self.migrations where version > current {
            try queue.sync {
                NSLog("SonarDictate: applying DB migration -> v\(version)")
                try execMulti(sql)
                try execMulti("PRAGMA user_version = \(version)")
            }
        }
    }

    // Encrypt a string with the keychain key + bind into the statement, or
    // bind NULL when plaintext is nil/empty.
    private func bindEncrypted(_ stmt: OpaquePointer?, index: Int32, plaintext: String?) throws {
        guard let plain = plaintext, !plain.isEmpty else {
            sqlite3_bind_null(stmt, index)
            return
        }
        let pt = Data(plain.utf8)
        let sealed = try AES.GCM.seal(pt, using: key)
        guard let combined = sealed.combined else { throw RecordingDBError.encryptionFailed }
        _ = combined.withUnsafeBytes { buf -> Int32 in
            sqlite3_bind_blob(stmt, index, buf.baseAddress, Int32(combined.count), SQLITE_TRANSIENT_FN)
        }
    }

    // Run a single SQL statement after a bind closure. Closure is called with
    // the prepared stmt for parameter binding; we step + finalize after.
    private func execStatement(_ sql: String, bind: (OpaquePointer?) throws -> Void) throws {
        var stmt: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard code == SQLITE_OK, stmt != nil else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw RecordingDBError.prepareFailed(code: code, message: msg, sql: sql)
        }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt)
        let stepCode = sqlite3_step(stmt)
        guard stepCode == SQLITE_DONE || stepCode == SQLITE_ROW else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw RecordingDBError.stepFailed(code: stepCode, message: msg)
        }
    }

    // Read-side helper - prepare + step once + call read closure for the row.
    private func readStatement(_ sql: String, _ read: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard code == SQLITE_OK, stmt != nil else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw RecordingDBError.prepareFailed(code: code, message: msg, sql: sql)
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW { read(stmt) }
    }

    // Multi-statement exec (for migrations with several CREATE/INDEX in one
    // block). Uses sqlite3_exec directly.
    private func execMulti(_ sql: String) throws {
        var errPtr: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &errPtr)
        guard code == SQLITE_OK else {
            let msg = errPtr.flatMap { String(cString: $0) } ?? "unknown"
            sqlite3_free(errPtr)
            throw RecordingDBError.prepareFailed(code: code, message: msg, sql: sql)
        }
    }
}
