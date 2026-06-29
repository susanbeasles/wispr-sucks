import Accelerate
import AVFoundation
import CoreAudio
import Foundation

// Our own acoustic echo canceller: tap all system audio as a reference, NLMS-
// subtract it from the mic so dictation survives over music from ANY source
// (built-in, Bluetooth, external) without ducking playback. The intended
// replacement for Apple VPIO.
//
// Phase 5 (integration) of .claude/plans/2026-06-24-053629-own-echo-canceller.md,
// built from the proven POCs in poc/aec (aecsync = capture, aecnlms = NLMS core).
// THIS phase (A): capture + streaming cancellation + ERLE instrumentation, behind
// IRIS_OWN_AEC / the `aectest` CLI. NOT yet wired to the recognizer (that is the
// SEALED capture path - phase B, separate approval).
//
// Realtime note: the IOProc block runs on a CoreAudio realtime thread. Per-block
// work is over pre-allocated buffers (no allocation) with vDSP math. Double-talk
// handling (do not cancel the user's OWN voice) is phase C - until then this is
// validated with music-only / talk-over-music by reading ERLE (echo return loss
// enhancement): music-only should drive the residual toward silence (high ERLE).

enum AECEngineError: Error, CustomStringConvertible {
    case noDefaultInput
    case os(OSStatus, String)
    var description: String {
        switch self {
        case .noDefaultInput: return "no default input device"
        case .os(let s, let w): return "AEC \(w) failed: OSStatus \(s)"
        }
    }
}

@available(macOS 14.2, *)   // CoreAudio process-tap APIs (CATapDescription etc.)
final class AECEngine {
    // NLMS parameters (env-tunable for on-device calibration; defaults from the POC).
    private let tapCount: Int      // L: filter length in taps (~64ms @ 16kHz at 1024)
    private let mu: Float          // step size
    private let eps: Float         // regularization

