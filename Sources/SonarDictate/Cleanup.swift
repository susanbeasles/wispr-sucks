import Foundation
import FoundationModels

// Optional cleanup pass over a finalized transcript using Apple's on-device
// Foundation Models (~3B). 100% on-device — no network, consistent with the
// rest of the app's thesis.
//
// Cleanup is OPT-IN per focused-app context. LLM clients (Cursor, Claude,
// ChatGPT, Terminal) are deliberately NOT cleanup targets — raw transcript is
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
    // not in this set stays raw (the default — which is what LLM prompting
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

    static func shouldClean(appContext: String?) -> Bool {
        guard let ctx = appContext else { return false }
        return cleanupApps.contains(ctx)
    }

    private static let instructions = """
        You clean up raw voice-dictation transcripts.
        - Add correct punctuation and capitalization.
        - Remove disfluencies and filler words: uh, um, er, "you know", and "like" when used as filler.
        - Do NOT change meaning. Do NOT add information. Do NOT rephrase, summarize, or reword.
        - Preserve technical terms, names, identifiers, and numbers exactly as transcribed.
        - Output ONLY the cleaned transcript text. No preamble, no quotes, no commentary.
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
            return cleaned.isEmpty ? text : cleaned
        } catch {
            NSLog("SonarDictate: cleanup failed (\(error.localizedDescription)); injecting raw transcript")
            return text
        }
    }
}
