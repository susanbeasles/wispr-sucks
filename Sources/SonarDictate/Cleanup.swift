import Foundation
import FoundationModels

// Optional cleanup pass over a finalized transcript using Apple's on-device
// Foundation Models (~3B). 100% on-device - no network, consistent with the
// rest of the app's thesis.
//
// Cleanup is OPT-IN per focused-app context. LLM clients (Cursor, Claude,
// ChatGPT, Terminal) are deliberately NOT cleanup targets - raw transcript is
// the correct input for an LLM prompt; punctuation/grammar cleanup there is
// wasted latency and can mangle intent. Document + messaging apps (Notes,
// Slack, Mail, Outlook, Notion) benefit from polished output, so those are the
// default cleanup targets.
//
// Fails open: on any unavailability or error, returns the raw transcript. We
// never lose the user's words to a cleanup failure.

@available(macOS 26.0, *)
final class Cleanup {

    // Focused-app bundle IDs where dictation gets the cleanup pass. Anything
    // not in this set stays raw (the default - which is what LLM prompting
    // wants). Future: make this user-configurable + persisted in SecureStore.
    static let cleanupApps: Set<String> = [
        "com.apple.Notes",
        "com.apple.mail",
        "com.apple.TextEdit",
        "com.apple.iWork.Pages",
        "com.tinyspeck.slackmacgap",   // Slack
        "com.microsoft.Outlook",
        "notion.id",                   // Notion
        "com.hnc.Discord",             // Discord
    ]

    // Global on/off switch, persisted. Default ON. Flipped from the menu bar so
    // the user can mute the cleanup pass entirely without a rebuild.
    private static let enabledKey = "cleanupEnabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func shouldClean(appContext: String?) -> Bool {
        guard isEnabled else { return false }
        guard let ctx = appContext else { return false }
        return cleanupApps.contains(ctx)
    }

    private static let instructions = """
        You repair ONLY punctuation and capitalization in raw voice-dictation text.
        Permitted edits, nothing else:
        - Add or correct punctuation: periods, commas, question marks, apostrophes.
        - Fix capitalization: sentence starts, the word "I", obvious proper nouns.
        Hard rules:
        - Do NOT add, remove, reorder, replace, or rephrase any word.
        - Do NOT remove filler words. Do NOT summarize. Do NOT "improve" the wording.
        - Keep every word the user said: same words, same order, same spelling.
        - Output ONLY the repaired text. No preamble, no quotes, no commentary.
        """

    // Returns the cleaned transcript, or the original on any failure /
    // model-unavailability. Caller should treat the result as drop-in.
    func clean(_ text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            NSLog("SonarDictate: Foundation Models unavailable; injecting raw transcript")
            return text
        }

        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let response = try await session.respond(to: trimmed)
            let cleaned = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return text }
            // Hard backstop: the model may only touch punctuation and capitalization.
            // If it changed, dropped, added, or reordered any actual word, throw the
            // rewrite away and keep the user's raw words. The prompt is a request;
            // this is the enforcement.
            guard Self.wordsPreserved(raw: trimmed, cleaned: cleaned) else {
                NSLog("SonarDictate: cleanup rejected - rewrite altered words; keeping raw transcript")
                return text
            }
            return cleaned
        } catch {
            NSLog("SonarDictate: cleanup failed (\(error.localizedDescription)); injecting raw transcript")
            return text
        }
    }

    // MARK: - Word-preservation guard

    // True only when raw and cleaned carry the exact same word sequence, ignoring
    // punctuation, capitalization, and apostrophes (so "dont" == "don't"). Makes
    // the punctuation/capitalization-only contract mechanical instead of a polite
    // request the model is free to ignore.
    static func wordsPreserved(raw: String, cleaned: String) -> Bool {
        normalizedWords(raw) == normalizedWords(cleaned)
    }

    private static func normalizedWords(_ s: String) -> [String] {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.lowercased().unicodeScalars {
            let v = scalar.value
            if (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39) {
                out.unicodeScalars.append(scalar)   // ASCII letter or digit
            } else if v == 0x27 || v == 0x2019 {
                continue                            // apostrophe (straight or curly): keep contractions whole
            } else {
                out.append(" ")                     // any other character is a word separator
            }
        }
        return out.split(separator: " ").map(String.init)
    }
}
