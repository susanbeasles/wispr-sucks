import CoreAudio
import AVFoundation
import Foundation

func fourcc(_ err: OSStatus) -> String {
    var be = err.bigEndian
    let bytes = withUnsafeBytes(of: &be) { Array($0) }
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return "'" + String(bytes.map { Character(UnicodeScalar($0)) }) + "'" }
    return "\(err)"
}
@discardableResult func chk(_ err: OSStatus, _ what: String) -> Bool {
    print("  [\(what)] " + (err == noErr ? "ok" : "FAILED \(fourcc(err))"))
    return err == noErr
}

let tap = CATapDescription(monoGlobalTapButExcludeProcesses: [])
tap.isPrivate = true
tap.muteBehavior = .unmuted
tap.name = "aectest"

var tapID = AudioObjectID(kAudioObjectUnknown)
guard chk(AudioHardwareCreateProcessTap(tap, &tapID), "createProcessTap"), tapID != kAudioObjectUnknown else {
    print("=> tap creation blocked - likely needs audio-capture TCC/entitlement"); exit(1)
}
print("  tapID=\(tapID) uuid=\(tap.uuid.uuidString)")

let aggUID = "com.sonarmd.aectest.\(getpid())"
let desc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "AECTestAgg",
    kAudioAggregateDeviceUIDKey: aggUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString]],
]
var aggID = AudioObjectID(kAudioObjectUnknown)
guard chk(AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID), "createAggregate"), aggID != kAudioObjectUnknown else { exit(1) }

final class Acc { var sumSq = 0.0; var n = 0; var peak: Float = 0 }
let acc = Acc()
var procID: AudioDeviceIOProcID?
let st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, _, _ in
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    for buf in abl {
        guard let p = buf.mData else { continue }
        let cnt = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
        let fp = p.assumingMemoryBound(to: Float.self)
        for i in 0..<cnt { let s = fp[i]; acc.sumSq += Double(s*s); acc.n += 1; if abs(s) > acc.peak { acc.peak = abs(s) } }
    }
}
guard chk(st, "createIOProc") else { exit(1) }
chk(AudioDeviceStart(aggID, procID), "start")
print("  capturing 3s of system audio (play music now)...")
Thread.sleep(forTimeInterval: 3.0)
chk(AudioDeviceStop(aggID, procID), "stop")
let rms = acc.n > 0 ? (acc.sumSq / Double(acc.n)).squareRoot() : 0
print(String(format: "  frames=%d RMS=%.5f peak=%.5f", acc.n, rms, acc.peak))
print(rms > 0.0002 ? "=> REFERENCE CAPTURE WORKS - we have the system audio reference" : "=> captured but near-silent (nothing playing or tap muted)")
if let procID { AudioDeviceDestroyIOProcID(aggID, procID) }
AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)
