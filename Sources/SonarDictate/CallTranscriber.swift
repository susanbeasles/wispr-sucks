import AVFoundation
import Foundation
import Speech

// A standalone continuous speech-to-text stream for ONE labeled audio source
// (e.g. "you" = mic, "them" = call/system audio). It MIRRORS the sealed
// SpeechAnalyzerSession's setup - DictationTranscriber + bestAvailableAudioFormat
// negotiation + AVAudioConverter + an AnalyzerInput stream - but is a SEPARATE
// instance and never touches the sealed dictation path.
//
// Emits FINALIZED segments only (clean transcript lines, not volatile churn) via
// onSegment(label, text), delivered on the main actor.
@available(macOS 26.0, *)
final class CallTranscriber {
    let label: String
    private let locale: Locale

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?
    private var pending = ""
    private var flushTask: Task<Void, Never>?

    var onSegment: ((String, String) -> Void)?
    var onResult: (() -> Void)?          // any result (volatile or final) - proves the analyzer is alive
    var onError: ((String) -> Void)?     // start/results error surfaced for diagnosis

    init(label: String, locale: Locale = Locale(identifier: "en-US")) {
        self.label = label
        self.locale = locale
    }

    func start(inputFormat: AVAudioFormat) async throws {
        stopInternal()

        let preset = DictationTranscriber.Preset.progressiveLongDictation
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions,
            attributeOptions: preset.attributeOptions
        )

        // Ensure the locale's speech assets are installed (one-time; on-device after).
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .supported, let req = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try? await req.downloadAndInstall()
        }

        let negotiated = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.analyzerFormat = negotiated
        if let negotiated, negotiated != inputFormat {
            self.converter = AVAudioConverter(from: inputFormat, to: negotiated)
        } else {
            self.converter = nil
        }

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.continuation = cont
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let label = self.label
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    await MainActor.run { self?.onResult?() }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if result.isFinal {
                        // A real final (rare on a live call): commit immediately.
                        self?.flushTask?.cancel()
                        self?.pending = ""
                        await MainActor.run { self?.onSegment?(label, text) }
                    } else {
                        // Live calls stay volatile. Hold the latest text and commit it
                        // when speech PAUSES (~1.1s of no new results) = an utterance.
                        self?.pending = text
                        self?.scheduleFlush()
                    }
                }
            } catch is CancellationError {
                // normal on stop()
            } catch {
                let msg = error.localizedDescription
                await MainActor.run { self?.onError?("results:\(msg)") }
            }
        }
        analyzerTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: stream)
            } catch is CancellationError {
                // normal on stop()
            } catch {
                let msg = error.localizedDescription
                await MainActor.run { self?.onError?("start:\(msg)") }
            }
        }
    }

    // Feed one audio buffer (realtime thread). Converts to the analyzer format first.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let continuation else { return }
        if let converter, let outFormat = analyzerFormat,
           let converted = Self.convert(buffer, with: converter, to: outFormat) {
            continuation.yield(AnalyzerInput(buffer: converted))
        } else {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
    }

    // Commit the held volatile text after a short pause (an utterance boundary),
    // since a live call rarely yields a "final" result the way push-to-talk does.
    private func scheduleFlush() {
        flushTask?.cancel()
        let label = self.label
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled, let self else { return }
            let text = self.pending
            guard !text.isEmpty else { return }
            self.pending = ""
            await MainActor.run { self.onSegment?(label, text) }
        }
    }

    func stop() {
        continuation?.finish()
        let analyzer = self.analyzer
        Task { try? await analyzer?.finalizeAndFinishThroughEndOfInput() }
        stopInternal()
    }

    private func stopInternal() {
        continuation?.finish()
        continuation = nil
        flushTask?.cancel()
        flushTask = nil
        pending = ""
        resultsTask?.cancel()
        analyzerTask?.cancel()
        resultsTask = nil
        analyzerTask = nil
        analyzer = nil
        converter = nil
        analyzerFormat = nil
    }

    private static func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter, to outFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = outFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        if error != nil { return nil }
        return output.frameLength > 0 ? output : nil
    }
}
