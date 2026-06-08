import Foundation
import Speech

// Offline batch re-transcription of a saved recording's audio.
//
// The live path (DictationTranscriber, streaming) can drop words under rapid or
// short use - but the FULL audio is always persisted, so we can re-run
// recognition over the saved FILE to recover what was dropped. File-based
// recognition is non-streaming and more forgiving than the live engine (it sees
// the whole utterance at once), exactly the "recorded audio" case. This never
// touches live dictation; it only reads a saved WAV. 100% on-device.
enum BatchTranscriber {
    enum Failure: Error, CustomStringConvertible {
        case noRecognizer
        case notAuthorized
        case onDeviceUnavailable

        var description: String {
            switch self {
            case .noRecognizer:
                return "no speech recognizer available for this locale"
            case .notAuthorized:
                return "Speech Recognition not authorized - grant it to SonarDictate in System Settings > Privacy & Security > Speech Recognition"
            case .onDeviceUnavailable:
                return "on-device recognition is unavailable for this locale"
            }
        }
    }

    // Recover the transcript from a saved WAV, on-device only. Blocks until the
    // final result - the CLI is short-lived, so a semaphore is the simplest
    // bridge from the completion-handler API to a synchronous command.
    static func recoverTranscript(wavURL: URL, locale: Locale = Locale(identifier: "en-US")) throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw Failure.notAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw Failure.noRecognizer
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw Failure.onDeviceUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: wavURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        let semaphore = DispatchSemaphore(value: 0)
        var output = ""
        var failure: Error?
        recognizer.recognitionTask(with: request) { result, error in
            if let error {
                failure = error
                semaphore.signal()
                return
            }
            if let result, result.isFinal {
                output = result.bestTranscription.formattedString
                semaphore.signal()
            }
        }
        semaphore.wait()

        if let failure { throw failure }
        return output
    }
}
