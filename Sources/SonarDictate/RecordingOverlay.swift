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
    // The widget is a tiny SPECK at idle and GROWS (animated) into the full EQ
    // square when you talk. Same square shape, small -> large.
    private static let idleSize = NSSize(width: 16, height: 16)
    private static let listeningSize = NSSize(width: 56, height: 56)

    private var window: DraggableWidgetWindow?
    private var bg: NSView?
    private var led: LEDMicView?
    private var statusLabel: NSTextField?
    private var transcriptLabel: NSTextField?
    private var shrinkWork: DispatchWorkItem?   // delayed shrink-to-speck after release

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

    // Listening state - expand the widget, wake the LED mic, clear transcript.
    // Called on fn-down.
    func show() {
        DispatchQueue.main.async {
            self.shrinkWork?.cancel()   // a quick re-press keeps it grown
            self.ensureWindow()
            self.applyListening()       // animated grow speck -> full square
            WidgetSignals.shared.setListening(true)
            self.led?.beginListening()
            self.window?.orderFront(nil)
        }
    }

    // Back to idle - clear text and release the LED mic (which plays its lock /
    // power-down animation, then settles to a faint idle outline). Called on
    // fn-up. The widget stays visible (it's the user's persistent draggable icon).
    func hide() {
        DispatchQueue.main.async {
            WidgetSignals.shared.setListening(false)
            self.led?.endListening()
            // Stay full-size while the LED plays its release lock + power-down, THEN
            // shrink back to the speck. Cancellable so a quick re-press keeps it big.
            self.shrinkWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.applyIdle() }
            self.shrinkWork = work
            // ~0.2s = right as the white lock finishes filling (sweep completes
            // ~0.18s into the release). Shrink starts the instant the white lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }

    func updateTranscript(_ text: String) {
        DispatchQueue.main.async {
            // Soft crossfade between revisions so word-swaps ("by lateral" ->
            // "bilateral") morph instead of snapping. ~80ms is short enough to
            // feel snappy but long enough to register as smooth.
            if let layer = self.transcriptLabel?.layer {
                let t = CATransition()
                t.type = .fade
                t.duration = 0.08
                layer.add(t, forKey: kCATransition)
            }
            self.transcriptLabel?.stringValue = text
        }
    }

    func setBufferingMode(_ buffering: Bool) {
        DispatchQueue.main.async {
            self.statusLabel?.stringValue = buffering ? "Action" : "Listening..."
        }
    }

    // MARK: - Layout

    // Both states animate the WINDOW frame + alpha. BOTTOM-RIGHT anchored: the
    // bottom edge (the floor) and the right edge stay put, so it grows UPWARD (and a
    // little left), never downward. The LED autoresizes to fill, so its 24x24 design
    // scales with the frame = the EQ grows/shrinks in place.
    private func applyIdle() {
        guard let w = window else { return }
        let br = NSPoint(x: w.frame.maxX, y: w.frame.minY)
        let size = Self.idleSize
        let origin = NSPoint(x: br.x - size.width, y: br.y)
        w.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
        w.alphaValue = 0.7   // a dim but seeable speck
        led?.needsDisplay = true
        savePosition()
    }

    private func applyListening() {
        guard let w = window else { return }
        let br = NSPoint(x: w.frame.maxX, y: w.frame.minY)
        let size = Self.listeningSize
        let origin = NSPoint(x: br.x - size.width, y: br.y)
        w.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
        w.alphaValue = 1.0
        savePosition()
    }

    // MARK: - Position persistence

    private func savePosition() {
        guard let w = window else { return }
        let br = NSPoint(x: w.frame.maxX, y: w.frame.minY)   // bottom-right is the stable anchor
        let d = UserDefaults.standard
        d.set(true, forKey: Self.posKey)
        d.set(Double(br.x), forKey: Self.posXKey)
        d.set(Double(br.y), forKey: Self.posYKey)
    }

    private func loadOrDefaultBottomRight() -> NSPoint {
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
        return defaultBottomRight()
    }

    private func defaultBottomRight() -> NSPoint {
        if let s = NSScreen.main {
            let v = s.visibleFrame
            // Leave headroom ABOVE the speck for the upward grow (listening height).
            return NSPoint(x: v.maxX - 24, y: v.maxY - 24 - Self.listeningSize.height)
        }
        return NSPoint(x: 1200, y: 760)
    }

    private func ensureWindow() {
        if window != nil { return }
        let br = loadOrDefaultBottomRight()
        let size = Self.idleSize
        let origin = NSPoint(x: br.x - size.width, y: br.y)
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

        let background = DragPassthroughEffectView(frame: NSRect(origin: .zero, size: size))
        // Solid near-black matching the LED tile (#060607) - one cohesive dark
        // surface, no translucent gray box around a black tile.
        background.wantsLayer = true
        background.layer?.backgroundColor = CGColor(srgbRed: 6/255, green: 6/255, blue: 7/255, alpha: 1)
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        bg = background

        let ledView = LEDMicView(frame: background.bounds)
        ledView.autoresizingMask = [.width, .height]   // scales with the window grow/shrink
        background.addSubview(ledView)
        led = ledView

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
        lbl.font = .systemFont(ofSize: 17, weight: .medium)
        // Right-align + truncate-head: the latest words always sit at the SAME
        // right-edge anchor instead of pushing the existing line leftward as
        // new words arrive. Kills the visual "jolt" of revisions.
        lbl.alignment = .right
        lbl.maximumNumberOfLines = 1
        lbl.lineBreakMode = .byTruncatingHead
        lbl.stringValue = ""
        lbl.isHidden = true
        lbl.wantsLayer = true   // so we can attach the fade CATransition
        background.addSubview(lbl)
        transcriptLabel = lbl

        w.contentView = background
        window = w
    }
}

// The widget's background. It is display + drag only - nothing inside it is
// clickable - so every click anywhere in its bounds resolves to THIS view rather
// than to a subview. That matters because the mic icon (NSImageView) and the text
// labels (NSTextField) are NSControls, which return mouseDownCanMoveWindow=false
// and would otherwise swallow the click and block isMovableByWindowBackground -
// the "I can't drag from the icon, only from outside it" bug. As a plain NSView,
// this view allows window-background dragging, so the whole widget drags.
final class DragPassthroughEffectView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Inside the widget -> us (draggable). Outside -> nil (pass through).
        return super.hitTest(point) == nil ? nil : self
    }
}

// NSWindow subclass that (a) lets us drag the widget without becoming key (so
// the user's real input stays focused for the on-release commit), and (b)
// reports drag-end via onDragEnd so we can persist the new position.
final class DraggableWidgetWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    var onDragEnd: (() -> Void)?

    // Snappy grow/shrink: a short fixed resize duration (the default scales with
    // size change and feels sluggish). Drives both the grow-on-talk and the fast
    // shrink-on-release.
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.13 }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onDragEnd?()
    }
}
