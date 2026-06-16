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
    case dictate(String)                                 // no trigger -> inject as text
    case action(verb: String, body: String)              // "yo ..." -> route to MCP gateway / action handler
    case llmPrompt(target: String, body: String)         // "claude ...", "cursor ..." -> strip trigger, inject body
    case note(String)                                    // "note ..." -> save to notes vault
    case todo(String)                                    // "todo ..." -> append to task list
    case runWorkflow(WorkflowBinding, input: String)     // user-defined Automator workflow

    // Content-free on purpose: this is logged on every utterance via
    // NSLog("classified -> \(action)"), and that NSLog stream is redirected to a
    // plaintext, unencrypted ~/Library/Logs/SonarDictate.log. Interpolating the
    // transcript body here put the first 40 chars of every dictation into that
    // file in cleartext (PHI at rest). Log only the route and the body LENGTH -
    // never the spoken words. Trigger verbs / target / workflow names are config
    // labels chosen by the user, not dictation content, so they stay.
    var description: String {
        switch self {
        case .dictate(let t):            return "dictate(len=\(t.count))"
        case .action(let v, let b):      return "action(verb=\(v), bodyLen=\(b.count))"
        case .llmPrompt(let t, let b):   return "llmPrompt(target=\(t), bodyLen=\(b.count))"
        case .note(let b):               return "note(len=\(b.count))"
        case .todo(let b):               return "todo(len=\(b.count))"
        case .runWorkflow(let b, let i): return "runWorkflow(name=\(b.name), trigger=\(b.triggerPhrase), inputLen=\(i.count))"
        }
    }
}

struct TriggerRouter {
    // Built-in trigger words are DISABLED. The user dictates naturally - often
    // starting with "yo" - and routing those to action/note/todo handlers got in
    // the way for zero benefit: the handlers are unwired and already fell back to
    // plain dictation. Empty set => classify() treats every utterance as plain
    // dictation, so leading "yo"/"note"/etc. land as ordinary words. User-defined
    // workflow bindings (WorkflowStore) are unaffected; they are matched
    // separately and only fire when the user explicitly binds a phrase.
    static let defaultTriggers: Set<String> = []

    static func classify(
        _ transcript: String,
        vocabulary: Set<String> = defaultTriggers,
        workflowStore: WorkflowStore? = nil
    ) -> TriggerAction {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .dictate(transcript) }

        // User-defined workflow bindings win over built-in triggers - they
        // were explicitly chosen by this user, so prefer them.
        if let store = workflowStore, let binding = store.match(trimmed) {
            let lower = trimmed.lowercased()
            // Drop the matched prefix from the original (case-preserving) transcript.
            let remainder: String
            if lower.count > binding.triggerPhrase.count {
                let dropCount = binding.triggerPhrase.count
                let idx = trimmed.index(trimmed.startIndex, offsetBy: dropCount)
                remainder = String(trimmed[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                remainder = ""
            }
            return .runWorkflow(binding, input: remainder)
        }

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
