import Foundation
import QuartzCore

// Thread-safe signal bus between the capture pipeline and the floating widget's
// LED view. Three INDEPENDENT signals drive the visualization:
//
//   energy     - per-buffer audio level (RMS). Bar height + motion.
//   confidence - recognizer certainty (0..1). Block integrity (flicker/missing/
//                saturation). NOT motion - decoupled from energy on purpose.
//   snap       - a finalization pulse: a segment just locked to final.
//
// Writers: the realtime audio thread (publishEnergy) and the speech results
// callback (publishConfidence/snap). Reader: the widget's main-thread display
// timer (snapshot). All access is guarded by one NSLock; critical sections are a
// single scalar store/read so the audio thread never blocks meaningfully.
//
// Timestamps are absolute CACurrentMediaTime() values; the view computes elapsed
// deltas at draw time so an idle tick never sees a stale "just snapped" state.
final class WidgetSignals {
    static let shared = WidgetSignals()

    struct Snapshot {
        var energy: Float          // raw RMS, ~0..0.4 typical; the view applies gain/curve
        var confidence: Float      // 0..1
        var listening: Bool
        var lastSnapAt: CFTimeInterval     // 0 if never
        var releaseAt: CFTimeInterval      // 0 while listening; set on setListening(false)
        var releaseConfidence: Float       // confidence captured at the moment of release
        var lastResultAt: CFTimeInterval   // last time the recognizer produced ANY result
    }

    private let lock = NSLock()
    private var energy: Float = 0
    private var confidence: Float = 1      // start certain so the mic reads solid, not hesitant
    private var listening = false
    private var lastSnapAt: CFTimeInterval = 0
    private var releaseAt: CFTimeInterval = 0
    private var releaseConfidence: Float = 1
    private var lastResultAt: CFTimeInterval = 0

    private init() {}

    // Realtime audio thread. MUST stay lock-free: a realtime thread blocking on a
    // lock held by the 120x/sec main-thread LED reader can stall audio capture and
    // drop buffers. A single Float store/load needs no lock here - a one-frame-stale
    // value is imperceptible for a UI level, and energy is never read under the lock.
    func publishEnergy(_ rms: Float) {
        energy = rms.isFinite ? max(0, rms) : 0
    }

    // Speech results callback. Clamp to 0..1.
    func publishConfidence(_ c: Float) {
        let v = c.isFinite ? min(1, max(0, c)) : confidence
        lock.lock(); confidence = v; lock.unlock()
    }

    // A segment just finalized - the "it stuck" pulse.
    func snap() {
        let now = CACurrentMediaTime()
        lock.lock(); lastSnapAt = now; lock.unlock()
    }

    // The recognizer produced ANY result (volatile or final). Drives the
    // starvation check: talking with no recent activity = the recognizer is
    // failing, even though no low-confidence result ever arrives to show it.
    func noteActivity() {
        let now = CACurrentMediaTime()
        lock.lock(); lastResultAt = now; lock.unlock()
    }

    // Listening edges. On start: arm (energy 0, confident, clear release/snap).
    // On stop: stamp the release and capture confidence so the view can choose a
    // white lock (high confidence) vs a hesitant gray power-down (low confidence).
    func setListening(_ on: Bool) {
        let now = CACurrentMediaTime()
        if on { energy = 0 }   // lock-free field (see publishEnergy)
        lock.lock()
        if on {
            listening = true
            confidence = 1
            lastSnapAt = 0
            releaseAt = 0
            releaseConfidence = 1
            lastResultAt = now   // baseline: starvation is measured from session start
        } else {
            listening = false
            releaseAt = now
            releaseConfidence = confidence
        }
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        let e = energy   // lock-free read (see publishEnergy)
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            energy: e,
            confidence: confidence,
            listening: listening,
            lastSnapAt: lastSnapAt,
            releaseAt: releaseAt,
            releaseConfidence: releaseConfidence,
            lastResultAt: lastResultAt
        )
    }
}
