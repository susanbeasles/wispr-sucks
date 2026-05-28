import AppKit

// Floating live widget - a draggable, user-positioned icon that shows the live
// transcript while you're talking and sits as a subtle mic icon when you're not.
//
// Why this exists (and isn't just an auto-positioned click-through pill):
// the user wants control - "into a fucking icon to the right hand side or
// wherever I decide to put it... I can move it around at any point." So:
//   - Always visible (idle when not dictating, expanded when listening).
//   - Draggable from anywhere on the widget; position survives launches.
//   - Doesn't steal keyboard focus (canBecomeKey = false) - your real input
//     stays focused for the on-release commit.
//
// Two sizes anchored on the TOP-RIGHT corner so the icon stays visually put
// when the bubble expands leftward into listening mode:
//   - IDLE:      5240, just the mic icon, dimmed.
//   - LISTENING: 48056, mic + "Listening..." + live transcript.
//
// The class name stays `RecordingOverlay` so the Dictator's call sites
// (show / hide / updateTranscript / setBufferingMode) don't have to change;
// show() now means "expand to listening" and hide() means "back to idle"
// instead of "orderFront / orderOut".

final class RecordingOverlay {
    private static let posKey = "sonar-dictate.widget.topRight"
    private static let posXKey = "sonar-dictate.widget.topRight.x"
    private static let posYKey = "sonar-dictate.widget.topRight.y"
    private static let idleSize = NSSize(width: 52, height: 40)
    private static let listeningSize = NSSize(width: 480, height: 56)

    private var window: DraggableWidgetWindow?
    private var bg: NSVisualEffectView?
    private var icon: NSImageView?
    private var statusLabel: NSTextField?
    private var transcriptLabel: NSTextField?

    // Call ONCE at app launch. Creates the widget in its idle state at its
    // saved position (or upper-right of the main screen on first run) and
    // shows it. The Dictator's other calls (show/hide/updateTranscript) just
    // transition between states from here on.
    func install() {
        DispatchQueue.main.async {
            self.ensureWindow()
            self.applyIdle()
            self.window?.orderFront(nil)
        }
    }

    // Listening state - expand the widget, red mic, clear transcript. Called
    // on Option-down.
    func show() {
        DispatchQueue.main.async {
            self.ensureWindow()
            self.applyListening()
            self.transcriptLabel?.stringValue = ""
            self.statusLabel?.stringValue = "Listening..."
            self.icon?.contentTintColor = .systemRed
            self.window?.orderFront(nil)
        }
    }

    // Back to idle - collapse, dim the icon, clear text. Called on Option-up.
    // The widget stays visible (it's the user's persistent draggable icon).
    func hide() {
        DispatchQueue.main.async {
            self.transcriptLabel?.stringValue = ""
            self.statusLabel?.stringValue = ""
            self.applyIdle()
        }
    }

    func updateTranscript(_ text: String) {
        DispatchQueue.main.async { self.transcriptLabel?.stringValue = text }
    }

    func setBufferingMode(_ buffering: Bool) {
        DispatchQueue.main.async {
            self.statusLabel?.stringValue = buffering ? "Action" : "Listening..."
            self.icon?.contentTintColor = buffering ? .systemBlue : .systemRed
        }
    }

    // MARK: - Layout

    private func applyIdle() {
        guard let w = window else { return }
        // Anchor on the CURRENT top-right so the icon doesn't visually jump
        // when we collapse from listening size.
        let tr = NSPoint(x: w.frame.maxX, y: w.frame.maxY)
        let size = Self.idleSize
        let origin = NSPoint(x: tr.x - size.width, y: tr.y - size.height)
        w.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        bg?.frame = NSRect(origin: .zero, size: size)
        icon?.frame = NSRect(x: (size.width - 24) / 2, y: (size.height - 24) / 2, width: 24, height: 24)
        icon?.contentTintColor = .secondaryLabelColor
        statusLabel?.isHidden = true
        transcriptLabel?.isHidden = true
        w.alphaValue = 0.55   // subtle when not dictating
        savePosition()
    }

