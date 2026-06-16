import AppKit

// A small, draggable floating chip that holds captured dictation text until
// the user commits it into a field. This is the "decouple capture from
// placement" UX: talk first, decide where it lands second.
//
// Behavior:
//   - Appears at the bottom-center when a dictation finishes with no editable
//     field focused (or when the user prefers always-chip).
//   - Shows a short preview of the captured text.
//   - Draggable anywhere on screen (mouse - so NOT click-through, unlike the
//     listening overlay).
//   - Holds the full text; the Dictator reads .pendingText to commit it.
//   - hide() clears it.
//
// Commit itself is driven by the Dictator (double-tap of the dictation key
// while a field is focused). The chip is just the holding pen + visual.

final class TextChip: NSObject {
    private var window: DraggableChipWindow?
    private var label: NSTextField?
    private var countLabel: NSTextField?

    // The full captured text awaiting commit. nil when the chip is empty/hidden.
    private(set) var pendingText: String?

    // Fired when the user clicks the chip. The Dictator copies the text to the
    // clipboard (stashing whatever was there first) so the captured words aren't
    // trapped in the chip with no way out when no field was focused.
    var onCopy: ((String) -> Void)?

    func present(_ text: String) {
        DispatchQueue.main.async {
            self.pendingText = text
            self.ensureWindow()
            let preview = text.count > 60 ? String(text.prefix(57)) + "..." : text
            self.label?.stringValue = preview
            self.countLabel?.stringValue = "\(text.count) chars - click to copy"
            self.window?.orderFront(nil)
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.pendingText = nil
            self.window?.orderOut(nil)
        }
    }

    var isShowing: Bool { pendingText != nil }

    // MARK: - Internals

    private func ensureWindow() {
        if window != nil { return }

        let width: CGFloat = 320
        let height: CGFloat = 52

        let w = DraggableChipWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.hasShadow = true
        w.isMovableByWindowBackground = true   // drag from anywhere on the chip

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true

        // Doc/quote glyph
        let img = NSImageView(frame: NSRect(x: 12, y: (height - 20) / 2, width: 20, height: 20))
        img.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Captured text")
        img.contentTintColor = .systemTeal
        img.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        bg.addSubview(img)

        let lbl = NSTextField(frame: NSRect(x: 40, y: 26, width: width - 52, height: 18))
        lbl.isEditable = false
        lbl.isBordered = false
        lbl.drawsBackground = false
        lbl.textColor = .labelColor
        lbl.font = .systemFont(ofSize: 13, weight: .medium)
        lbl.maximumNumberOfLines = 1
        lbl.lineBreakMode = .byTruncatingTail
        bg.addSubview(lbl)
        label = lbl

        let count = NSTextField(frame: NSRect(x: 40, y: 8, width: width - 52, height: 14))
        count.isEditable = false
        count.isBordered = false
        count.drawsBackground = false
        count.textColor = .secondaryLabelColor
        count.font = .systemFont(ofSize: 10, weight: .regular)
        count.maximumNumberOfLines = 1
        bg.addSubview(count)
        countLabel = count

        w.contentView = bg

        // Click the chip -> copy. A click (no movement) fires the gesture; a drag
        // still moves the window via isMovableByWindowBackground. Mouse events
        // reach the view even though the window can't become key.
        let click = NSClickGestureRecognizer(target: self, action: #selector(chipClicked))
        bg.addGestureRecognizer(click)

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: visible.maxX - width - 24, y: visible.minY + 96))
        }

        window = w
    }

    @objc private func chipClicked() {
        guard let text = pendingText else { return }
        onCopy?(text)
    }
}

// Borderless windows don't drag by default; this subclass allows it and keeps
// the window from stealing key focus (so the user's field stays focused for
// the double-tap commit).
final class DraggableChipWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
