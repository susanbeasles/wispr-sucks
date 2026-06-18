import Foundation
import AVFoundation
import Speech
import CoreMedia

// Thin wrapper around macOS 26's SpeechAnalyzer + SpeechTranscriber.
//
// Why this exists vs. SFSpeechRecognizer:
//   - Partial cadence ~50-100ms instead of 200-500ms (sub-network-RTT,
//     so we beat any cloud streaming product on perceived latency).
//   - Native volatile/final result distinction via per-result CMTimeRange.
//   - Apple ships the model on macOS 26+; nothing to install.
//
// AUDIO FORMAT (load-bearing - see git history): SpeechAnalyzer traps with
// EXC_BREAKPOINT inside preRunRecognition() if fed an incompatible PCM
// format. The mic input node is typically 48kHz Float32; the transcriber
// wants whatever bestAvailableAudioFormat reports. We negotiate that format
// at start() and run every buffer through an AVAudioConverter before feeding
// AnalyzerInput. Do NOT feed raw mic buffers directly - it crashes.

@available(macOS 26.0, *)
final class SpeechAnalyzerSession {
    private let locale: Locale
    private let context = AnalysisContext()

    // Compiled custom-vocabulary language model (built once from the user's
    // dictionary - see prepareVocabulary). Attached to the transcriber as a content
    // hint so the recognizer RELIABLY prefers their jargon (contextual strings were
    // too soft to ever stick). nil until built / if the build fails.
    private var customModelConfig: SFSpeechLanguageModel.Configuration?

    private var transcriber: DictationTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var audioContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    // Audio format conversion: mic format -> transcriber-compatible format.
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    // Final (committed) transcript segments, keyed by range start (ms). Volatile
    // (in-progress) results are tracked SEPARATELY: mixing volatile + final in
    // one map doubled every phrase, because a volatile and its final can have
    // range starts that jitter by ~1ms -> different keys -> both survive. Finals
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
    private var droppedBufferCount = 0
    private var resultCount = 0
    private var peakAmplitude: Float = 0
    // Diagnostic: what real transcriptionConfidence values are we actually reading?
    // confObs=0 => the attribute isn't populating (confidence stuck at default).
    // confObs>0 with a high min => the model is overconfident even on garbage.
    private var confObsCount = 0
    private var confObsSum = 0.0
    private var confObsMin = 1.0
    private var confObsMax = 0.0
    // How often the mid-word truncation guard fired this session (the recognizer
    // committed a final that chopped letters off the word the user just saw, and
    // we restored the fuller volatile). truncRestoreChars = total tail chars saved.
    // Content-free: counts only, no transcript text. Proves the guard is working
    // via `sonar-dictate logs` without inspecting any dictated content.
    private var truncRestoreCount = 0
    private var truncRestoreChars = 0
    private let diagLock = NSLock()


