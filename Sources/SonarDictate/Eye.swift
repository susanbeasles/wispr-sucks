import AppKit

// The eye loop: a 3s heartbeat that captures the region under the eye frame,
// OCRs it, runs the delta gate, and on a meaningful change asks the reasoner for
// a situational read - published to EyeSignals.
//
// All mutable state (isWatching, busy, lastText) is @MainActor-isolated, so the
// timer tick, the UI reads (overlay frame), and the async result all touch it on
// one thread - no locks, no races. The capture/OCR/reason work runs in awaited
// async/detached calls, so the main thread is never blocked.
//
// Phase 1 delta gate is a cheap text-change ratio. Phase 2 swaps changed() for
// semantic embedding distance (reusing RAGIndex) without touching the loop.
// Note: not @MainActor-annotated so it can be constructed from main.swift's
// non-isolated top-level code, but every method runs on the main thread in
// practice - start/stop/toggle are called from the main-thread menu action, the
// timer is added to RunLoop.main, and the async result hops back via
// `Task { @MainActor in }`. So busy/lastText/isWatching are only ever touched on
// main: no locks, no races.
@available(macOS 26.0, *)
final class Eye {
    private weak var overlay: EyeOverlay?
    private let reasoner = ScreenReasoner()
    private var timer: Timer?
    private(set) var isWatching = false
    private var busy = false
    private var lastText = ""

    private let intervalSec = 3.0
    // Tunable: how much the OCR text must change (0..1) before we re-reason.
    // Suppresses micro-churn (a blinking cursor, a clock tick). Phase 2 replaces
    // this magnitude with a semantic-distance threshold.
    private let deltaThreshold = 0.15

    func attach(overlay: EyeOverlay) { self.overlay = overlay }

    func toggle() { isWatching ? stop() : start() }

    func start() {
        guard !isWatching else { return }
        isWatching = true
        lastText = ""
        EyeSignals.shared.setWatching(true)
        overlay?.showFrame()

        let t = Timer(timeInterval: intervalSec, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()   // first read immediately
    }

    func stop() {
        guard isWatching else { return }
        isWatching = false
        timer?.invalidate()
        timer = nil
        EyeSignals.shared.setWatching(false)
        overlay?.hideFrame()
    }

    private func tick() {
        guard isWatching, !busy else { return }
        guard let region = overlay?.captureRegion(), region.width > 4, region.height > 4 else { return }
        busy = true
        let previous = lastText

        Task { @MainActor in
            defer { self.busy = false }
            do {
                let image = try await EyeCapture.capture(region: region)
                // OCR is synchronous CPU work - run it off the main thread.
                let text = await Task.detached { ScreenText.recognize(image) }.value
                guard self.isWatching else { return }
                guard self.changed(text) else { return }
                self.lastText = text

                let summary = await self.reasoner.summarize(current: text, previous: previous)
                guard self.isWatching, !summary.isEmpty else { return }
                EyeSignals.shared.publishSummary(summary)
            } catch {
                EyeSignals.shared.publishStatus("screen capture blocked - grant Screen Recording in System Settings")
            }
        }
    }

    // Phase 1 delta gate: escalate only when the OCR text changed beyond the
    // threshold. Empty reads never escalate; the first non-empty read always does.
    private func changed(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if lastText.isEmpty { return true }
        return Eye.normalizedDistance(lastText, t) >= deltaThreshold
    }

    // Cheap change magnitude in [0, 1]: 1 - (shared prefix + suffix) / max length.
    // Catches "text grew / shrank / a middle chunk changed" without the cost of a
    // full edit distance every 3s. Good enough to gate re-reasoning.
    static func normalizedDistance(_ a: String, _ b: String) -> Double {
        if a == b { return 0 }
        let aa = Array(a), bb = Array(b)
        let maxLen = max(aa.count, bb.count)
        guard maxLen > 0 else { return 0 }

        var pre = 0
        while pre < aa.count, pre < bb.count, aa[pre] == bb[pre] { pre += 1 }
        var suf = 0
        while suf < (aa.count - pre), suf < (bb.count - pre),
              aa[aa.count - 1 - suf] == bb[bb.count - 1 - suf] { suf += 1 }

        let shared = pre + suf
        return Double(maxLen - shared) / Double(maxLen)
    }
}
