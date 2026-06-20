import Foundation

// Iris's agenda: the structured, actionable layer on top of raw memory. Where
// PerceptionMemory holds everything she has seen/heard/been told, the Agenda
// holds the things that NEED something - action items and notes - with state.
// This is the primitive the assistant grows from (day-planning, priorities).
//
// Encrypted at rest with the device Secure Enclave key (EnclaveBox), same posture
// as the memory and the recordings. PHI-safe; nothing leaves the box.

struct AgendaItem: Codable {
    let id: String          // short random id (prefix-matchable from the CLI/chat)
    var kind: String        // "task" (something to do) | "note" (something to remember)
    var text: String
    var status: String      // "open" | "done"
    let createdAt: Date
    var tags: [String]
}

final class AgendaStore {
    private static let fileName = "agenda.enc"
    private static let salt = "__sonar_dictate_agenda__"
    private static let info = "sonar-dictate.v1.agenda"

    private let box: EnclaveBox
    private let url: URL
    private let queue = DispatchQueue(label: "sonar-dictate.agenda", qos: .utility)
    private var items: [AgendaItem] = []

    init() throws {
        let key = try EnclaveKey.loadOrCreate()
        self.box = EnclaveBox(key: key, salt: Self.salt, info: Self.info)
        self.url = SecureStore.baseDir.appendingPathComponent(Self.fileName)
        self.items = (try? loadAll()) ?? []
    }

    @discardableResult
    func add(kind: String, text: String, tags: [String] = []) -> AgendaItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = AgendaItem(
            id: Self.newID(), kind: kind, text: trimmed, status: "open",
            createdAt: Date(), tags: tags
        )
        queue.sync { items.append(item) }
        try? persist()
        return item
    }

    // Open items, oldest first (the order you'd work them).
    func open() -> [AgendaItem] {
        queue.sync { items.filter { $0.status == "open" } }
    }

    func all() -> [AgendaItem] {
        queue.sync { items }
    }

    // Complete the first OPEN item whose id starts with the given prefix, or whose
    // text contains it (so "done dishes" works from the chat).
    @discardableResult
    func complete(_ needle: String) -> AgendaItem? {
        let n = needle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var done: AgendaItem?
        queue.sync {
            if let i = items.firstIndex(where: {
                $0.status == "open" && ($0.id.hasPrefix(n) || $0.text.lowercased().contains(n))
            }) {
                items[i].status = "done"
                done = items[i]
            }
        }
        if done != nil { try? persist() }
        return done
    }

    func reset() throws {
        queue.sync { items.removeAll() }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Encrypted persistence

    private static func newID() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var s = ""
        for _ in 0..<6 { s.append(chars[Int.random(in: 0..<chars.count)]) }
        return s
    }

    private func loadAll() throws -> [AgendaItem] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let blob = try Data(contentsOf: url)
        guard !blob.isEmpty else { return [] }
        let plain = try box.open(blob)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([AgendaItem].self, from: plain)
    }

    private func persist() throws {
        let snapshot = queue.sync { items }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plain = try encoder.encode(snapshot)
        let blob = try box.seal(plain)
        try blob.write(to: url, options: [.completeFileProtection, .atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
