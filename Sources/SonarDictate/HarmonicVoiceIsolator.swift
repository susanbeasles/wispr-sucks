import Accelerate
import Foundation

// Native, single-mic harmonic voice isolation. No system audio, NO system-audio
// grant: keep the spectral energy on the harmonics of the speaker's tracked pitch
// (F0) and attenuate the inharmonic rest (music/noise) to a soft floor. Unvoiced
// frames (f0 <= 0) pass through UNCHANGED so consonants survive.
//
// STFT with 75% Hann overlap-add (vDSP.DFT). This is the OFFLINE-validated core: a
// pure function over a sample array, with no realtime or sealed-path risk. The
// streaming wrapper + sealed-seam wiring come AFTER `isotest` proves the suppression
// numbers. Tier 1a of .agent/plans/2026-06-29-105844-native-voice-isolation.md.

enum HarmonicVoiceIsolator {
    static let fftSize = 1024
    static let hop = 256   // 75% overlap

    struct Params {
        var harmonics = 30
        var binTolerance: Float = 1.0   // keep bins within +/- this many bins of a harmonic
        var floorGain: Float = 0.1      // attenuation (not 0) for inharmonic bins: limits musical noise
    }

    // Isolate the voice in `samples` given a (roughly constant) F0 in Hz. Returns a
    // same-length array. f0 <= 0 or too-short input -> returns the input unchanged.
    static func isolate(_ samples: [Float], sampleRate: Float, f0: Float, params: Params = Params()) -> [Float] {
        let N = fftSize
        guard f0 > 0, samples.count >= N,
              let fwd = vDSP.DFT(count: N, direction: .forward, transformType: .complexComplex, ofType: Float.self),
              let inv = vDSP.DFT(count: N, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
        else { return samples }

        let n = samples.count
        let H = hop
        let half = N / 2

        var hann = [Float](repeating: 0, count: N)
        vDSP_hann_window(&hann, vDSP_Length(N), Int32(vDSP_HANN_DENORM))

        // Per-bin harmonic gain mask for this F0 (conjugate-symmetric, so the inverse
        // transform stays real).
        let binHz = sampleRate / Float(N)
        let f0Bin = f0 / binHz
        var gain = [Float](repeating: params.floorGain, count: N)
        var k = 1
        while k <= params.harmonics {
            let center = Float(k) * f0Bin
            if center > Float(half) { break }
            let lo = max(1, Int((center - params.binTolerance).rounded(.down)))
            let hi = min(half, Int((center + params.binTolerance).rounded(.up)))
            if lo <= hi {
                for b in lo...hi {
                    gain[b] = 1
                    if b < half { gain[N - b] = 1 }   // mirror to the negative frequency
                }
            }
            k += 1
        }
        gain[0] = params.floorGain   // suppress DC

        var out = [Float](repeating: 0, count: n)
        var norm = [Float](repeating: 0, count: n)
        var inRe = [Float](repeating: 0, count: N)
        let inIm = [Float](repeating: 0, count: N)
        var re = [Float](repeating: 0, count: N)
        var im = [Float](repeating: 0, count: N)
        var oRe = [Float](repeating: 0, count: N)
        var oIm = [Float](repeating: 0, count: N)
        let scale = 1 / Float(N)

        var pos = 0
        while pos + N <= n {
            for i in 0..<N { inRe[i] = samples[pos + i] * hann[i] }
            fwd.transform(inputReal: inRe, inputImaginary: inIm, outputReal: &re, outputImaginary: &im)
            for b in 0..<N { re[b] *= gain[b]; im[b] *= gain[b] }
            inv.transform(inputReal: re, inputImaginary: im, outputReal: &oRe, outputImaginary: &oIm)
            for i in 0..<N {
                let v = oRe[i] * scale * hann[i]   // synthesis window for overlap-add
                out[pos + i] += v
                norm[pos + i] += hann[i] * hann[i]
            }
            pos += H
        }

        // Normalize the overlap-add; any tail shorter than one frame keeps the input.
        for i in 0..<n {
            if norm[i] > 1e-6 { out[i] /= norm[i] } else { out[i] = samples[i] }
        }
        return out
    }

    // MARK: - offline self-test (no audio device, no grant)

    // Synthesize voice (harmonics of f0) + inharmonic music (tones unrelated to f0
    // plus broadband noise) for the self-tests.
    static func synth(sampleRate: Float, f0: Float) -> (voice: [Float], music: [Float]) {
        let n = Int(sampleRate) * 3
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> Float { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return Float(Int32(truncatingIfNeeded: seed)) / Float(Int32.max) }
        var voice = [Float](repeating: 0, count: n)
        var music = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Float(i) / sampleRate
            var v: Float = 0
            var h = 1
            while h <= 20 { v += (1 / Float(h)) * sinf(2 * .pi * f0 * Float(h) * t); h += 1 }
            voice[i] = 0.3 * v
            music[i] = 0.4 * sinf(2 * .pi * 523 * t) + 0.3 * sinf(2 * .pi * 784 * t)
                     + 0.2 * sinf(2 * .pi * 1175 * t) + 0.15 * rnd()
        }
        return (voice, music)
    }

