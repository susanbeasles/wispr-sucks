import Foundation
import Accelerate
var seed: UInt64 = 0x2545F4914F6CDD1D
func rnd() -> Float { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return Float(Int32(truncatingIfNeeded: seed))/Float(Int32.max) }
let sr = 16000, N = 16000*5
var x = [Float](repeating:0,count:N)
for n in 0..<N { let t=Float(n)/Float(sr); x[n]=0.35*sinf(2 * .pi*220*t)+0.25*sinf(2 * .pi*440*t)+0.18*sinf(2 * .pi*660*t)+0.15*rnd() }
var lp:Float=0; for n in 0..<N { lp=0.85*lp+0.15*x[n]; x[n]=lp }

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
    let din=ss(d[L..<N]), eout=ss(e[L..<N])
    print(String(format:"  %@: delay=%dms filterLen=%dms -> ERLE %.1f dB", label, delay*1000/sr, L*1000/sr, 10*log10(din/eout)))
}
print("Our canceller vs echo latency:")
runAEC(delay: 40,   L: 1024, label: "built-in speaker (~2.5ms)   ")
runAEC(delay: 3200, L: 1024, label: "BLUETOOTH, filter too short ")
runAEC(delay: 3200, L: 4096, label: "BLUETOOTH, filter sized right")
