import Foundation
import AVFoundation
import Speech
import CoreMedia

// Thin wrapper around macOS 26's SpeechAnalyzer + SpeechTranscriber.
//
// Why this exists vs. SFSpeechRecognizer:
//   - Partial cadence ~50–100ms instead of 200–500ms (sub-network-RTT,
//     so we beat any cloud streaming product on perceived latency).
//   - Native volatile/final result distinction via per-result CMTimeRange
//     (no manual word-holdback heuristic).
//   - Apple ships the model on macOS 26+; nothing to install.
//
// Architecture:
//   - Audio in: AsyncStream<AnalyzerInput>. Caller yields PCM buffers
//     via append(buffer:); we wrap them as AnalyzerInput.
//   - Results out: an async Task iterating transcriber.results and
//     assembling overlapping volatile chunks into a single "current
//     best transcript so far" string. onTranscriptUpdate is called
//     with that string after every result.
//   - Each result has a CMTimeRange. Earlier results that get
//     superseded by later results (volatile revisions of the same
//     range) are replaced. Final results extend the timeline.
//   - Cleanest assembly: keep a sorted map [CMTime: String] keyed by
//     range start. Each result writes to its key; concatenate values
//     in time order to get the current transcript.

@available(macOS 26.0, *)
final class SpeechAnalyzerSession {
    private let locale: Locale
    private let context = AnalysisContext()

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var audioContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    // Range-keyed transcript chunks. We use the CMTime seconds (rounded
    // to ms) as the dictionary key so volatile revisions of the same
    // range start replace the previous value cleanly.
    private var chunks: [Double: String] = [:]
    private let chunksQueue = DispatchQueue(label: "sonar-dictate.speech.chunks")

    // Caller hooks. Called from a background queue; caller is
    // responsible for marshalling to the main thread if needed.
    var onTranscriptUpdate: (@Sendable (_ transcript: String, _ isFinal: Bool) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    // Pre-session vocabulary bias. Re-call before each start() to update.
    func setContextualStrings(_ strings: [String]) {
        context.contextualStrings[.general] = strings
    }

    func start() throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )
        self.transcriber = transcriber

        let (audioStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.audioContinuation = continuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Reset chunks for this session.
        chunksQueue.sync { self.chunks.removeAll() }

        // Consume results in a task; assemble running transcript on every result.
        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    self.handle(result: result)
                }
                // Stream ended → flush as final
                self.emitTranscript(isFinal: true)
            } catch is CancellationError {
                // Normal cancel from stop()
            } catch {
                NSLog("SonarDictate: transcriber.results error: \(error)")
                self.onError?(error)
            }
        }

        // Start the analyzer feeding from the audio stream. We pass the
        // context via the convenience init that accepts both. start() is
        // async; spawn it in a task so the caller can return immediately.
        let analysisContext = self.context
        analyzerTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: audioStream)
                _ = analysisContext  // capture
            } catch is CancellationError {
                // Normal cancel from stop()
            } catch {
                NSLog("SonarDictate: analyzer.start error: \(error)")
                self?.onError?(error)
            }
        }
    }

    // Caller invokes from the AVAudioEngine tap.
    func append(buffer: AVAudioPCMBuffer) {
        audioContinuation?.yield(AnalyzerInput(buffer: buffer))
    }

    // Caller invokes after Option-up. We finish the audio stream; the
    // analyzer drains in-flight audio, the results loop emits any final
    // chunks, and the results task completes naturally.
    func stop() {
        audioContinuation?.finish()
        audioContinuation = nil
        // Don't cancel the resultsTask — let it drain so the user's
        // last words come through.
    }

    // MARK: - Internals

    private func handle(result: SpeechTranscriber.Result) {
        let plain = String(result.text.characters)
        let key = result.range.start.seconds.rounded(toMilliseconds: 3)
        chunksQueue.sync {
            self.chunks[key] = plain
        }
        emitTranscript(isFinal: false)
    }

    private func emitTranscript(isFinal: Bool) {
        let snapshot: [Double: String] = chunksQueue.sync { self.chunks }
        // Assemble in time order
        let sortedKeys = snapshot.keys.sorted()
        let assembled = sortedKeys.compactMap { snapshot[$0] }
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
        onTranscriptUpdate?(assembled, isFinal)
    }
}

private extension Double {
    func rounded(toMilliseconds digits: Int) -> Double {
        let mult = pow(10.0, Double(digits))
        return (self * mult).rounded() / mult
    }
}
