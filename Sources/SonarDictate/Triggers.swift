import Foundation

// Trigger-word classifier.
//
// Run on the FINAL transcript after the user releases Option. Looks at the
// first word(s) and decides whether this dictation should be routed
// somewhere other than the focused app.
//
// Current scope: classification only. Handlers are stubbed (log + notify).
// Real handlers (MCP gateway, Jira ticket creation, notes vault, etc.)
// come later once the platform integration points are wired.

enum TriggerAction: CustomStringConvertible {
    case dictate(String)                          // no trigger → inject as text
    case action(verb: String, body: String)       // "yo …" → route to MCP gateway / action handler
    case llmPrompt(target: String, body: String)  // "claude …", "cursor …" → strip trigger, inject body
    case note(String)                             // "note …" → save to notes vault
    case todo(String)                             // "todo …" → append to task list

    var description: String {
        switch self {
        case .dictate(let t):           return "dictate(\(t.prefix(40))…)"
        case .action(let v, let b):     return "action(verb=\(v), body=\(b.prefix(40))…)"
        case .llmPrompt(let t, let b):  return "llmPrompt(target=\(t), body=\(b.prefix(40))…)"
        case .note(let b):              return "note(\(b.prefix(40))…)"
        case .todo(let b):              return "todo(\(b.prefix(40))…)"
        }
    }
}

struct TriggerRouter {
    // Default trigger vocabulary. Future: load user-defined triggers from
    // SecureStore so per-user vocabulary travels with the install.
    static let defaultTriggers: Set<String> = ["yo", "claude", "cursor", "note", "todo", "jira"]

    static func classify(_ transcript: String, vocabulary: Set<String> = defaultTriggers) -> TriggerAction {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .dictate(transcript) }

        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let firstRaw = parts.first else { return .dictate(transcript) }
        let first = String(firstRaw).lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters)
        let rest = parts.count > 1 ? String(parts[1]) : ""

        guard vocabulary.contains(first) else { return .dictate(transcript) }

        switch first {
        case "yo":                  return .action(verb: "yo", body: rest)
        case "jira":                return .action(verb: "jira", body: rest)
        case "claude", "cursor":    return .llmPrompt(target: first, body: rest)
        case "note":                return .note(rest)
        case "todo":                return .todo(rest)
        default:                    return .action(verb: first, body: rest)
        }
    }
}
