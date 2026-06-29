import AVFoundation
import Foundation

// Enrollment + matching support for the owner voiceprint (tier 2 P3). Captures a few
// seconds of mic audio, resampled to the model's 16 kHz mono, and turns it into a
// stable template by averaging embeddings over overlapping windows.
//
// No system-audio grant - just the mic (NSMicrophoneUsageDescription, already in the
// app's Info.plist). Capture is self-contained so `sonar-dictate enroll` works from
// the CLI without the full Dictator pipeline.

@available(macOS 14.0, *)
enum VoiceEnroll {
    static let targetRate: Double = 16000

    // Record `seconds` of mic audio as 16 kHz mono Float. Blocks the calling thread.
    static func captureMono16k(seconds: Double) throws -> [Float] {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw VoiceEmbedder.EmbedderError.modelLoad("enroll: could not build 16k converter")
        }

        let lock = NSLock()
        var samples: [Float] = []

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
            let ratio = targetRate / inFormat.sampleRate
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if let ch = out.floatChannelData, out.frameLength > 0 {
                let n = Int(out.frameLength)
                lock.lock()
                samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
                lock.unlock()
            }
        }

        engine.prepare()
        try engine.start()
        Thread.sleep(forTimeInterval: seconds)
        engine.stop()
        input.removeTap(onBus: 0)

        lock.lock(); defer { lock.unlock() }
        return samples
    }

    // Build a template from captured 16k mono audio: embed overlapping windows and
    // average. Windows give a more stable template than one embedding of the whole.
    static func template(from audio: [Float], embedder: VoiceEmbedder) throws -> [Float] {
        let win = Int(targetRate * 3)      // 3s windows
        let hop = Int(targetRate * 1.5)    // 50% overlap
        var embeddings: [[Float]] = []
        if audio.count <= win {
            embeddings.append(try embedder.embed(audio))
        } else {
            var start = 0
            while start + win <= audio.count {
                embeddings.append(try embedder.embed(Array(audio[start..<start + win])))
                start += hop
            }
        }
        return VoiceprintStore.template(from: embeddings.filter { !$0.isEmpty })
    }
}
