import AppKit

// Floating overlay that appears while Option is held.
//
// Design intent:
//   - Visible enough to confirm "we're listening right now" without
//     stealing focus, eating keystrokes, or covering important content.
//   - Click-through (ignoresMouseEvents = true) so the user can keep
//     working in whatever app they were focused on.
//   - Bottom-center of the active screen, above floating windows but
//     below modal alerts. Joins all Spaces so it's there in full-screen.
//   - Shows a mic glyph + the live transcript as it comes in. The
//     transcript truncates from the HEAD so the most recent words are
//     always visible — same heuristic Wispr uses.

final class RecordingOverlay {
    private var window: NSWindow?
    private var label: NSTextField?
    private var icon: NSImageView?
    private var statusLabel: NSTextField?

    // Show the overlay. Idempotent — repeated calls just keep it visible
    // and reset the transcript text.
    func show() {
        DispatchQueue.main.async {
            self.ensureWindow()
            self.label?.stringValue = ""
            self.statusLabel?.stringValue = "Listening…"
            self.icon?.contentTintColor = .systemRed
            self.window?.orderFront(nil)
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.window?.orderOut(nil)
            self.label?.stringValue = ""
        }
    }

    // Called as partials come in. The label truncates from the head so
    // the right edge always shows the latest recognized words.
    func updateTranscript(_ text: String) {
        DispatchQueue.main.async {
            self.label?.stringValue = text
        }
    }

    // Lets the Dictator tell the overlay we entered buffering mode (a
    // trigger phrase was detected). Distinguishing visually saves the
    // user from wondering why their dictation isn't typing into the app.
    func setBufferingMode(_ buffering: Bool) {
        DispatchQueue.main.async {
            self.statusLabel?.stringValue = buffering ? "Action" : "Listening…"
            self.icon?.contentTintColor = buffering ? .systemBlue : .systemRed
        }
    }

    // MARK: - Internals

    private func ensureWindow() {
        if window != nil { return }

        let width: CGFloat = 480
        let height: CGFloat = 56

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.ignoresMouseEvents = true   // click-through
        w.hasShadow = true

        // Blurred dark background via NSVisualEffectView
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true

        // Mic icon
        let img = NSImageView(frame: NSRect(x: 14, y: (height - 24) / 2, width: 24, height: 24))
        img.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recording")
        img.contentTintColor = .systemRed
        img.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        bg.addSubview(img)
        icon = img

        // Status label ("Listening…" / "Action")
        let status = NSTextField(frame: NSRect(x: 46, y: 30, width: 110, height: 16))
        status.isEditable = false
        status.isBordered = false
        status.drawsBackground = false
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11, weight: .semibold)
        status.maximumNumberOfLines = 1
        status.stringValue = "Listening…"
        bg.addSubview(status)
        statusLabel = status

        // Live transcript
        let lbl = NSTextField(frame: NSRect(x: 46, y: 8, width: width - 60, height: 22))
        lbl.isEditable = false
        lbl.isBordered = false
        lbl.drawsBackground = false
        lbl.textColor = .labelColor
        lbl.font = .systemFont(ofSize: 14, weight: .medium)
        lbl.maximumNumberOfLines = 1
        lbl.lineBreakMode = .byTruncatingHead   // keep the tail visible
        lbl.stringValue = ""
        bg.addSubview(lbl)
        label = lbl

        w.contentView = bg

        // Bottom-center of the active screen, ~80pt above the dock.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let x = visible.midX - width / 2
            let y = visible.minY + 80
            w.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window = w
    }
}
