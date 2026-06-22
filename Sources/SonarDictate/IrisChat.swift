import AppKit

// Iris's conversation surface. She is silent by default (the eyes fill her
// memory without narrating); this is the ONLY place she speaks, and only when
// spoken to. Her replies STREAM in token by token. Everything said here - your
// words and hers - is embedded, tagged, and filed into the same memory the eyes
// fill. That shared memory is her brain.
@available(macOS 26.0, *)
final class IrisChat: NSObject {
    private var window: NSWindow?
    private var textView: NSTextView?
    private var input: NSTextField?
    private var listenButton: NSButton?

    // Click the Listen button -> toggle the call listener (reliable; no hotkey).
    var onToggleListen: (() -> Void)?

    private weak var memory: PerceptionMemory?
    private weak var agenda: AgendaStore?
    private var embedder: TextEmbedder?
    // The owner-routed sealed ledger + her brain of learnings. Optional and used
    // best-effort: if it is nil or any step fails, the chat is unaffected.
    private var ledgers: Ledgers?
    private let scrubber: Scrubber = PhiMaskScrubber()        // mandatory PHI gate
    private let deriver: LearningDeriver = ModelLearningDeriver()
    private var history: [[String: String]] = []   // conversation turns, for context
    private var recentCall: [String] = []           // rolling call transcript (her ears -> her context)
    private var busy = false
    private var voiceOn = true   // she speaks her replies aloud; /mute to silence
    // Track the last call line so a growing utterance REPLACES it instead of
    // printing "Hey", "Hey there", "Hey there friend" as three lines.
    private var lastCallStart = -1
    private var lastCallLen = 0
    private var lastCallText = ""
    private var lastCallLabel = ""

    func attach(memory: PerceptionMemory?, embedder: TextEmbedder?, agenda: AgendaStore?, ledgers: Ledgers?) {
        self.memory = memory
        self.embedder = embedder
        self.agenda = agenda
        self.ledgers = ledgers
    }

    func install() { DispatchQueue.main.async { self.ensureWindow() } }

    func show() {
        DispatchQueue.main.async {
            self.ensureWindow()
            self.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let i = self.input { self.window?.makeFirstResponder(i) }
        }
    }

    // MARK: - Call listening (her ears)

    // Dead-obvious listening state: the window title + a clear marker line, so you
    // never think she's listening when she is not.
    func noteListening(_ on: Bool) {
        DispatchQueue.main.async {
            self.ensureWindow()
            self.window?.title = on ? "Iris - LISTENING (call)" : "Iris"
            self.listenButton?.title = on ? "Stop" : "Listen"
            self.appendAttr(on ? "--- LISTENING: system audio + your mic ---\n"
                               : "--- stopped listening ---\n",
                            color: on ? .systemGreen : .systemOrange, bold: true)
            if on { self.show() }
        }
    }

    // A transcript segment from the call (label = "you" / "them"). If it just
    // EXTENDS the last call line (same speaker, still mid-utterance) it replaces
    // that line; otherwise it starts a new one. The length check ensures we only
    // replace when nothing else (a reply, a marker) was printed in between.
    func appendCallSegment(_ label: String, _ text: String) {
        DispatchQueue.main.async {
            guard let tv = self.textView, let storage = tv.textStorage else { return }

            let canReplace = self.lastCallStart >= 0
                && self.lastCallLabel == label
                && text.hasPrefix(self.lastCallText)
                && storage.length == self.lastCallStart + self.lastCallLen
            if canReplace {
                storage.deleteCharacters(in: NSRange(location: self.lastCallStart, length: self.lastCallLen))
                // The growing line supersedes the partial we recorded for context.
                if !self.recentCall.isEmpty { self.recentCall.removeLast() }
            }

            let start = storage.length
            let color: NSColor = (label == "you") ? .systemTeal : .systemPurple
            storage.append(NSAttributedString(string: "\(label)  ",
                attributes: [.foregroundColor: color, .font: NSFont.boldSystemFont(ofSize: 12)]))
            storage.append(NSAttributedString(string: text + "\n",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 13)]))

