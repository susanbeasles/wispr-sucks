import Foundation

// Iris's brain: a local ollama model (the `iris` Modelfile, built on a fast
// non-thinking vision-language model). She is the INTEGRATOR - her senses report
// to her and she composes the reply.
//
// 100% on-device: ollama listens on 127.0.0.1 only; nothing leaves the box, so
// this stays compliant on a PHI machine. If ollama is down or slow, the caller
// falls back to Apple's on-device model - Iris is preferred, never required.
enum IrisClient {
    private static let endpoint = URL(string: "http://127.0.0.1:11434/api/chat")!
    private static let model = "iris"

    // A screen-read note for her own memory (terse, per the Modelfile persona).
    static func read(_ screenText: String) async -> String? {
        await chatOnce([["role": "user", "content": "Screen read:\n\(screenText)"]])
    }

    // A plain one-shot completion (no "Screen read:" framing) - tagging, etc.
    static func complete(_ userText: String) async -> String? {
        await chatOnce([["role": "user", "content": userText]])
    }

    // Classify a piece of text into 1-4 short tags (best-effort) for the memory.
    static func tags(for text: String) async -> [String] {
        let prompt = "Classify this in 1 to 4 short lowercase topic tags. Output ONLY the tags, comma-separated, nothing else:\n\(text)"
        guard let r = await complete(prompt) else { return [] }
        let separators = CharacterSet(charactersIn: ",;\n")
        let rawParts = r.lowercased().components(separatedBy: separators)
        var out: [String] = []
        for part in rawParts {
            let tag = part.trimmingCharacters(in: .whitespaces)
            if !tag.isEmpty, tag.count <= 24 { out.append(tag) }
            if out.count == 4 { break }
        }
        return out
    }

    // Pull concrete action items / notes out of a message. Conservative; returns
    // [] when there is nothing actionable. Used to auto-fill the Agenda.
    static func extractAgenda(from message: String) async -> [(kind: String, text: String)] {
        let prompt = """
        From the user's message, extract concrete ACTION ITEMS (things they need to do) \
        and NOTES (facts worth remembering for them). Be conservative - only clear, \
        real ones; skip small talk and questions.
        Output ONLY a JSON array like [{"kind":"task","text":"..."},{"kind":"note","text":"..."}]. \
        If there are none, output [].
        Message: \(message)
        """
        guard let r = await complete(prompt),
              let start = r.firstIndex(of: "["), let end = r.lastIndex(of: "]"), start < end else { return [] }
        let json = String(r[start...end])
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var out: [(kind: String, text: String)] = []
        for obj in arr {
            guard let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            let kind = ((obj["kind"] as? String)?.lowercased() == "note") ? "note" : "task"
            out.append((kind, text))
            if out.count >= 5 { break }
        }
        return out
    }

    // One non-streaming chat call; nil on any failure so callers can fall back.
    private static func chatOnce(_ messages: [[String: String]]) async -> String? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Generous: a cold model load can take seconds; a DOWN server fails fast
        // (connection refused). Warm calls return in under a second.
        request.timeoutInterval = 20

        let payload: [String: Any] = ["model": model, "stream": false, "messages": messages]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        request.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? String else { return nil }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    // Streaming conversation: send the full message history, get tokens as they
    // arrive (onToken is delivered on the main actor for direct UI append), and
    // the full text is returned at the end. Used by the chat window so Iris's
    // replies flow in instead of popping in fully formed.
    static func streamChat(_ messages: [[String: String]], onToken: @escaping (String) -> Void) async -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let payload: [String: Any] = ["model": model, "stream": true, "messages": messages]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return "" }
        request.httpBody = body

        var full = ""
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return "" }
            for try await line in bytes.lines {
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                if let msg = obj["message"] as? [String: Any],
                   let token = msg["content"] as? String, !token.isEmpty {
                    full += token
                    let t = token
                    await MainActor.run { onToken(t) }
                }
                if let done = obj["done"] as? Bool, done { break }
            }
        } catch {
            return full
        }
        return full
    }

    // Warm the model into RAM at launch so the first real read is not the slow
    // one (mirrors the speech-model prewarm). Best-effort; ignores the result.
    static func prewarm() {
        Task.detached(priority: .utility) { _ = await read("ready") }
    }
}