    // Energy over the steady-state interior only: the first/last frame of an
    // overlap-add has partial window coverage and is not representative.
    private static func interiorEnergy(_ a: [Float]) -> Double {
        let lo = min(fftSize, a.count), hi = max(lo, a.count - fftSize)
        guard hi > lo else { return 0 }
        var s: Float = 0
        a.withUnsafeBufferPointer { p in vDSP_svesq(p.baseAddress! + lo, 1, &s, vDSP_Length(hi - lo)) }
        return Double(s)
    }

    // Batch core: attenuate music-only vs preserve voice-only. (suppressionDb, retentionDb)
    static func selfTest(sampleRate: Float = 16000, f0: Float = 140) -> (musicSuppressionDb: Double, voiceRetentionDb: Double) {
        let (voice, music) = synth(sampleRate: sampleRate, f0: f0)
        let yMusic = isolate(music, sampleRate: sampleRate, f0: f0)
        let yVoice = isolate(voice, sampleRate: sampleRate, f0: f0)
        let supp = 10 * log10(interiorEnergy(music) / max(interiorEnergy(yMusic), 1e-12))
        let ret = 10 * log10(max(interiorEnergy(yVoice), 1e-12) / max(interiorEnergy(voice), 1e-12))
        return (supp, ret)
    }

    // Streaming path: feed the same signals through StreamingHarmonicIsolator in
    // odd-sized chunks (like live mic buffers) and confirm it matches the batch core.
    @available(macOS 14.0, *)
    static func selfTestStreaming(sampleRate: Float = 16000, f0: Float = 140) -> (musicSuppressionDb: Double, voiceRetentionDb: Double) {
        let (voice, music) = synth(sampleRate: sampleRate, f0: f0)
        func run(_ x: [Float]) -> [Float] {
            guard let s = StreamingHarmonicIsolator(sampleRate: sampleRate) else { return x }
            var y: [Float] = []
            let sizes = [1024, 777, 2048, 333, 1500]
            var i = 0, k = 0
            while i < x.count {
                let m = min(sizes[k % sizes.count], x.count - i)
                y.append(contentsOf: s.process(Array(x[i..<i + m]), f0: f0))
                i += m; k += 1
            }
            y.append(contentsOf: s.flush())
            return y
        }
        let yMusic = run(music)
        let yVoice = run(voice)
        let supp = 10 * log10(interiorEnergy(music) / max(interiorEnergy(yMusic), 1e-12))
        let ret = 10 * log10(max(interiorEnergy(yVoice), 1e-12) / max(interiorEnergy(voice), 1e-12))
        return (supp, ret)
    }
}
