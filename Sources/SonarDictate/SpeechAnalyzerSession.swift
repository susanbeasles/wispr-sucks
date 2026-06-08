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

    private var transcriber: DictationTranscriber?
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

    // Per-session diagnostics (reset each start). They distinguish "user was
    // silent" from "recognizer dropped real speech" when a transcript comes back
    // empty - the log alone could not tell those apart. Written from the realtime
    // audio thread (append) and the results task; guarded by diagLock.
    private var fedBufferCount = 0
    private var resultCount = 0
    private var peakAmplitude: Float = 0
    private let diagLock = NSLock()

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

        // DictationTranscriber instead of SpeechTranscriber: Apple ships two
        // recognizers in macOS 26. SpeechTranscriber is tuned for transcribing
        // recorded audio (meetings, podcasts). DictationTranscriber is tuned
        // for the exact use case we have - live voice into text input. The
        // .progressiveLongDictation preset gives the streaming-with-volatile-
        // partials cadence (same shape as SpeechTranscriber's .progressive-
        // Transcription) so the live preview UX is unchanged.
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        self.transcriber = transcriber

        // Ensure the language model assets are installed for this locale. Without
        // this, the transcriber initializes silently and runs through audio but
        // emits ZERO results - captured WAVs persist, finalize fires, transcript
        // is empty. This is the (load-bearing) one-time per-locale download; once
        // .installed everything else stays on-device.
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        NSLog("SonarDictate: speech assets status=\(assetStatus) for \(locale.identifier)")
        if assetStatus == .supported {
            do {
                if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    NSLog("SonarDictate: downloading speech model for \(locale.identifier)...")
                    try await req.downloadAndInstall()
                    NSLog("SonarDictate: speech model installed")
                } else {
                    NSLog("SonarDictate: assetInstallationRequest returned nil - no install path")
                }
            } catch {
                NSLog("SonarDictate: asset install error: \(error.localizedDescription)")
            }
        } else if assetStatus == .unsupported {
            NSLog("SonarDictate: speech assets UNSUPPORTED for \(locale.identifier) - transcription will be empty")
        } else if assetStatus == .downloading {
            NSLog("SonarDictate: speech model is already downloading - proceeding")
        }

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
        resetDiagnostics()

        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    self.handle(result: result)
                }
                self.logSessionDiagnostics(outcome: "completed")
                self.emitTranscript(isFinal: true)
            } catch is CancellationError {
                // normal cancel from stop() (e.g. a fast re-press superseding this session)
                self.logSessionDiagnostics(outcome: "cancelled")
            } catch {
                NSLog("SonarDictate: transcriber.results error: \(error)")
                self.logSessionDiagnostics(outcome: "error")
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
        recordDiagnostics(for: buffer)
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

    private func handle(result: DictationTranscriber.Result) {
        diagLock.lock(); resultCount += 1; diagLock.unlock()
        let plain = String(result.text.characters)
        let key = result.range.start.seconds.rounded(toMilliseconds: 3)
        // TEMP diagnostic (content-free): the raw result stream, to see whether
        // the recognizer ever emits the final words or the assembly drops them.
        NSLog("SonarDictate: result isFinal=\(result.isFinal) range=[\(String(format: "%.2f", result.range.start.seconds))..\(String(format: "%.2f", result.range.end.seconds))] len=\(plain.count)")
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
        // Always include the live volatile tail, including on the final emit.
        // DictationTranscriber keeps the most recent phrase in volatile state
        // until session-end - without including it here, the last thing the user
        // said gets silently dropped. Since each final clears volatileText, no
        // double-counting risk.
        if !vol.isEmpty { parts.append(vol) }
        let assembled = parts
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
        if isFinal {
            // TEMP diagnostic (content-free): which final segments survived and
            // whether a trailing volatile was still pending at finalize.
            let starts = finals.keys.sorted().map { String(format: "%.2f", $0) }.joined(separator: ",")
            NSLog("SonarDictate: FINAL assembled len=\(assembled.count) finals=[\(starts)] volLen=\(vol.count)")
        }
        onTranscriptUpdate?(assembled, isFinal)
    }

    // MARK: - Diagnostics

    // Zero the per-session counters. A synchronous method so the lock is never
    // taken directly inside the async start() (unavailable in async contexts).
    private func resetDiagnostics() {
        diagLock.lock()
        fedBufferCount = 0
        resultCount = 0
        peakAmplitude = 0
        diagLock.unlock()
    }

    // Count one fed buffer and track the session's peak audio amplitude. Runs on
    // the realtime audio thread; the sample scan is lock-free and the lock is held
    // only for the brief counter update. Peak near 0 over a whole session means
    // the mic captured (near-)silence - i.e. the user was not really speaking.
    private func recordDiagnostics(for buffer: AVAudioPCMBuffer) {
        var peak: Float = 0
        if let ch = buffer.floatChannelData {
            let n = Int(buffer.frameLength)
            let samples = ch[0]
            var i = 0
            while i < n {
                let a = abs(samples[i])
                if a > peak { peak = a }
                i += 1
            }
        }
        diagLock.lock()
        fedBufferCount += 1
        if peak > peakAmplitude { peakAmplitude = peak }
        diagLock.unlock()
    }

    // One line at session end summarizing how much audio reached the recognizer,
    // how many results it produced, and the peak amplitude. Reading an EMPTY
    // transcript:
    //   fed>0, results=0, peak high  => recognizer dropped real speech (a bug)
    //   fed>0, results=0, peak ~0    => mic heard near-silence (not a bug)
    //   outcome=cancelled            => a fast re-press superseded this session
    private func logSessionDiagnostics(outcome: String) {
        diagLock.lock()
        let fed = fedBufferCount, res = resultCount, peak = peakAmplitude
        diagLock.unlock()
        NSLog("SonarDictate: session diag [\(outcome)] - fed=\(fed) buffers, results=\(res), peakAmplitude=\(String(format: "%.4f", peak))")
    }
}

private extension Double {
    func rounded(toMilliseconds digits: Int) -> Double {
        let mult = pow(10.0, Double(digits))
        return (self * mult).rounded() / mult
    }
}
