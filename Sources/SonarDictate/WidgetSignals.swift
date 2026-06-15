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
    }

    private let lock = NSLock()
    private var energy: Float = 0
    private var confidence: Float = 1      // start certain so the mic reads solid, not hesitant
    private var listening = false
    private var lastSnapAt: CFTimeInterval = 0
    private var releaseAt: CFTimeInterval = 0
    private var releaseConfidence: Float = 1

    private init() {}

    // Realtime audio thread. Single store; never allocates.
    func publishEnergy(_ rms: Float) {
        let v = rms.isFinite ? max(0, rms) : 0
        lock.lock(); energy = v; lock.unlock()
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

    // Listening edges. On start: arm (energy 0, confident, clear release/snap).
    // On stop: stamp the release and capture confidence so the view can choose a
    // white lock (high confidence) vs a hesitant gray power-down (low confidence).
    func setListening(_ on: Bool) {
        let now = CACurrentMediaTime()
        lock.lock()
        if on {
            listening = true
            energy = 0
            confidence = 1
            lastSnapAt = 0
            releaseAt = 0
            releaseConfidence = 1
        } else {
            listening = false
            releaseAt = now
            releaseConfidence = confidence
        }
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            energy: energy,
            confidence: confidence,
            listening: listening,
            lastSnapAt: lastSnapAt,
            releaseAt: releaseAt,
            releaseConfidence: releaseConfidence
        )
    }
}
