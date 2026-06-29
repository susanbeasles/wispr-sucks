import Accelerate
import AVFoundation
import Foundation

// Streaming counterpart of HarmonicVoiceIsolator: keeps STFT overlap-add state
// across the live mic buffers so the harmonic mask runs continuously, with no
// per-buffer edge artifacts. Emits each sample only once all overlapping frames
// that cover it have been processed (latency ~one FFT window). Voiced frames get
// the F0 harmonic mask; unvoiced frames use an all-ones mask (clean reconstruction)
// so consonants and continuity are preserved.
//
// Tier 1b of .agent/plans/2026-06-29-105844-native-voice-isolation.md. Reuses the
// fftSize/hop/Params of the validated batch core. Behind IRIS_HARMONIC_ISO at the
// seam, default OFF.

@available(macOS 14.0, *)
final class StreamingHarmonicIsolator {
    private let N = HarmonicVoiceIsolator.fftSize
    private let H = HarmonicVoiceIsolator.hop
    private let sr: Float
    private let params: HarmonicVoiceIsolator.Params
    private let fwd: vDSP.DFT<Float>
    private let inv: vDSP.DFT<Float>
    private var hann: [Float]

    // Harmonic gain mask, rebuilt only when F0 changes meaningfully.
    private var gain: [Float]
    private var gainF0: Float = -1

    // Input ring (absolute sample indexing): inBuf[i] is absolute index inBase + i.
    private var inBuf: [Float] = []
    private var inBase = 0
    private var nextFrame = 0

    // Output overlap-add accumulator (absolute indexing): out[i] is outBase + i.
    private var out: [Float] = []
    private var norm: [Float] = []
    private var outBase = 0
    private var emitted = 0

    // Frame scratch (reused).
    private var inRe: [Float]
    private let inIm: [Float]
    private var re: [Float]
    private var im: [Float]
    private var oRe: [Float]
    private var oIm: [Float]

    init?(sampleRate: Float, params: HarmonicVoiceIsolator.Params = .init()) {
        guard let f = vDSP.DFT(count: HarmonicVoiceIsolator.fftSize, direction: .forward, transformType: .complexComplex, ofType: Float.self),
              let i = vDSP.DFT(count: HarmonicVoiceIsolator.fftSize, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
        else { return nil }
        self.fwd = f
        self.inv = i
        self.sr = sampleRate
        self.params = params
        let n = HarmonicVoiceIsolator.fftSize
        var h = [Float](repeating: 0, count: n)
        vDSP_hann_window(&h, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        self.hann = h
        self.gain = [Float](repeating: 1, count: n)
        self.inRe = [Float](repeating: 0, count: n)
        self.inIm = [Float](repeating: 0, count: n)
        self.re = [Float](repeating: 0, count: n)
        self.im = [Float](repeating: 0, count: n)
        self.oRe = [Float](repeating: 0, count: n)
        self.oIm = [Float](repeating: 0, count: n)
    }

    private func buildGain(f0: Float) {
        // All-ones (identity / passthrough) when unvoiced; harmonic mask when voiced.
        if f0 <= 0 {
            for b in 0..<N { gain[b] = 1 }
            gainF0 = 0
            return
        }
        for b in 0..<N { gain[b] = params.floorGain }
        let half = N / 2
        let f0Bin = f0 / (sr / Float(N))
        var k = 1
        while k <= params.harmonics {
            let center = Float(k) * f0Bin
            if center > Float(half) { break }
            let lo = max(1, Int((center - params.binTolerance).rounded(.down)))
            let hi = min(half, Int((center + params.binTolerance).rounded(.up)))
            if lo <= hi {
                for b in lo...hi { gain[b] = 1; if b < half { gain[N - b] = 1 } }
            }
            k += 1
        }
        gain[0] = params.floorGain
        gainF0 = f0
    }

    // Feed samples (with the current F0 estimate); returns the samples now finalized.
    func process(_ x: [Float], f0: Float) -> [Float] {
        if abs(f0 - gainF0) > 0.5 { buildGain(f0: f0) }
        inBuf.append(contentsOf: x)
        return drain(flush: false)
    }

    // Drain remaining samples at end of stream (zero-pads the final partial frame).
    func flush() -> [Float] {
        let inEnd = inBase + inBuf.count
        while nextFrame + N > inBase + inBuf.count && inBase + inBuf.count < nextFrame + N {
            inBuf.append(0)
        }
        let tail = drain(flush: true)
        // Emit anything still pending up to the real input end.
        let ready = emitUpTo(min(inEnd, outBase + out.count))
        return tail + ready
    }

    private func drain(flush: Bool) -> [Float] {
        let inEnd = inBase + inBuf.count
        while nextFrame + N <= inEnd {
            processFrame(at: nextFrame)
            nextFrame += H
        }
        // Samples below nextFrame are final (no future frame covers them).
        let ready = emitUpTo(nextFrame)
        compact()
        return ready
    }

    private func processFrame(at s: Int) {
        let off = s - inBase
        for i in 0..<N { inRe[i] = inBuf[off + i] * hann[i] }
        fwd.transform(inputReal: inRe, inputImaginary: inIm, outputReal: &re, outputImaginary: &im)
        for b in 0..<N { re[b] *= gain[b]; im[b] *= gain[b] }
        inv.transform(inputReal: re, inputImaginary: im, outputReal: &oRe, outputImaginary: &oIm)
        // Ensure the OLA accumulator covers [s, s+N).
        let need = (s + N) - (outBase + out.count)
        if need > 0 {
            out.append(contentsOf: repeatElement(0, count: need))
            norm.append(contentsOf: repeatElement(0, count: need))
        }
        let scale = 1 / Float(N)
        let base = s - outBase
        for i in 0..<N {
            out[base + i] += oRe[i] * scale * hann[i]
            norm[base + i] += hann[i] * hann[i]
        }
    }

    private func emitUpTo(_ absEnd: Int) -> [Float] {
        guard absEnd > emitted else { return [] }
        var ready = [Float](repeating: 0, count: absEnd - emitted)
        for j in emitted..<absEnd {
            let k = j - outBase
            ready[j - emitted] = norm[k] > 1e-6 ? out[k] / norm[k] : 0
        }
        emitted = absEnd
        return ready
    }

    private func compact() {
        // Drop consumed input (everything before the next frame start).
        if nextFrame > inBase {
            inBuf.removeFirst(nextFrame - inBase)
            inBase = nextFrame
        }
        // Drop emitted output.
        if emitted > outBase {
            let d = emitted - outBase
            out.removeFirst(d)
            norm.removeFirst(d)
            outBase = emitted
        }
    }
}
