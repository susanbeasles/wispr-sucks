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
// The delta gate is semantic (Phase 2): a cheap text-ratio pre-filter, then
// cosine novelty vs a rolling centroid of recent frame embeddings (TextEmbedder).
// Noticed moments are written to PerceptionMemory for recall by meaning.
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

    // Phase 2: semantic perception. Optional - if the embedder/memory failed to
    // init (e.g. embedding assets not ready), the loop falls back to the cheap
    // text-ratio gate and simply does not record memory.
    private var embedder: TextEmbedder?
    private var memory: PerceptionMemory?
    // The sealed ledger (optional, best-effort). Screen observations default to
    // COMPANY provenance: on a PHI machine the screen is work-by-default, so the
    // safe (fail-toward-protection) seal is the device-bound Enclave chain. The
    // classifier can only escalate further, never relax it. Screen OCR can carry
    // PHI, so it goes through the same mandatory scrubber.
    private var ledgers: Ledgers?
    private let scrubber: Scrubber = PhiMaskScrubber()
    private let deriver: LearningDeriver = ModelLearningDeriver()
    // A rolling window of recent per-tick embeddings; its centroid is "what I have
    // been looking at," and a new frame far from it is the meaningful change.
    private var recentVectors: [[Double]] = []
    private let recentWindow = 8

    private let intervalSec = 3.0
    // Cheap pre-filter: skip embedding/reasoning when the OCR text is essentially
    // unchanged (a blinking cursor, a ticking clock). Low so the semantic gate,
    // not this, decides real escalation.
    private let textPrefilter = 0.04
    // The real gate (Phase 2): cosine DISTANCE from the recent centroid. Above
    // this, the meaning changed enough to re-reason. Tunable - up = calmer,
    // down = more reactive.
    private let noveltyThreshold = 0.12

    func attach(overlay: EyeOverlay) {
        self.overlay = overlay
        // The frame's X button stops watching - a reliable, keyboard-free close
        // (the Ctrl-Opt-E hotkey is eaten by secure input in terminals).
        overlay.onClose = { [weak self] in self?.stop() }
    }

    // Phase 2 wiring (optional). Without it the eyes still see; they just do not
    // gate semantically or remember.
    func attachMemory(embedder: TextEmbedder?, memory: PerceptionMemory?) {
        self.embedder = embedder
        self.memory = memory
    }

    func attachLedger(_ ledgers: Ledgers?) { self.ledgers = ledgers }

    func toggle() { isWatching ? stop() : start() }

    func start() {
        guard !isWatching else { return }
        isWatching = true
        lastText = ""
        recentVectors.removeAll()
        NSLog("SonarDictate: eyes START (overlay attached: \(overlay != nil))")
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

        Task { @MainActor in
            defer { self.busy = false }
            do {
                let image = try await EyeCapture.capture(region: region)
                // OCR is synchronous CPU work - run it off the main thread.
                let text = await Task.detached { ScreenText.recognize(image) }.value
                guard self.isWatching else { return }

                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                // Cheap pre-filter: ignore micro-churn before paying for an embedding.
                if !self.lastText.isEmpty, Eye.normalizedDistance(self.lastText, t) < self.textPrefilter {
                    return
                }

                // Semantic gate. Embed the text; novelty = cosine distance from the
                // centroid of recent frames. If the embedder is unavailable, fall
                // back to "any non-trivial text change escalates."
                let vector = try? self.embedder?.vector(for: t)
                let escalate: Bool
                if let v = vector {
                    let novelty = Salience.novelty(of: v, against: self.recentVectors)
                    escalate = self.lastText.isEmpty || novelty >= self.noveltyThreshold
                    self.recentVectors.append(v)
                    if self.recentVectors.count > self.recentWindow {
                        self.recentVectors.removeFirst(self.recentVectors.count - self.recentWindow)
                    }
                } else {
                    escalate = true   // no embedder: pre-filter already proved a change
                }
                self.lastText = t
                EyeSignals.shared.setLatestObservation(t)
                guard escalate, let v = vector else { return }

                // SILENT: she condenses what she sees for her OWN memory and files
                // it - no narration, she does not speak. If reasoning is
                // unavailable, she remembers the raw text instead.
                let note = await self.reasoner.summarize(current: t, previous: nil)
                guard self.isWatching else { return }
                let content = note.isEmpty ? String(t.prefix(600)) : note
                try? self.memory?.add(at: Date(), vector: v, summary: content, kind: "observation")
                EyeSignals.shared.noteRemembered(self.memory?.count ?? 0)
                // Also seal the observation into the owner-routed ledger (company
                // by default for screen) + derive learnings - best-effort, detached.
                if let ledgers = self.ledgers {
                    let scrubber = self.scrubber, deriver = self.deriver
                    let mem = self.memory, emb = self.embedder
                    Task.detached {
                        guard let record = try? await Ingest.ingestEnriched(
                            SourceItem(source: "eye", provenance: .company, at: Date(), text: content, externalId: nil),
                            scrub: scrubber, into: ledgers) else { return }
                        _ = try? await Ingest.learn(from: record, using: deriver, into: ledgers,
                                                    recallInto: mem, embedder: emb)
                    }
                }
            } catch {
                EyeSignals.shared.publishStatus("screen capture blocked - grant Screen Recording in System Settings")
            }
        }
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
