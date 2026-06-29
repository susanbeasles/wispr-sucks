import CoreAudio
import AVFoundation
import Foundation
func fourcc(_ e: OSStatus) -> String { var b = e.bigEndian; let by = withUnsafeBytes(of: &b){Array($0)}; return by.allSatisfy{$0>=32 && $0<127} ? "'"+String(by.map{Character(UnicodeScalar($0))})+"'" : "\(e)" }
@discardableResult func chk(_ e: OSStatus, _ w: String) -> Bool { print("  [\(w)] " + (e==noErr ? "ok" : "FAIL \(fourcc(e))")); return e==noErr }
func defIn() -> String? { var d = AudioObjectID(kAudioObjectUnknown); var s = UInt32(MemoryLayout<AudioObjectID>.size); var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain); guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &d)==noErr else {return nil}; var u: Unmanaged<CFString>?=nil; var us=UInt32(MemoryLayout<CFString?>.size); var ua=AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain); guard AudioObjectGetPropertyData(d,&ua,0,nil,&us,&u)==noErr else {return nil}; return u?.takeRetainedValue() as String? }
guard let mic = defIn() else { exit(1) }
let tap = CATapDescription(monoGlobalTapButExcludeProcesses: []); tap.isPrivate=true; tap.muteBehavior = .unmuted; tap.name="ref"
var tapID = AudioObjectID(kAudioObjectUnknown); guard chk(AudioHardwareCreateProcessTap(tap,&tapID),"tap") else {exit(1)}
let desc: [String:Any] = [kAudioAggregateDeviceNameKey:"AECSync2", kAudioAggregateDeviceUIDKey:"com.sonarmd.aecsync2.\(getpid())", kAudioAggregateDeviceIsPrivateKey:true, kAudioAggregateDeviceMainSubDeviceKey:mic, kAudioAggregateDeviceSubDeviceListKey:[[kAudioSubDeviceUIDKey:mic]], kAudioAggregateDeviceTapListKey:[[kAudioSubTapUIDKey:tap.uuid.uuidString]]]
var agg = AudioObjectID(kAudioObjectUnknown); guard chk(AudioHardwareCreateAggregateDevice(desc as CFDictionary,&agg),"agg") else {exit(1)}
final class Acc { var sq:[String:Double]=[:]; var n:[String:Int]=[:] }
let acc = Acc()
var proc: AudioDeviceIOProcID?
let st = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, inData, _, _, _ in
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    for (bi, buf) in abl.enumerated() {
        guard let p = buf.mData else { continue }
        let ch = Int(buf.mNumberChannels); let tot = Int(buf.mDataByteSize)/MemoryLayout<Float>.size; let fp = p.assumingMemoryBound(to: Float.self); let frames = ch>0 ? tot/ch : 0
        for c in 0..<ch { let k = "stream\(bi).ch\(c)"; var s = 0.0; for f in 0..<frames { let v = fp[f*ch+c]; s += Double(v*v) }; acc.sq[k, default:0] += s; acc.n[k, default:0] += frames }
    }
}
guard chk(st,"ioproc") else {exit(1)}
chk(AudioDeviceStart(agg,proc),"start"); print("  4s - TALK over your music..."); Thread.sleep(forTimeInterval:4.0); chk(AudioDeviceStop(agg,proc),"stop")
print("  stream0 = mic (your voice), last stream = tap (the music reference):")
for k in acc.sq.keys.sorted() { let r = acc.n[k]! > 0 ? (acc.sq[k]!/Double(acc.n[k]!)).squareRoot() : 0; print(String(format:"    %@  RMS=%.5f", k, r)) }
if let proc { AudioDeviceDestroyIOProcID(agg,proc) }; AudioHardwareDestroyAggregateDevice(agg); AudioHardwareDestroyProcessTap(tapID)
