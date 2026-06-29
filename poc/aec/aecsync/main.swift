import CoreAudio
import AVFoundation
import Foundation

func fourcc(_ e: OSStatus) -> String { var b = e.bigEndian; let by = withUnsafeBytes(of: &b){Array($0)}; return by.allSatisfy{$0>=32 && $0<127} ? "'"+String(by.map{Character(UnicodeScalar($0))})+"'" : "\(e)" }
@discardableResult func chk(_ e: OSStatus, _ w: String) -> Bool { print("  [\(w)] " + (e==noErr ? "ok" : "FAIL \(fourcc(e))")); return e==noErr }

func defaultInputUID() -> String? {
    var dev = AudioObjectID(kAudioObjectUnknown); var sz = UInt32(MemoryLayout<AudioObjectID>.size)
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev) == noErr else { return nil }
    var uid: Unmanaged<CFString>? = nil; var usz = UInt32(MemoryLayout<CFString?>.size)
    var ua = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(dev, &ua, 0, nil, &usz, &uid) == noErr else { return nil }
    return uid?.takeRetainedValue() as String?
}

guard let micUID = defaultInputUID() else { print("no default input"); exit(1) }
print("  mic UID=\(micUID)")

let tap = CATapDescription(monoGlobalTapButExcludeProcesses: [])
tap.isPrivate = true; tap.muteBehavior = .unmuted; tap.name = "aecref"
var tapID = AudioObjectID(kAudioObjectUnknown)
guard chk(AudioHardwareCreateProcessTap(tap, &tapID), "createTap"), tapID != kAudioObjectUnknown else { exit(1) }

let desc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "AECSync",
    kAudioAggregateDeviceUIDKey: "com.sonarmd.aecsync.\(getpid())",
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceMainSubDeviceKey: micUID,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: micUID]],
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString]],
]
var agg = AudioObjectID(kAudioObjectUnknown)
guard chk(AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg), "createAggregate"), agg != kAudioObjectUnknown else { exit(1) }

// total input channels on the aggregate
var fmt = AudioStreamBasicDescription(); var fsz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
var fa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat, mScope: kAudioObjectPropertyScopeInput, mElement: 0)
AudioObjectGetPropertyData(agg, &fa, 0, nil, &fsz, &fmt)
print("  aggregate input: \(fmt.mChannelsPerFrame)ch @ \(Int(fmt.mSampleRate))Hz (mic channels first, then tap/reference)")

let nch = Int(fmt.mChannelsPerFrame)
final class Acc { var sq: [Double]; var n: Int = 0; init(_ c: Int){ sq = Array(repeating: 0, count: c) } }
let acc = Acc(max(nch,1))
var proc: AudioDeviceIOProcID?
let st = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, inData, _, _, _ in
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    for buf in abl {
        guard let p = buf.mData else { continue }
        let ch = Int(buf.mNumberChannels); let total = Int(buf.mDataByteSize)/MemoryLayout<Float>.size
        let fp = p.assumingMemoryBound(to: Float.self); let frames = ch>0 ? total/ch : 0
        for f in 0..<frames { for c in 0..<ch { let s = fp[f*ch+c]; if c < acc.sq.count { acc.sq[c] += Double(s*s) } } }
        acc.n += frames
    }
}
guard chk(st, "createIOProc") else { exit(1) }
chk(AudioDeviceStart(agg, proc), "start")
print("  capturing 4s - TALK while music plays...")
Thread.sleep(forTimeInterval: 4.0)
chk(AudioDeviceStop(agg, proc), "stop")
print("  per-channel RMS over \(acc.n) frames:")
for (c, s) in acc.sq.enumerated() { let r = acc.n>0 ? (s/Double(acc.n)).squareRoot() : 0; print(String(format: "    ch%d RMS=%.5f", c, r)) }
if let proc { AudioDeviceDestroyIOProcID(agg, proc) }
AudioHardwareDestroyAggregateDevice(agg); AudioHardwareDestroyProcessTap(tapID)
