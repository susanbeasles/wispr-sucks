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

    // Range-keyed transcript chunks (CMTime seconds rounded to ms as key) so
    // volatile revisions of the same range start replace cleanly.
    private var chunks: [Double: String] = [:]
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

        chunksQueue.sync { self.chunks.removeAll() }

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
        audioContinuation?.finish()
        audioContinuation = nil
        // Let resultsTask drain so the user's last words come through.
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
        chunksQueue.sync { self.chunks[key] = plain }
        emitTranscript(isFinal: false)
    }

    private func emitTranscript(isFinal: Bool) {
        let snapshot: [Double: String] = chunksQueue.sync { self.chunks }
        let assembled = snapshot.keys.sorted()
            .compactMap { snapshot[$0] }
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
