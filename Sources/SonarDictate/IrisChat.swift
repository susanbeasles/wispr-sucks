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

    private weak var memory: PerceptionMemory?
    private var embedder: TextEmbedder?
    private var history: [[String: String]] = []   // conversation turns, for context
    private var busy = false

    func attach(memory: PerceptionMemory?, embedder: TextEmbedder?) {
        self.memory = memory
        self.embedder = embedder
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

        let field = NSTextField(frame: NSRect(x: 8, y: 8, width: 404, height: 28))
        field.placeholderString = "Talk to Iris..."
        field.autoresizingMask = [.width]
        field.bezelStyle = .roundedBezel
        field.target = self
        field.action = #selector(handleSend)
        container.addSubview(field)
        self.input = field

        w.contentView = container
        self.window = w
        appendAttr("Iris is here - watching quietly, remembering. Talk to her.\n\n",
                   color: .secondaryLabelColor, bold: false)
    }

    // MARK: - Send

    @objc private func handleSend() {
        guard let input, !busy else { return }
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input.stringValue = ""

        appendAttr("you  ", color: .systemTeal, bold: true)
        appendAttr(text + "\n", color: .labelColor, bold: false)
        remember(text, kind: "utterance", tag: true)

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
            }
        }
    }

    // Build the user turn with her context: what she sees now + what she remembers.
    private func contextualize(_ text: String) -> String {
        var parts: [String] = []
        let screen = EyeSignals.shared.snapshot().latestObservation
        if !screen.isEmpty {
            parts.append("(On screen right now: \(String(screen.prefix(500))))")
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
        guard let memory, let embedder else { return }
        Task.detached {
            guard let v = try? embedder.vector(for: text) else { return }
            let tags = tag ? await IrisClient.tags(for: text) : []
            try? memory.add(at: Date(), vector: v, summary: text, kind: kind, tags: tags)
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
