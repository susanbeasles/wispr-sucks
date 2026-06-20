import AVFoundation
import Foundation
import ScreenCaptureKit

// Iris's ears for a call. Captures TWO audio sources on-device and transcribes
// each with its own CallTranscriber (separate from the sealed dictation path):
//   - you  = the microphone (AVAudioEngine)
//   - them = the call / system audio (ScreenCaptureKit, capturesAudio)
//
// Emits finalized, speaker-labeled segments via onSegment(label, text). Nothing
// is persisted by this class; the transcript lives wherever the consumer keeps
// it. PHI: all on-device; system-audio capture needs the Screen Recording grant
// the eyes already use. excludesCurrentProcessAudio keeps Iris's own voice out.
@available(macOS 26.0, *)
final class CallListener: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var isListening = false

    private let you = CallTranscriber(label: "you")
    private let them = CallTranscriber(label: "them")
    private var micEngine: AVAudioEngine?
    private var stream: SCStream?
    private var themStarted = false
    private var segCount = 0
    private var youSegs = 0
    private var themSegs = 0
    private var themBufferCount = 0
    private var resultCount = 0
    private var lastError = ""
    private let audioQueue = DispatchQueue(label: "com.sonarmd.dictate.call.audio")

    // (label, text) per finalized segment, delivered on the main actor.
    var onSegment: ((String, String) -> Void)?
    // Listening-state edges (for the UI indicator).
    var onState: ((Bool) -> Void)?
    // Live, content-free counts for the on-screen indicator (no log/CLI needed).
    var onDiag: ((String) -> Void)?

    private func emitDiag() {
        var text = "sys:\(themBufferCount)buf  res:\(resultCount)  you:\(youSegs)  them:\(themSegs)"
        if !lastError.isEmpty { text += "  ERR:\(lastError.prefix(40))" }
        DispatchQueue.main.async { [weak self] in self?.onDiag?(text) }
    }

    private func noteResult() {
        resultCount += 1
        if resultCount <= 3 || resultCount % 10 == 0 { emitDiag() }
    }

    private func noteError(_ message: String) {
        lastError = message
        NSLog("SonarDictate: call transcriber error: \(message)")
        emitDiag()
    }

    func start() async throws {
        guard !isListening else { return }
        you.onSegment = { [weak self] l, t in self?.note(l, t) }
        them.onSegment = { [weak self] l, t in self?.note(l, t) }
        you.onResult = { [weak self] in self?.noteResult() }
        them.onResult = { [weak self] in self?.noteResult() }
        you.onError = { [weak self] m in self?.noteError("you/" + m) }
        them.onError = { [weak self] m in self?.noteError("them/" + m) }

        // --- you: microphone ---
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        try await you.start(inputFormat: micFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
            self?.you.append(buffer)
        }
        engine.prepare()
        try engine.start()
        self.micEngine = engine

        // --- them: system audio via ScreenCaptureKit ---
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "CallListener", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display for system audio"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // SCStream wants a video output to start; we keep it tiny and ignore it.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream

        isListening = true
        onState?(true)
        NSLog("SonarDictate: call listener STARTED - mic \(Int(micFormat.sampleRate))Hz/\(micFormat.channelCount)ch + system audio stream")
    }

    // Content-free diagnostics so we can verify hearing without exposing words.
    private func note(_ label: String, _ text: String) {
        segCount += 1
        if label == "you" { youSegs += 1 } else { themSegs += 1 }
        onSegment?(label, text)
        emitDiag()
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
        you.stop()
        if let s = stream {
            Task { try? await s.stopCapture() }
        }
        stream = nil
        them.stop()
        themStarted = false
        onState?(false)
    }

    func toggle() async {
        if isListening { stop(); return }
        do {
            try await start()
        } catch {
            NSLog("SonarDictate: call listener START FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - SCStreamOutput (system audio)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let pcm = Self.pcm(from: sampleBuffer) else { return }
        themBufferCount += 1
        if themBufferCount == 1 || themBufferCount % 50 == 0 { emitDiag() }
        if themStarted {
            them.append(pcm)
        } else {
            themStarted = true
            let format = pcm.format
            Task { [weak self] in
                try? await self?.them.start(inputFormat: format)
                self?.them.append(pcm)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("SonarDictate: call listener system-audio stream stopped: \(error.localizedDescription)")
    }

    // Convert a CoreMedia audio sample buffer to an AVAudioPCMBuffer the
    // transcriber's converter can take.
    private static func pcm(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else { return nil }
        var streamDesc = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDesc) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
        )
        return status == noErr ? pcm : nil
    }
}
