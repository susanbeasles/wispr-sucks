import Foundation
import Accelerate

// ---- signal gen (deterministic) ----
var seed: UInt64 = 0x2545F4914F6CDD1D
func rnd() -> Float { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return Float(Int32(truncatingIfNeeded: seed)) / Float(Int32.max) }

let sr = 16000, secs = 4, N = 16000 * 4
// pseudo-music reference: a few tones + noise, lightly lowpassed
var x = [Float](repeating: 0, count: N)
for n in 0..<N {
    let t = Float(n) / Float(sr)
    x[n] = 0.35*sinf(2 * .pi * 220 * t) + 0.25*sinf(2 * .pi * 440 * t) + 0.18*sinf(2 * .pi * 660 * t) + 0.15*rnd()
}
// one-pole lowpass to smear it a bit
var lp: Float = 0; for n in 0..<N { lp = 0.85*lp + 0.15*x[n]; x[n] = lp }

// ---- synthetic "room" echo path (what the speaker+air+room do to the reference) ----
let delay = 40                 // ~2.5ms direct path + output latency
var h = [Float](repeating: 0, count: 600)
h[delay] = 0.60; h[delay+25] = 0.32; h[delay+70] = 0.18; h[delay+140] = 0.10; h[delay+260] = 0.05; h[delay+450] = 0.025
// mic echo d = convolution of reference with the room
var d = [Float](repeating: 0, count: N)
for n in 0..<N { var acc: Float = 0; for k in 0..<h.count where n-k >= 0 { acc += h[k]*x[n-k] }; d[n] = acc }

// ---- NLMS adaptive filter ----
let L = 1024                   // 64ms of taps - longer than the echo, so it can model it
var w = [Float](repeating: 0, count: L)
let mu: Float = 0.5, eps: Float = 1e-6
var e = [Float](repeating: 0, count: N)

func block(_ a: ArraySlice<Float>) -> Double { var s: Float = 0; a.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress!, 1, &s, vDSP_Length($0.count)) }; return Double(s) }

for n in (L-1)..<N {
    let lo = n - L + 1
    var yhat: Float = 0
    var energy: Float = 0
    w.withUnsafeBufferPointer { wp in
        x.withUnsafeBufferPointer { xp in
            let win = xp.baseAddress! + lo
            vDSP_dotpr(wp.baseAddress!, 1, win, 1, &yhat, vDSP_Length(L))
            vDSP_svesq(win, 1, &energy, vDSP_Length(L))
        }
    }
    let err = d[n] - yhat
    e[n] = err
    var factor = mu * err / (energy + eps)
    w.withUnsafeMutableBufferPointer { wp in
        x.withUnsafeBufferPointer { xp in
            vDSP_vsma(xp.baseAddress! + lo, 1, &factor, wp.baseAddress!, 1, wp.baseAddress!, 1, vDSP_Length(L))
        }
    }
}

// ---- ERLE per 0.5s block (convergence) ----
print("ERLE (dB) per 0.5s block - how much music we killed as the filter learns:")
let bs = sr/2
var bn = 0
var stride0 = L
while stride0 + bs <= N {
    let din = block(d[stride0..<stride0+bs]); let eout = block(e[stride0..<stride0+bs])
    let erle = eout > 0 ? 10*log10(din/eout) : 99
    print(String(format: "  block %d (%.1fs): ERLE = %5.1f dB", bn, Double(stride0)/Double(sr), erle))
    stride0 += bs; bn += 1
}
let dT = block(d[L..<N]); let eT = block(e[L..<N])
print(String(format: "OVERALL ERLE = %.1f dB  (mic-music RMS=%.4f -> residual RMS=%.4f)", 10*log10(dT/eT), (dT/Double(N-L)).squareRoot(), (eT/Double(N-L)).squareRoot()))
