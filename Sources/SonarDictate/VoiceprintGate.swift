import AVFoundation
import Foundation

// Owner gate (tier 2 P4): rejects sustained NON-owner audio (another speaker, vocal
// music the harmonic filter passes) from the transcriber feed by matching a rolling
// window against the enrolled voiceprint. Default OFF (IRIS_VOICEPRINT).
//
// REAL-TIME SAFETY (the capture path is SEALED, release-to-field must be INSTANT):
// ingest() runs on the audio thread and does NOTHING but copy samples into a ring
// under a lock - no embedding, no resample, no allocation-heavy work. The ECAPA
// embedding + 16k resample run on a background queue; a single atomic flag
// (ownerPresent) is all the audio thread reads. CARDINAL RULE: never clip the owner -
// the gate forwards by default and only blocks after sustained confident non-owner
// evidence, with hysteresis. It gates the transcriber feed only; the raw WAV is
// always complete.

@available(macOS 14.0, *)
final class VoiceprintGate {
    private let template: [Float]
    private let embedder: VoiceEmbedder
    private let threshold: Float
    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    private let queue = DispatchQueue(label: "sonar-dictate.voiceprint-gate", qos: .userInitiated)
    private let lock = NSLock()
    private var ring: [Float] = []
    private var sinceLastEval = 0
    private var evaluating = false

    private let windowSamples: Int        // at input rate
    private let hopSamples: Int

    // ownerPresent starts true so dictation is never clipped before the first
    // evaluation. Negative evidence must accumulate to flip it off (hysteresis).
    private var _ownerPresent = true
    private var missStreak = 0
    var ownerPresent: Bool { lock.lock(); defer { lock.unlock() }; return _ownerPresent }

    init?(template: [Float], embedder: VoiceEmbedder, inputFormat: AVAudioFormat) {
        guard !template.isEmpty,
              let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VoiceEnroll.targetRate, channels: 1, interleaved: false)
        else { return nil }
        self.template = template
        self.embedder = embedder
        self.threshold = VoiceprintStore.threshold
        self.inFormat = inputFormat
        self.outFormat = out
        self.converter = AVAudioConverter(from: inputFormat, to: out)
        self.windowSamples = Int(inputFormat.sampleRate * 1.5)   // ~1.5s window
        self.hopSamples = Int(inputFormat.sampleRate * 0.75)     // evaluate ~every 0.75s
    }

    // Audio thread: copy only. Triggers a background eval when a hop has accrued.
    func ingest(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock()
        ring.append(contentsOf: samples)
        if ring.count > windowSamples { ring.removeFirst(ring.count - windowSamples) }
        sinceLastEval += samples.count
        let ready = sinceLastEval >= hopSamples && ring.count >= windowSamples && !evaluating
        if ready {
            sinceLastEval = 0
            evaluating = true
            let window = ring   // value copy under lock
            lock.unlock()
            queue.async { [weak self] in self?.evaluate(window) }
            return
        }
        lock.unlock()
    }

    private func evaluate(_ window: [Float]) {
        defer { lock.lock(); evaluating = false; lock.unlock() }
        guard let mono16k = resample(window), mono16k.count > Int(VoiceEnroll.targetRate / 2) else { return }
        guard let emb = try? embedder.embed(mono16k), !emb.isEmpty else { return }
        let cos = VoiceEmbedder.cosine(emb, template)
        lock.lock()
        if cos >= threshold {
            missStreak = 0
            _ownerPresent = true
        } else {
            missStreak += 1
            // Require two consecutive confident misses before muting - a single
            // low score (a transient, a quiet patch) must not clip the owner.
            if missStreak >= 2 { _ownerPresent = false }
        }
        lock.unlock()
    }

    private func resample(_ samples: [Float]) -> [Float]? {
        guard let converter else { return samples }
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = inBuf.floatChannelData else { return nil }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { memcpy(ch[0], $0.baseAddress!, samples.count * MemoryLayout<Float>.size) }
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let cap = AVAudioFrameCount(Double(samples.count) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        guard err == nil, let oc = out.floatChannelData, out.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: oc[0], count: Int(out.frameLength)))
    }
}
