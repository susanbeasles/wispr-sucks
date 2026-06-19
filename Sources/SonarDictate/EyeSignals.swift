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
        var summary: String          // latest situational read (may be PHI; never persisted here)
        var status: String           // short line: "idle", "watching", a permission hint, an error
        var lastUpdateAt: CFTimeInterval
    }

    private let lock = NSLock()
    private var watching = false
    private var summary = ""
    private var status = "idle"
    private var lastUpdateAt: CFTimeInterval = 0

    private init() {}

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
        return Snapshot(watching: watching, summary: summary, status: status, lastUpdateAt: lastUpdateAt)
    }

    private func emit() {
        let snap = snapshot()
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(snap) }
    }
}
