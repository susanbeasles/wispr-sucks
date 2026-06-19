import Foundation
import QuartzCore

// Thread-safe bus between the eye loop (writer) and any consumer (the caption
// overlay now; the agent later). Mirrors WidgetSignals: one NSLock, scalar
// state, an optional main-thread observer.
//
// Phase 1 surfaces the latest situational summary + a short status line. The
// "decide during build" consumption seam lands here: this in-memory bus is the
// most PHI-safe option (nothing persisted), and a durable encrypted sink can be
// added behind publishSummary later without changing the writer.
final class EyeSignals {
    static let shared = EyeSignals()

    struct Snapshot {
        var watching: Bool
        var summary: String          // unused in silent mode (kept for the caption render)
        var status: String           // short NON-narrative line: "watching - N remembered", a permission hint
        var latestObservation: String  // current on-screen text (for conversation context; never narrated)
        var lastUpdateAt: CFTimeInterval
    }

    private let lock = NSLock()
    private var watching = false
    private var summary = ""
    private var status = "idle"
    private var latestObservation = ""
    private var lastUpdateAt: CFTimeInterval = 0

    private init() {}

    // The current on-screen text - kept so the chat can answer "what do you see"
    // WITHOUT it ever being narrated in the caption. Not displayed.
    func setLatestObservation(_ text: String) {
        lock.lock(); latestObservation = text; lock.unlock()
    }

    // She just filed a memory. Update the quiet status (a count, not content).
    func noteRemembered(_ count: Int) {
        let now = CACurrentMediaTime()
        lock.lock(); status = "watching - \(count) remembered"; lastUpdateAt = now; lock.unlock()
        emit()
    }

    // Set by a consumer (the caption overlay) to receive updates on the main thread.
    var onUpdate: ((Snapshot) -> Void)?

    func setWatching(_ on: Bool) {
        lock.lock()
        watching = on
        status = on ? "watching..." : "idle"
        if !on { summary = "" }
        lock.unlock()
        emit()
    }

    func publishSummary(_ text: String) {
        let now = CACurrentMediaTime()
        lock.lock()
        summary = text
        status = "watching..."
        lastUpdateAt = now
        lock.unlock()
        emit()
    }

    func publishStatus(_ line: String) {
        lock.lock(); status = line; lock.unlock()
        emit()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(watching: watching, summary: summary, status: status,
                        latestObservation: latestObservation, lastUpdateAt: lastUpdateAt)
    }

    private func emit() {
        let snap = snapshot()
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(snap) }
    }
}
