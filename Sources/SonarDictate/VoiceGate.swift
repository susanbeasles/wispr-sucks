import AVFoundation

enum VoiceGateMode: String {
    case off      // gating disabled entirely
    case shadow   // evaluate + count, but forward everything (validation)
    case active   // actually drop non-speech before the transcriber
}

struct VoiceGateDecision {
    let speaking: Bool
    let energyDb: Float
    let pitchHz: Float
    let voicing: Float   // 0..1 normalized autocorrelation peak in the voice band
    let zcr: Float        // zero-crossing rate (fraction of samples)
    let held: Bool        // passed only because of the hysteresis hangover
}

// Decides, per audio buffer, whether the user is speaking, so non-speech (silence,
// broadband noise, non-vocal music) can be kept out of the transcriber feed. This
// is the seam target-speaker isolation plugs into; for now it is speaker-GENERIC
// (energy + voicing + zero-crossing). A voiceprint stage slots into evaluate()
// later without changing the wiring.
//
// Runs on the realtime audio thread: allocation-free, pure arithmetic, no locks
// (single-threaded - the tap is the only caller, and counters are read only after
// the tap is removed). Hysteresis holds the gate OPEN for a hangover after speech
// so word-endings and short pauses are never clipped - the cardinal sin here.
final class VoiceGate {
    let mode: VoiceGateMode
    private let sampleRate: Float
    private let minLag: Int
    private let maxLag: Int
    private let energyFloorDb: Float
    private let voicingMin: Float
    private let zcrMax: Float
    private let hangoverWindows: Int

    private var hangover = 0

    // Shadow-mode validation counters (read at session end, after the tap is gone).
    private(set) var totalWindows = 0
    private(set) var speechWindows = 0   // raw speech detected (pre-hysteresis)
    private(set) var forwardWindows = 0  // would be forwarded (incl. hangover holds)
    private(set) var dropWindows = 0     // would be dropped in active mode

    init(mode: VoiceGateMode, sampleRate: Double) {
        self.mode = mode
        let sr = Float(sampleRate)
        self.sampleRate = sr
        // Voice band 80-320 Hz -> autocorrelation lag range.
        self.minLag = max(2, Int(sr / 320))
        self.maxLag = max(self.minLag + 1, Int(sr / 80))
        let env = ProcessInfo.processInfo.environment
        self.energyFloorDb = Float(env["IRIS_GATE_FLOOR_DB"] ?? "") ?? -50
        self.voicingMin = Float(env["IRIS_GATE_VOICING"] ?? "") ?? 0.35
        self.zcrMax = Float(env["IRIS_GATE_ZCR_MAX"] ?? "") ?? 0.30
        // ~400ms of hold at ~21ms/buffer: never clip a trailing word or a brief gap.
        self.hangoverWindows = Int(env["IRIS_GATE_HANGOVER"] ?? "") ?? 19
    }

    func reset() {
        hangover = 0
        totalWindows = 0; speechWindows = 0; forwardWindows = 0; dropWindows = 0
    }

    func evaluate(_ buffer: AVAudioPCMBuffer) -> VoiceGateDecision {
        totalWindows += 1
        guard let ch = buffer.floatChannelData, buffer.frameLength >= 64 else {
            return decide(raw: false, energyDb: -120, pitch: 0, voicing: 0, zcr: 0)
        }
        let n = Int(buffer.frameLength)
        let x = ch[0]

        var sumSq: Float = 0
        var zc = 0
        var prev = x[0]
        for i in 0..<n {
            let s = x[i]
            sumSq += s * s
            if (s >= 0) != (prev >= 0) { zc += 1 }
            prev = s
        }
        let rms = (sumSq / Float(n)).squareRoot()
        let energyDb: Float = rms > 1e-9 ? 20 * log10f(rms) : -120
        let zcr = Float(zc) / Float(n)

        if energyDb < energyFloorDb {
            return decide(raw: false, energyDb: energyDb, pitch: 0, voicing: 0, zcr: zcr)
        }

        // Normalized autocorrelation peak in the voice band: high + periodic == voiced.
        var bestVoicing: Float = 0
        var bestLag = 0
        let hi = min(maxLag, n - 1)
        if hi > minLag && sumSq > 1e-9 {
            var lag = minLag
            while lag <= hi {
                var acc: Float = 0
                var i = 0
                let m = n - lag
                while i < m { acc += x[i] * x[i + lag]; i += 1 }
                let r = acc / sumSq
                if r > bestVoicing { bestVoicing = r; bestLag = lag }
                lag += 1
            }
        }
        let pitch = bestLag > 0 ? sampleRate / Float(bestLag) : 0
        let voiced = bestVoicing >= voicingMin && zcr <= zcrMax
        return decide(raw: voiced, energyDb: energyDb, pitch: pitch, voicing: bestVoicing, zcr: zcr)
    }

    private func decide(raw: Bool, energyDb: Float, pitch: Float, voicing: Float, zcr: Float) -> VoiceGateDecision {
        var speaking = raw
        var held = false
        if raw {
            hangover = hangoverWindows
            speechWindows += 1
        } else if hangover > 0 {
            hangover -= 1
            speaking = true
            held = true
        }
        if speaking { forwardWindows += 1 } else { dropWindows += 1 }
        return VoiceGateDecision(speaking: speaking, energyDb: energyDb, pitchHz: pitch,
                                 voicing: voicing, zcr: zcr, held: held)
    }

    func shouldForward(_ d: VoiceGateDecision) -> Bool {
        switch mode {
        case .off, .shadow: return true   // forward everything; counters still tallied
        case .active: return d.speaking
        }
    }

    // Content-free validation line for the session log. In shadow mode, dropWindows
    // is what active mode WOULD have removed - if it is high while the recognizer
    // produced results, the gate is too aggressive and must not be activated yet.
    func summary() -> String {
        let pct = totalWindows > 0 ? (Double(dropWindows) / Double(totalWindows) * 100) : 0
        return "gate[\(mode.rawValue)] windows=\(totalWindows) speech=\(speechWindows) " +
               "forward=\(forwardWindows) wouldDrop=\(dropWindows) (\(String(format: "%.0f", pct))%)"
    }
}