            self.lastCallStart = start
            self.lastCallLen = storage.length - start
            self.lastCallText = text
            self.lastCallLabel = label
            self.recentCall.append("\(label): \(text)")
            if self.recentCall.count > 40 { self.recentCall.removeFirst(self.recentCall.count - 40) }
            tv.scrollToEndOfDocument(nil)
        }
    }

    // Live, content-free capture counts in the title (no CLI/log, no prompts).
    func noteDiag(_ text: String) {
        DispatchQueue.main.async { self.window?.title = "Iris - LISTENING  [\(text)]" }
    }

    // MARK: - Build

    private func ensureWindow() {
        if window != nil { return }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        w.title = "Iris"
        w.isReleasedWhenClosed = false
        w.center()

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 540))

        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 44, width: 420, height: 496)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(srgbRed: 6/255, green: 6/255, blue: 7/255, alpha: 1)
        tv.textColor = .labelColor
        tv.font = .systemFont(ofSize: 13)
        tv.textContainerInset = NSSize(width: 8, height: 8)
        container.addSubview(scroll)
        self.textView = tv

        let field = NSTextField(frame: NSRect(x: 8, y: 8, width: 312, height: 28))
        field.placeholderString = "Talk to Iris..."
        field.autoresizingMask = [.width]
        field.bezelStyle = .roundedBezel
        field.target = self
        field.action = #selector(handleSend)
        container.addSubview(field)
        self.input = field

        let listen = NSButton(frame: NSRect(x: 328, y: 8, width: 84, height: 28))
        listen.title = "Listen"
        listen.bezelStyle = .rounded
        listen.autoresizingMask = [.minXMargin]
        listen.target = self
        listen.action = #selector(handleListen)
        listen.toolTip = "Iris listens to the call (system audio + your mic)"
        container.addSubview(listen)
        self.listenButton = listen

        w.contentView = container
        self.window = w
        appendAttr("Iris is here - watching quietly, remembering. Talk to her.\n\n",
                   color: .secondaryLabelColor, bold: false)
    }

    // MARK: - Send

    @objc private func handleListen() {
        onToggleListen?()
    }

    @objc private func handleSend() {
        guard let input, !busy else { return }
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input.stringValue = ""

        appendAttr("you  ", color: .systemTeal, bold: true)
        appendAttr(text + "\n", color: .labelColor, bold: false)

        // Agenda commands - reliable, no LLM round-trip.
        let lower = text.lowercased()
        if lower == "/mute" || lower == "/quiet" {
            voiceOn = false
            appendAttr("[muted - she will not speak aloud]\n", color: .systemOrange, bold: false)
            return
        }
        if lower == "/voice" || lower == "/unmute" || lower == "/speak" {
            voiceOn = true
            let line = IrisVoice.isAvailable
                ? "[voice on]" : "[voice on - but not installed yet; run the venv install]"
            appendAttr("\(line)\n", color: .systemGreen, bold: false)
            return
        }
        if lower == "/brief" || lower == "/plan" || lower.contains("plan my day")
            || lower.contains("brief me") || lower.contains("my day") {
            showBrief()
            return
        }
        if lower == "/agenda" || lower == "/list" || lower.contains("what's on my list")
            || lower.contains("whats on my list") || lower.contains("my agenda")
            || lower.contains("my action items") || lower.contains("my to-do") || lower.contains("my todo") {
            showAgenda()
            return
        }
        if lower.hasPrefix("done ") || lower.hasPrefix("/done ") {
            let needle = String(text.dropFirst(lower.hasPrefix("/done ") ? 6 : 5))
            if let item = agenda?.complete(needle) {
                appendAttr("[done] \(item.text)\n", color: .systemGreen, bold: false)
            } else {
                appendAttr("[nothing open matched \"\(needle)\"]\n", color: .systemOrange, bold: false)
            }
            return
        }

        remember(text, kind: "utterance", tag: true)
        captureAgenda(text)   // auto-extract action items / notes (background, conservative)

        history.append(["role": "user", "content": contextualize(text)])
        busy = true
        appendAttr("iris  ", color: NSColor.systemIndigo, bold: true)

        Task { @MainActor in
            let reply = await IrisClient.streamChat(self.history) { token in
                self.appendAttr(token, color: .labelColor, bold: false)
            }
            self.appendAttr("\n\n", color: .labelColor, bold: false)
            self.busy = false
            if reply.isEmpty {
                self.appendAttr("(Iris is unreachable - is ollama running?)\n\n",
                                color: .systemOrange, bold: false)
            } else {
                self.history.append(["role": "assistant", "content": reply])
                self.remember(reply, kind: "reply", tag: false)
                if self.voiceOn { IrisVoice.speak(reply) }   // she says it aloud in her own voice
            }
        }
    }

    // Show the open agenda directly (no LLM - reliable).
    private func showAgenda() {
        let items = agenda?.open() ?? []
        guard !items.isEmpty else {
            appendAttr("(your list is empty)\n", color: .secondaryLabelColor, bold: false)
            return
        }
        appendAttr("Your list - \(items.count) open:\n", color: NSColor.systemIndigo, bold: true)
        for it in items {
            let mark = it.kind == "task" ? "[ ]" : "  -"
            appendAttr("  \(mark) \(it.text)   (\(it.id))\n", color: .labelColor, bold: false)
        }
    }

    // The day-brief: the open agenda ordered by SALIENCE (Salience.base) - the
    // first VIEW over the one classify-and-rank primitive. Not a bespoke planner:
    // it is just the agenda sorted by how much each item should rise (kind weight
    // plus staleness), so the thing that nags loudest sits on top. Nudges will
    // reuse this exact ranking, conditioned on the moment instead of the whole day.
    private func showBrief() {
        let items = agenda?.open() ?? []
        guard !items.isEmpty else {
            appendAttr("(nothing on your plate - your list is empty)\n", color: .secondaryLabelColor, bold: false)
            return
        }
        let now = Date()
        let ranked = items
            .map { (item: $0, score: Salience.base(kind: Self.salienceKind($0.kind),
                                                   age: now.timeIntervalSince($0.createdAt))) }
            .sorted { $0.score > $1.score }

        appendAttr("Your day - \(ranked.count) open, most pressing first:\n",
                   color: NSColor.systemIndigo, bold: true)
        for (i, r) in ranked.enumerated() {
            let mark = r.item.kind == "task" ? "[ ]" : "  -"
            appendAttr("  \(i + 1). \(mark) \(r.item.text)\n", color: .labelColor, bold: false)
        }
    }

    // Map an agenda item's kind onto the salience taxonomy. A task is an action
    // (something to do); a note is a fact (something to remember).
    private static func salienceKind(_ agendaKind: String) -> Salience.Kind {
        agendaKind == "note" ? .fact : .action
    }

    // Auto-capture action items / notes from a message (background, conservative).
    private func captureAgenda(_ text: String) {
        guard let agenda else { return }
        Task { @MainActor in
            let items = await IrisClient.extractAgenda(from: text)
            for it in items {
                let added = agenda.add(kind: it.kind, text: it.text)
                self.appendAttr("[+\(added.kind)] \(added.text)\n", color: .systemTeal, bold: false)
            }
        }
    }

    // Build the user turn with her context: what she sees now + what she remembers.
    private func contextualize(_ text: String) -> String {
        var parts: [String] = []
        if let open = agenda?.open(), !open.isEmpty {
            let lines = open.prefix(20).map { "- [\($0.kind)] \($0.text)" }.joined(separator: "\n")
            parts.append("(The user's current open agenda - their tasks and notes. Use this when relevant:\n\(lines))")
        }
        let screen = EyeSignals.shared.snapshot().latestObservation
        if !screen.isEmpty {
            parts.append("(On screen right now: \(String(screen.prefix(500))))")
        }
        if !recentCall.isEmpty {
            let lines = recentCall.suffix(24).joined(separator: "\n")
            parts.append("(You are listening to a live call. This is what you have heard - 'you' is the user you are helping, 'them' is the other party. This IS your hearing; do not deny you can hear:\n\(lines))")
        }
        if let memory, let embedder, let v = try? embedder.vector(for: text) {
            let hits = memory.recall(vector: v, k: 4).filter { $0.score > 0.3 }
            if !hits.isEmpty {
                let mems = hits.map { "- \($0.entry.summary)" }.joined(separator: "\n")
                parts.append("(Things you remember that may be relevant:\n\(mems))")
            }
        }
        parts.append(text)
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Memory (her brain)

    private func remember(_ text: String, kind: String, tag: Bool) {
        if kind != "reply" { ingestToLedger(text) }   // seal real input + learn (best-effort)
        guard let memory, let embedder else { return }
        Task.detached {
            guard let v = try? embedder.vector(for: text) else { return }
            let tags = tag ? await IrisClient.tags(for: text) : []
            try? memory.add(at: Date(), vector: v, summary: text, kind: kind, tags: tags)
        }
    }

    // Seal what you said into the owner-routed ledger (PHI-scrubbed, classified by
    // owner) and derive learnings into her brain. Fully detached, best-effort -
    // never blocks the reply, never breaks the chat if the ledger/masker is absent.
    private func ingestToLedger(_ text: String) {
        guard let ledgers else { return }
        let scrubber = self.scrubber
        let deriver = self.deriver
        Task.detached {
            guard let record = try? Ingest.ingest(
                SourceItem(source: "chat", provenance: .personal, at: Date(), text: text, externalId: nil),
                scrub: scrubber, into: ledgers) else { return }
            _ = try? await Ingest.learn(from: record, using: deriver, into: ledgers)
        }
    }

    // MARK: - Transcript

    private func appendAttr(_ string: String, color: NSColor, bold: Bool) {
        DispatchQueue.main.async {
            guard let tv = self.textView, let storage = tv.textStorage else { return }
            let font = bold ? NSFont.boldSystemFont(ofSize: 12) : NSFont.systemFont(ofSize: 13)
            storage.append(NSAttributedString(string: string, attributes: [.foregroundColor: color, .font: font]))
            tv.scrollToEndOfDocument(nil)
        }
    }
}
