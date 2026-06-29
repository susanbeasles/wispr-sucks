import Foundation
import Accelerate
var seed: UInt64 = 0x9E3779B97F4A7C15
func rnd() -> Float { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return Float(Int32(truncatingIfNeeded: seed))/Float(Int32.max) }
let sr = 16000, N = 16000*5
// broadband, music-like: white noise shaped by a couple of resonant filters (decorrelated across long lags)
var x = [Float](repeating:0,count:N)
var b1:Float=0, b2:Float=0
for n in 0..<N { let w = rnd(); b1 = 0.6*b1 + 0.4*w; b2 = 0.92*b2 + 0.08*w; x[n] = 0.6*b1 + 0.5*b2 }
var mx:Float=0; vDSP_maxmgv(x,1,&mx,vDSP_Length(N)); if mx>0 { var g=0.5/mx; vDSP_vsmul(x,1,&g,&x,1,vDSP_Length(N)) }
func runAEC(delay: Int, L: Int, label: String) {
    var h=[Float](repeating:0,count: delay+500)
    h[delay]=0.6; h[delay+25]=0.32; h[delay+70]=0.18; h[delay+140]=0.10; h[delay+260]=0.05; h[delay+450]=0.025
    var d=[Float](repeating:0,count:N)
    for n in 0..<N { var a:Float=0; for k in 0..<h.count where n-k>=0 { a+=h[k]*x[n-k] }; d[n]=a }
    var w=[Float](repeating:0,count:L); let mu:Float=0.5, eps:Float=1e-6; var e=[Float](repeating:0,count:N)
    for n in (L-1)..<N {
        let lo=n-L+1; var yhat:Float=0; var en:Float=0
        w.withUnsafeBufferPointer{wp in x.withUnsafeBufferPointer{xp in let win=xp.baseAddress!+lo; vDSP_dotpr(wp.baseAddress!,1,win,1,&yhat,vDSP_Length(L)); vDSP_svesq(win,1,&en,vDSP_Length(L))}}
        let err=d[n]-yhat; e[n]=err; var f=mu*err/(en+eps)
        w.withUnsafeMutableBufferPointer{wp in x.withUnsafeBufferPointer{xp in vDSP_vsma(xp.baseAddress!+lo,1,&f,wp.baseAddress!,1,wp.baseAddress!,1,vDSP_Length(L))}}
    }
    func ss(_ s:ArraySlice<Float>)->Double{var v:Float=0; s.withUnsafeBufferPointer{vDSP_svesq($0.baseAddress!,1,&v,vDSP_Length($0.count))}; return Double(v)}
    let din=ss(d[(N/2)..<N]), eout=ss(e[(N/2)..<N])   // measure 2nd half (converged)
    print(String(format:"  %@: delay=%3dms filter=%3dms -> ERLE %5.1f dB", label, delay*1000/sr, L*1000/sr, 10*log10(din/eout)))
}
print("Broadband (music-like) reference - the honest test:")
runAEC(delay: 40,   L: 1024, label: "built-in (~2ms), 64ms filter      ")
runAEC(delay: 3200, L: 1024, label: "BLUETOOTH 200ms, 64ms filter (VPIO-ish)")
runAEC(delay: 3200, L: 4096, label: "BLUETOOTH 200ms, 256ms filter (ours)   ")