    // Cleaned mono voice (near-end minus estimated echo), at the aggregate's sample
    // rate. Phase B resamples/feeds this to the recognizer; phase A leaves it unset.
    var onCleanedAudio: (([Float], Double) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    // Filter state, persisted across IOProc blocks.
    private var w: [Float]
    // Reference history: (L-1) carry samples + the current block's reference, so
    // every output sample sees a contiguous L-tap window. One memmove per block.
    private let maxBlock = 8192
    private var refBuf: [Float]
    private var micScratch: [Float]
    private var cleaned: [Float]

    // ERLE accumulators: mic (near-end+echo) power vs residual power.
    private var sumMicSq: Double = 0
    private var sumResSq: Double = 0
    private var framesSeen: Int = 0
    private var lastLogFrames: Int = 0
    private var sampleRate: Double = 0

    init() {
        let env = ProcessInfo.processInfo.environment
        self.tapCount = Int(env["IRIS_AEC_TAPS"] ?? "") ?? 1024
        self.mu = Float(env["IRIS_AEC_MU"] ?? "") ?? 0.5
        self.eps = Float(env["IRIS_AEC_EPS"] ?? "") ?? 1e-6
        self.w = [Float](repeating: 0, count: tapCount)
        self.refBuf = [Float](repeating: 0, count: tapCount - 1 + maxBlock)
        self.micScratch = [Float](repeating: 0, count: maxBlock)
        self.cleaned = [Float](repeating: 0, count: maxBlock)
    }

    // MARK: - lifecycle

    func start() throws {
        guard let micUID = Self.defaultInputUID() else { throw AECEngineError.noDefaultInput }

        // Tap all system output EXCEPT our own process, so Iris's own TTS/playback
        // is not treated as echo to subtract.
        let tap = CATapDescription(monoGlobalTapButExcludeProcesses: Self.selfProcessObjects())
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        tap.name = "iris-aec-ref"
        var t = AudioObjectID(kAudioObjectUnknown)
        try Self.ck(AudioHardwareCreateProcessTap(tap, &t), "createTap")
        tapID = t

        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "IrisAEC",
            kAudioAggregateDeviceUIDKey: "com.sonarmd.dictate.aec.\(getpid())",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: micUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString]],
        ]
        var a = AudioObjectID(kAudioObjectUnknown)
        try Self.ck(AudioHardwareCreateAggregateDevice(desc as CFDictionary, &a), "createAggregate")
        aggID = a
        sampleRate = Self.streamSampleRate(aggID)

        var proc: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&proc, aggID, nil) { [weak self] _, inData, _, _, _ in
            self?.process(inData)
        }
        try Self.ck(st, "createIOProc")
        procID = proc
        try Self.ck(AudioDeviceStart(aggID, proc), "start")
        NSLog("SonarDictate: AEC started (taps=\(tapCount) mu=\(mu) sr=\(Int(sampleRate)))")
    }

    func stop() {
        if let p = procID {
            AudioDeviceStop(aggID, p)
            AudioDeviceDestroyIOProcID(aggID, p)
            procID = nil
        }
        if aggID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    // MARK: - realtime processing

    // Layout: the aggregate presents the mic channel(s) first, then the tap
    // (reference) channel(s) (see poc/aec/aecsync). We take the FIRST channel as
    // the near-end mic and the LAST as the far-end reference. Handles both an
    // interleaved single buffer and the planar (one buffer per channel) layout.
    private func process(_ inData: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        let nbuf = abl.count
        guard nbuf >= 1 else { return }
        let L = tapCount
        var frames = 0
        var hasRef = false

        if nbuf >= 2 {
            // Planar: one channel per buffer; first = mic, last = reference.
            guard let mp = abl[0].mData, let rp = abl[nbuf - 1].mData else { return }
            let mf = mp.assumingMemoryBound(to: Float.self)
            let rf = rp.assumingMemoryBound(to: Float.self)
            frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0, frames <= maxBlock else { return }
            for i in 0..<frames {
                micScratch[i] = mf[i]
                refBuf[L - 1 + i] = rf[i]
            }
            hasRef = true
        } else {
            // Interleaved single buffer: [mic, ..., reference] per frame.
            guard let p = abl[0].mData else { return }
            let ch = Int(abl[0].mNumberChannels)
            guard ch >= 1 else { return }
            let fp = p.assumingMemoryBound(to: Float.self)
            frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size / ch
            guard frames > 0, frames <= maxBlock else { return }
            let refCh = ch - 1
            hasRef = ch >= 2
            for i in 0..<frames {
                micScratch[i] = fp[i * ch]
                refBuf[L - 1 + i] = hasRef ? fp[i * ch + refCh] : 0
            }
        }

        refBuf.withUnsafeBufferPointer { rb in
            w.withUnsafeMutableBufferPointer { wp in
                let rbase = rb.baseAddress!
                let wbase = wp.baseAddress!
                for i in 0..<frames {
                    let win = rbase + i               // contiguous window refBuf[i ..< i+L]
                    var yhat: Float = 0
                    vDSP_dotpr(wbase, 1, win, 1, &yhat, vDSP_Length(L))
                    let err = micScratch[i] - yhat
                    cleaned[i] = err
                    if hasRef {
                        var energy: Float = 0
                        vDSP_svesq(win, 1, &energy, vDSP_Length(L))
                        var factor = mu * err / (energy + eps)
                        vDSP_vsma(win, 1, &factor, wbase, 1, wbase, 1, vDSP_Length(L))
                    }
                    sumMicSq += Double(micScratch[i] * micScratch[i])
                    sumResSq += Double(err * err)
                }
            }
        }

        // Carry the last (L-1) reference samples for the next block's window.
        // Forward copy is safe: every source index (frames+i) is written later than
        // its destination (i), so reads always see the original sample.
        if L >= 2 {
            for i in 0..<(L - 1) { refBuf[i] = refBuf[frames + i] }
        }

        framesSeen += frames
        if let cb = onCleanedAudio { cb(Array(cleaned[0..<frames]), sampleRate) }
        logERLEIfDue()
    }

    private func logERLEIfDue() {
        guard sampleRate > 0 else { return }
        let interval = Int(sampleRate)   // ~1s
        guard framesSeen - lastLogFrames >= interval else { return }
        lastLogFrames = framesSeen
        let erle = sumResSq > 0 ? 10 * log10(sumMicSq / sumResSq) : 99
        let micRMS = framesSeen > 0 ? (sumMicSq / Double(framesSeen)).squareRoot() : 0
        let resRMS = framesSeen > 0 ? (sumResSq / Double(framesSeen)).squareRoot() : 0
        NSLog(String(format: "SonarDictate: AEC ERLE=%.1f dB  micRMS=%.4f  residualRMS=%.4f", erle, micRMS, resRMS))
    }

    // MARK: - helpers

    private static func ck(_ e: OSStatus, _ what: String) throws {
        if e != noErr { throw AECEngineError.os(e, what) }
    }

    private static func defaultInputUID() -> String? {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        var usz = UInt32(MemoryLayout<CFString?>.size)
        var ua = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                            mScope: kAudioObjectPropertyScopeGlobal,
                                            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(dev, &ua, 0, nil, &usz, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private static func streamSampleRate(_ agg: AudioObjectID) -> Double {
        var fmt = AudioStreamBasicDescription()
        var fsz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                                            mScope: kAudioObjectPropertyScopeInput,
                                            mElement: 0)
        AudioObjectGetPropertyData(agg, &fa, 0, nil, &fsz, &fmt)
        return fmt.mSampleRate
    }

    // Translate our own pid to its CoreAudio process object so the tap can exclude
    // it. Best-effort: [] if the translate fails (then we tap everything).
    private static func selfProcessObjects() -> [AudioObjectID] {
        var pid = getpid()
        var obj = AudioObjectID(kAudioObjectUnknown)
        var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a,
                                            UInt32(MemoryLayout<pid_t>.size), &pid, &sz, &obj)
        return (st == noErr && obj != kAudioObjectUnknown) ? [obj] : []
    }
}