    var onTranscriptUpdate: (@Sendable (_ transcript: String, _ isFinal: Bool) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    func setContextualStrings(_ strings: [String]) {
        context.contextualStrings[.general] = strings
    }

    // Build a custom-vocabulary language model from the user's terms and compile it,
    // so the recognizer reliably prefers their jargon. Best-effort + async (export +
    // compile take a beat): runs once at launch (and again when the vocabulary
    // changes). On success, customModelConfig is set and start() attaches it.
    //
    // DEDUPED: trims, drops empties, and removes case-insensitive duplicates so a
    // phrase is never weighted more than once just for appearing twice.
    func prepareVocabulary(_ rawTerms: [String]) async {
        var seen = Set<String>()
        let terms = rawTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
        guard !terms.isEmpty else { customModelConfig = nil; return }

        let dir = SecureStore.baseDir.appendingPathComponent("vocab", isDirectory: true)
        let assetURL = dir.appendingPathComponent("vocab.bin")
        let modelURL = dir.appendingPathComponent("vocab.lm")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = SFCustomLanguageModelData(locale: locale,
                                                 identifier: "com.sonarmd.sonardictate.vocab",
                                                 version: "1")
            // High count = strong bias. count:10 was too weak to beat common
            // homophones ("git" kept losing to "get"). Crank it so the user's jargon
            // wins. (If this over-biases - normal "get" becoming "git" - dial down.)
            for term in terms {
                SFCustomLanguageModelData.PhraseCount(phrase: term, count: 200).insert(data: data)
            }
            try await data.export(to: assetURL)
            let config = SFSpeechLanguageModel.Configuration(languageModel: modelURL)
            try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: assetURL,
                                                                       configuration: config,
                                                                       ignoresCache: false)
            customModelConfig = config
            NSLog("SonarDictate: custom vocabulary model ready (\(terms.count) terms)")
        } catch {
            customModelConfig = nil
            NSLog("SonarDictate: custom vocabulary model build failed: \(error.localizedDescription)")
        }
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
        // session never emits a final result - which kills finalize()/broadcast.
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
        // for the exact use case we have - live voice into text input.
        //
        // Built from explicit options instead of the .progressiveLongDictation
        // preset for ONE reason: the preset initializer cannot opt into
        // attributeOptions, and we need .transcriptionConfidence to drive the
        // widget's REAL confidence (the preset only gives volatile streaming).
        // reportingOptions:[.volatileResults] reproduces the preset's live
        // streaming-with-volatile-partials cadence (the live preview UX); the
        // confidence attribute then rides on each result's text runs.
        var hints: Set<DictationTranscriber.ContentHint> = []
        if let cfg = customModelConfig {
            hints.insert(.customizedLanguage(modelConfiguration: cfg))   // bias toward the user's jargon
        }
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: hints,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.transcriptionConfidence]
        )
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

        // BOUNDED buffer (was the default .unbounded). The realtime tap yields ~21
        // buffers/sec; if the analyzer stalls or falls behind on a long hold, an
        // unbounded queue silently absorbs hundreds of buffers and the session ends
        // having produced ZERO results (the long-dictation failure). 64 items is
        // ~3s of slack - a healthy analyzer never reaches it (no drops, no behavior
        // change for working sessions); a genuinely-stalled one drops buffers (which
        // the new droppedBufferCount surfaces) instead of backlogging into silence.
        let (audioStream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.audioContinuation = continuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Hand the contextual-strings bias (personal dictionary + RAG terms, set
        // via setContextualStrings before start()) TO the analyzer. This was the
        // missing wire: the AnalysisContext was populated but never applied, so the
        // recognizer got zero bias and mangled jargon ("git"->"get", "egress"->
        // "addresses") even when the term was already in the dictionary. Best-effort
        // - a context-set failure must never break dictation.
        do {
            try await analyzer.setContext(context)
        } catch {
            NSLog("SonarDictate: setContext failed (\(error.localizedDescription)); proceeding without vocabulary bias")
        }

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
            // No conversion needed (formats matched) - feed directly.
            noteYield(continuation.yield(AnalyzerInput(buffer: buffer)))
            return
        }
        guard let converted = convert(buffer, with: converter, to: outFormat) else { return }
        noteYield(continuation.yield(AnalyzerInput(buffer: converted)))
    }

    // Count buffers the bounded stream dropped (analyzer genuinely slower than
    // realtime). fed high + dropped>0 => raise the buffer bound or the consumer is
    // too slow; dropped=0 on a healthy long session proves the buffering fix holds.
    private func noteYield(_ result: AsyncStream<AnalyzerInput>.Continuation.YieldResult) {
        if case .dropped = result {
            diagLock.lock(); droppedBufferCount += 1; diagLock.unlock()
        }
    }

    func stop() {
        // 0. Feed a short trailing SILENCE before ending input. The streaming
        //    endpointer needs trailing low-energy audio to promote the genuinely-
        //    last word from volatile to final; without it an abrupt key-release
        //    truncated the last ~150-190ms of speech (final range ended early,
        //    volLen=0). Yield it in the already-negotiated analyzer format (no
        //    converter), zeroed so it reads as true silence. The analyzer consumes
        //    input faster than realtime, so this adds compute time, not wall-clock.
        if let continuation = audioContinuation, let fmt = analyzerFormat {
            let frames = AVAudioFrameCount(fmt.sampleRate * 0.25)  // ~250ms
            if let silence = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) {
                silence.frameLength = frames
                let abl = UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList)
                for buf in abl { if let p = buf.mData { memset(p, 0, Int(buf.mDataByteSize)) } }
                continuation.yield(AnalyzerInput(buffer: silence))
            }
        }
        // 1. Signal no-more-audio by finishing the input stream.
        audioContinuation?.finish()
        audioContinuation = nil
        // 2. Explicitly finalize the analyzer. THIS is load-bearing: finishing
        //    the input stream alone does NOT complete transcriber.results, so the
        //    resultsTask loop never ends and its final emitTranscript(isFinal:true)
        //    never runs - which is why commit-at-end wrote nothing. finalizeAnd
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

    // Warm the speech recognition stack at app launch so the FIRST real
    // dictation doesn't pay the one-time cold model-load cost (the "big delay
    // when I first start"). Spins up a THROWAWAY analyzer and feeds it ~100ms of
    // synthetic silence in the analyzer's own format - no AVAudioEngine, no mic,
    // no privacy indicator, no permission prompt. Best-effort: any failure is
    // ignored (the real session, a separate instance, still works cold). Only
    // warms when assets are already installed; never triggers a download here.
    static func prewarm(locale: Locale = Locale(identifier: "en-US")) async {
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else { return }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return }
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let frames = AVAudioFrameCount(format.sampleRate * 0.1)  // ~100ms
        if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
            silence.frameLength = frames  // contents are silence/garbage; output is discarded
            continuation.yield(AnalyzerInput(buffer: silence))
        }
        continuation.finish()

        do {
            try await analyzer.start(inputSequence: stream)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            NSLog("SonarDictate: speech model prewarmed at launch")
        } catch {
            NSLog("SonarDictate: prewarm skipped (\(error.localizedDescription))")
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
        WidgetSignals.shared.noteActivity()   // recognizer produced output -> not starving
        let plain = String(result.text.characters)
        let key = result.range.start.seconds.rounded(toMilliseconds: 3)
        // TEMP diagnostic (content-free): the raw result stream, to see whether
        // the recognizer ever emits the final words or the assembly drops them.
        NSLog("SonarDictate: result isFinal=\(result.isFinal) range=[\(String(format: "%.2f", result.range.start.seconds))..\(String(format: "%.2f", result.range.end.seconds))] len=\(plain.count)")

        // LED widget signals (additive; not consumed by transcription). Confidence
        // is proxied from volatile-tail churn; a non-empty final is a "snap" pulse.
        // REAL confidence: average the recognizer's per-run transcriptionConfidence
        // (0..1) over this result. This is the model's own certainty - NOT inferred
        // from volatile churn. The old proxy dropped on every word rewrite, but a
        // streaming recognizer rewrites constantly even on clean speech, so it
        // yo-yoed into "severe lossy" during perfect dictation. Real confidence stays
        // high for clean speech and only dips when the model is genuinely unsure.
        var confSum = 0.0, confN = 0
        for run in result.text.runs {
            if let cv = run.transcriptionConfidence { confSum += cv; confN += 1 }
        }
        if confN > 0 {
            let avg = confSum / Double(confN)
            WidgetSignals.shared.publishConfidence(Float(avg))
            diagLock.lock()
            confObsCount += 1; confObsSum += avg
            confObsMin = min(confObsMin, avg); confObsMax = max(confObsMax, avg)
            diagLock.unlock()
        }
        if result.isFinal && !plain.isEmpty {
            WidgetSignals.shared.snap()
        }

        var didRestore = false
        var restoredTail = 0
        chunksQueue.sync {
            if result.isFinal {
                // An empty final must NOT wipe the volatile tail. DictationTranscriber
                // (and the forced flush in stop()/finalizeAndFinishThroughEndOfInput)
                // can emit a final result with empty text at a segment boundary. If we
                // stored "" and cleared volatileText, we would drop the words the user
                // just said and still has on screen - the "swallowed the whole thing,
                // shows empty" bug. An empty final carries no words to commit, so ignore
                // it entirely and keep the live tail intact.
                guard !plain.isEmpty else { return }
                // Mid-word truncation guard. The recognizer sometimes commits a final
                // that is a strict character PREFIX of the volatile tail the user just
                // saw on screen - it heard the whole word (audio range is preserved)
                // but emitted fewer letters ("github" shown, "githu" committed). When
                // that happens, restore the fuller volatile so the trailing letters are
                // not dropped. Gated tight so it only ever EXTENDS, never reinterprets:
                //   - exact hasPrefix (no case/normalization games)
                //   - the dropped remainder has NO space: it is the rest of the SAME
                //     last word, not a distinct later word (a space means the final
                //     deliberately dropped a separate token, e.g. a correct
                //     "testing testing" -> "testing" collapse: keep the final)
                //   - remainder is short (<=5): a longer no-space tail over a multi-
                //     second utterance is a deliberate revision/URL/compound, not one
                //     truncated word: keep the final
                //   - the final ends mid-word (last char is a letter/digit): if it
                //     already ends on a space or sentence punctuation, the tail is not
                //     a truncated word: keep the final (punctuation/casing the finalize
                //     adds is an improvement, leave it)
                // Non-prefix finals (a real rewrite like "git" -> "get") fall straight
                // through to `plain`, so this is a strict superset of the old behavior.
                var committed = plain
                if self.volatileText.hasPrefix(plain), let last = plain.last,
                   last.isLetter || last.isNumber {
                    let remainder = self.volatileText.dropFirst(plain.count)
                    if !remainder.contains(" ") && remainder.count <= 5 {
                        committed = self.volatileText
                        didRestore = true
                        restoredTail = remainder.count
                    }
                }
                // Committed segment: store under its range and drop the volatile
                // tail it supersedes - otherwise the in-progress copy doubles it.
                self.finalizedChunks[key] = committed
                self.volatileText = ""
            } else {
                // Only the latest volatile matters. Each volatile result's text is
                // the full guess for its (un-finalized) range, so replace - never
                // append - the previous volatile.
                self.volatileText = plain
            }
        }
        // Tally a guard fire OUTSIDE chunksQueue.sync so diagLock is never nested
        // inside the chunks queue (lock-ordering safety). didRestore/restoredTail
        // were set by the non-escaping sync closure above.
        if didRestore {
            diagLock.lock()
            truncRestoreCount += 1
            truncRestoreChars += restoredTail
            diagLock.unlock()
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
        droppedBufferCount = 0
        resultCount = 0
        peakAmplitude = 0
        confObsCount = 0; confObsSum = 0; confObsMin = 1; confObsMax = 0
        truncRestoreCount = 0; truncRestoreChars = 0
        diagLock.unlock()
    }

    // Count one fed buffer and track the session's peak audio amplitude. Runs on
    // the realtime audio thread; the sample scan is lock-free and the lock is held
    // only for the brief counter update. Peak near 0 over a whole session means
    // the mic captured (near-)silence - i.e. the user was not really speaking.
    private func recordDiagnostics(for buffer: AVAudioPCMBuffer) {
        var peak: Float = 0
        var sumSq: Float = 0
        var count = 0
        if let ch = buffer.floatChannelData {
            let n = Int(buffer.frameLength)
            let samples = ch[0]
            var i = 0
            while i < n {
                let a = abs(samples[i])
                if a > peak { peak = a }
                sumSq += samples[i] * samples[i]
                i += 1
            }
            count = n
        }
        // Additive, behavior-free: publish this buffer's RMS to the widget LED bus.
        // Realtime audio thread; WidgetSignals.publishEnergy is a single lock + store.
        if count > 0 {
            WidgetSignals.shared.publishEnergy((sumSq / Float(count)).squareRoot())
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
        let fed = fedBufferCount, dropped = droppedBufferCount, res = resultCount, peak = peakAmplitude
        let cObs = confObsCount, cAvg = confObsCount > 0 ? confObsSum / Double(confObsCount) : 0
        let cMin = confObsCount > 0 ? confObsMin : 0, cMax = confObsMax
        let tRestore = truncRestoreCount, tChars = truncRestoreChars
        diagLock.unlock()
        NSLog("SonarDictate: session diag [\(outcome)] - fed=\(fed) buffers, dropped=\(dropped), results=\(res), peakAmplitude=\(String(format: "%.4f", peak)), confObs=\(cObs) confAvg=\(String(format: "%.3f", cAvg)) confMin=\(String(format: "%.3f", cMin)) confMax=\(String(format: "%.3f", cMax)) truncRestore=\(tRestore) restoredChars=\(tChars)")
    }
}

private extension Double {
    func rounded(toMilliseconds digits: Int) -> Double {
        let mult = pow(10.0, Double(digits))
        return (self * mult).rounded() / mult
    }
}