    private func applyListening() {
        guard let w = window else { return }
        let tr = NSPoint(x: w.frame.maxX, y: w.frame.maxY)
        let size = Self.listeningSize
        let origin = NSPoint(x: tr.x - size.width, y: tr.y - size.height)
        w.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        bg?.frame = NSRect(origin: .zero, size: size)
        icon?.frame = NSRect(x: 14, y: (size.height - 24) / 2, width: 24, height: 24)
        statusLabel?.frame = NSRect(x: 46, y: 30, width: 110, height: 16)
        statusLabel?.isHidden = false
        transcriptLabel?.frame = NSRect(x: 46, y: 8, width: size.width - 60, height: 22)
        transcriptLabel?.isHidden = false
        w.alphaValue = 1.0
        savePosition()
    }

    // MARK: - Position persistence

    private func savePosition() {
        guard let w = window else { return }
        let tr = NSPoint(x: w.frame.maxX, y: w.frame.maxY)
        let d = UserDefaults.standard
        d.set(true, forKey: Self.posKey)
        d.set(Double(tr.x), forKey: Self.posXKey)
        d.set(Double(tr.y), forKey: Self.posYKey)
    }

    private func loadOrDefaultTopRight() -> NSPoint {
        let d = UserDefaults.standard
        if d.object(forKey: Self.posKey) != nil {
            let p = NSPoint(x: CGFloat(d.double(forKey: Self.posXKey)),
                            y: CGFloat(d.double(forKey: Self.posYKey)))
            // Clamp: if saved position is off all screens (monitor changed),
            // fall back to the default rather than stranding the widget.
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(p) }) {
                return p
            }
        }
        return defaultTopRight()
    }

    private func defaultTopRight() -> NSPoint {
        if let s = NSScreen.main {
            let v = s.visibleFrame
            return NSPoint(x: v.maxX - 24, y: v.maxY - 24)
        }
        return NSPoint(x: 1200, y: 800)
    }

    private func ensureWindow() {
        if window != nil { return }
        let tr = loadOrDefaultTopRight()
        let size = Self.idleSize
        let origin = NSPoint(x: tr.x - size.width, y: tr.y - size.height)
        let w = DraggableWidgetWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.hasShadow = true
        w.isMovableByWindowBackground = true   // drag from anywhere on the widget
        w.onDragEnd = { [weak self] in self?.savePosition() }

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        bg = background

        let img = NSImageView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        img.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Microphone")
        img.contentTintColor = .secondaryLabelColor
        img.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        background.addSubview(img)
        icon = img

        let status = NSTextField(frame: NSRect(x: 46, y: 30, width: 110, height: 16))
        status.isEditable = false
        status.isBordered = false
        status.drawsBackground = false
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11, weight: .semibold)
        status.maximumNumberOfLines = 1
        status.stringValue = ""
        status.isHidden = true
        background.addSubview(status)
        statusLabel = status

        let lbl = NSTextField(frame: NSRect(x: 46, y: 8, width: Self.listeningSize.width - 60, height: 22))
        lbl.isEditable = false
        lbl.isBordered = false
        lbl.drawsBackground = false
        lbl.textColor = .labelColor
        lbl.font = .systemFont(ofSize: 14, weight: .medium)
        lbl.maximumNumberOfLines = 1
        lbl.lineBreakMode = .byTruncatingHead   // keep the latest words visible
        lbl.stringValue = ""
        lbl.isHidden = true
        background.addSubview(lbl)
        transcriptLabel = lbl

        w.contentView = background
        window = w
    }
}

// NSWindow subclass that (a) lets us drag the widget without becoming key (so
// the user's real input stays focused for the on-release commit), and (b)
// reports drag-end via onDragEnd so we can persist the new position.
final class DraggableWidgetWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    var onDragEnd: (() -> Void)?

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onDragEnd?()
    }
}
