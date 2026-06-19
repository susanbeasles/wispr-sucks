import Foundation
import FoundationModels

// The eyes' reasoning stage: turn the OCR'd on-screen text into a short, plain
// situational read - "what is on screen right now."
//
// Iris (a local ollama model) is the primary reasoner - she is the integrator
// the senses report to. If she is unreachable (ollama down/slow), this falls
// back to Apple's on-device Foundation Models (~3B), so a read is always
// produced. Both paths are 100% on-device.
//
// Fails open: on any unavailability or error, returns "" and the loop simply
// shows nothing new. A reasoning failure never crashes the eyes.
@available(macOS 26.0, *)
final class ScreenReasoner {
    private static let instructions = """
        You are the eyes of an assistant, watching one region of the user's screen.
        You receive the TEXT currently visible in that region (extracted by OCR).
        In ONE or TWO short, concrete sentences, state plainly what is on screen
        right now. If something clearly stands out as new or important, say so.
        No preamble, no markdown, no quotes, no lists. If the text is empty or
        unreadable, reply exactly: nothing readable.
        """

    // current: the OCR text this tick. previous: the OCR text last time we
    // reasoned (nil on the first read) - used only to nudge the model toward what
    // is NEW; real change detection is the loop's delta gate (Phase 2: semantic).
    func summarize(current: String, previous: String?) async -> String {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Cap the OCR text so latency stays bounded - a full screen of text can be
        // huge and the situational read only needs the gist.
        let clipped = String(trimmed.prefix(2000))

        // Primary: Iris (local ollama). Her persona + brevity live in the Modelfile,
        // so we just hand her the text.
        if let iris = await IrisClient.read(clipped) { return iris }

        // Fallback: Apple's on-device model, only if Iris is unreachable.
        return await appleFallback(clipped, previous: previous)
    }

    private func appleFallback(_ clipped: String, previous: String?) async -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            NSLog("SonarDictate: eyes - Iris unreachable and Apple model unavailable; skipping")
            return ""
        }
        let prompt: String
        if let prev = previous?.trimmingCharacters(in: .whitespacesAndNewlines), !prev.isEmpty {
            prompt = "On-screen text now:\n\(clipped)\n\nFocus on what looks NEW since a moment ago."
        } else {
            prompt = "On-screen text now:\n\(clipped)"
        }
        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let response = try await session.respond(to: prompt)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            NSLog("SonarDictate: eyes Apple fallback failed (\(error.localizedDescription))")
            return ""
        }
    }
}
