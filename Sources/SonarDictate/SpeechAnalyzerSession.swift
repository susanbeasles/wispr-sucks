import Foundation
import AVFoundation
import Speech
import CoreMedia

// Thin wrapper around macOS 26's SpeechAnalyzer + SpeechTranscriber.
//
// Why this exists vs. SFSpeechRecognizer:
//   - Partial cadence ~50–100ms instead of 200–500ms (sub-network-RTT,
//     so we beat any cloud streaming product on perceived latency).
//   - Native volatile/final result distinction via per-result CMTimeRange.
//   - Apple ships the model on macOS 26+; nothing to install.
//
// AUDIO FORMAT (load-bearing — see git history): SpeechAnalyzer traps with
// EXC_BREAKPOINT inside preRunRecognition() if fed an incompatible PCM
// format. The mic input node is typically 48kHz Float32; the transcriber
// wants whatever bestAvailableAudioFormat reports. We negotiate that format
// at start() and run every buffer through an AVAudioConverter before feeding
// AnalyzerInput. Do NOT feed raw mic buffers directly — it crashes.

@available(macOS 26.0, *)
final class SpeechAnalyzerSession {
    private let locale: Locale
    private let context = AnalysisContext()

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var audioContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    // Audio format conversion: mic format → transcriber-compatible format.
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    // Final (committed) transcript segments, keyed by range start (ms). Volatile
    // (in-progress) results are tracked SEPARATELY: mixing volatile + final in
    // one map doubled every phrase, because a volatile and its final can have
    // range starts that jitter by ~1ms → different keys → both survive. Finals
    // accumulate; only the latest volatile tail is kept and it never enters the
    // committed transcript.
    private var finalizedChunks: [Double: String] = [:]
    private var volatileText: String = ""
    private let chunksQueue = DispatchQueue(label: "sonar-dictate.speech.chunks")

    var onTranscriptUpdate: (@Sendable (_ transcript: String, _ isFinal: Bool) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    func setContextualStrings(_ strings: [String]) {
        context.contextualStrings[.general] = strings
    }

    // Async because format negotiation (bestAvailableAudioFormat) is async and
    // MUST complete before any audio is fed. Caller starts the AVAudioEngine
    // only AFTER this returns, so no buffer reaches append() before the
    // converter exists.
    func start(inputFormat: AVAudioFormat) async throws {
        // Tear down any prior run BEFORE building a new one. If a previous
        // session's start() raced with a fast stop (e.g. a <2s Option tap while
        // start() was still negotiating the audio format), its input continuation
        // was never finished and its analyzer/results tasks hang forever. Two
        // overlapping SpeechAnalyzer instances corrupt the pipeline so the new
        // session never emits a final result — which kills finalize()/broadcast.
        // Cancelling here guarantees exactly one analyzer at a time.
        audioContinuation?.finish()
        audioContinuation = nil
        resultsTask?.cancel()
        analyzerTask?.cancel()
        resultsTask = nil
        analyzerTask = nil
        analyzer = nil
        self.transcriber = nil

        // .progressiveTranscription bundles the transcription options that drive
        // smooth streaming volatile partials — this is the lowest-latency LIVE
        // cadence available. (Tried explicit reportingOptions [.volatileResults,
        // .fastResults] to go faster; it actually regressed — dropping the preset
        // lost progressive streaming and the output got chunkier. The preset wins.)
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.transcriber = transcriber

        // Negotiate the transcriber-compatible audio format and build the
        // converter from the mic format to it.
        let negotiated = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.analyzerFormat = negotiated
        if let negotiated, negotiated != inputFormat {
            self.converter = AVAudioConverter(from: inputFormat, to: negotiated)
            NSLog("SonarDictate: audio convert \(Int(inputFormat.sampleRate))Hz/\(inputFormat.channelCount)ch -> \(Int(negotiated.sampleRate))Hz/\(negotiated.channelCount)ch")
        } else {
            self.converter = nil
            NSLog("SonarDictate: mic format already transcriber-compatible (\(Int(inputFormat.sampleRate))Hz)")
        }

        let (audioStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.audioContinuation = continuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        chunksQueue.sync { self.finalizedChunks.removeAll(); self.volatileText = "" }

        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    self.handle(result: result)
                }
                self.emitTranscript(isFinal: true)
            } catch is CancellationError {
                // normal cancel from stop()
            } catch {
                NSLog("SonarDictate: transcriber.results error: \(error)")
                self.onError?(error)
            }
        }

        analyzerTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: audioStream)
            } catch is CancellationError {
                // normal cancel from stop()
            } catch {
                NSLog("SonarDictate: analyzer.start error: \(error)")
                self?.onError?(error)
            }
        }
    }

    // Called from the AVAudioEngine tap (realtime audio thread). Converts the
    // mic buffer to the transcriber-compatible format, then feeds it.
    func append(buffer: AVAudioPCMBuffer) {
        guard let continuation = audioContinuation else { return }
        guard let converter, let outFormat = analyzerFormat else {
            // No conversion needed (formats matched) — feed directly.
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        guard let converted = convert(buffer, with: converter, to: outFormat) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func stop() {
        // 1. Signal no-more-audio by finishing the input stream.
        audioContinuation?.finish()
        audioContinuation = nil
        // 2. Explicitly finalize the analyzer. THIS is load-bearing: finishing
        //    the input stream alone does NOT complete transcriber.results, so the
        //    resultsTask loop never ends and its final emitTranscript(isFinal:true)
        //    never runs — which is why commit-at-end wrote nothing. finalizeAnd
        //    FinishThroughEndOfInput() flushes pending audio + promotes volatile
        //    results to final, completing the stream so the final transcript fires.
        let analyzer = self.analyzer
        Task {
            do {
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
            } catch is CancellationError {
                // normal if a newer session superseded this one
            } catch {
                NSLog("SonarDictate: analyzer finalize error: \(error)")
            }
        }
    }

    // MARK: - Internals

    private func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter, to outFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = outFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }

        if let error {
            NSLog("SonarDictate: audio conversion error: \(error.localizedDescription)")
            return nil
        }
        if status == .error { return nil }
        return output.frameLength > 0 ? output : nil
    }

    private func handle(result: SpeechTranscriber.Result) {
        let plain = String(result.text.characters)
        let key = result.range.start.seconds.rounded(toMilliseconds: 3)
        chunksQueue.sync {
            if result.isFinal {
                // Committed segment: store under its range and drop the volatile
                // tail it supersedes — otherwise the in-progress copy doubles it.
                self.finalizedChunks[key] = plain
                self.volatileText = ""
            } else {
                // Only the latest volatile matters. Each volatile result's text is
                // the full guess for its (un-finalized) range, so replace — never
                // append — the previous volatile.
                self.volatileText = plain
            }
        }
        emitTranscript(isFinal: false)
    }

    private func emitTranscript(isFinal: Bool) {
        let (finals, vol): ([Double: String], String) = chunksQueue.sync {
            (self.finalizedChunks, self.volatileText)
        }
        var parts = finals.keys.sorted().compactMap { finals[$0] }
        // Live tail (volatile) is shown only for partial/overlay updates. The
        // committed transcript (isFinal) is finals-only, so nothing doubles.
        if !isFinal, !vol.isEmpty { parts.append(vol) }
        let assembled = parts
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
