import AppKit

// The "look here" frame: a resizable, draggable, persistent overlay the user
// places over whatever they want the eyes to watch. Two windows:
//
//   frameWindow   - the watched rect. A visible rounded border with a faint
//                   interior tint and a bottom-right resize grip. Its INTERIOR is
//                   click-through (hitTest returns nil) so the user keeps working
//                   under it; only the border band and the grip are interactive
//                   (drag to move / resize).
//   captionWindow - a thin strip just BELOW the frame showing the latest
//                   situational read. It sits OUTSIDE the watched rect on purpose,
//                   so the eyes never OCR their own caption (no feedback loop).
//
// captureRegion() returns frameWindow.frame in global AppKit coordinates - that
// is exactly what EyeCapture wants. Frame position+size persist across launches.
final class EyeOverlay {
    private static let xKey = "sonar-dictate.eye.frame.x"
    private static let yKey = "sonar-dictate.eye.frame.y"
    private static let wKey = "sonar-dictate.eye.frame.w"
    private static let hKey = "sonar-dictate.eye.frame.h"
    private static let savedKey = "sonar-dictate.eye.frame.saved"

    private static let minSize = NSSize(width: 160, height: 120)
    private static let captionHeight: CGFloat = 40
    private static let captionGap: CGFloat = 6

    private var frameWindow: EyeFrameWindow?
    private var frameView: EyeFrameView?
    private var captionWindow: NSWindow?
    private var captionLabel: NSTextField?

    // Called when the user clicks the frame's X (stop watching). Wired by Eye.
    var onClose: (() -> Void)?

    // Build both windows (hidden) and subscribe to the signal bus. Call once at
    // launch; showFrame()/hideFrame() flip visibility when watching starts/stops.
    func install() {
        DispatchQueue.main.async {
            self.ensureWindows()
            EyeSignals.shared.onUpdate = { [weak self] snap in self?.render(snap) }
        }
    }

    func showFrame() {
        DispatchQueue.main.async {
            self.ensureWindows()
            self.repositionCaption()
            self.frameWindow?.orderFront(nil)
            self.captionWindow?.orderFront(nil)
            NSLog("SonarDictate: eyes showFrame - frame at \(self.frameWindow?.frame ?? .zero), visible: \(self.frameWindow?.isVisible ?? false)")
        }
    }

    func hideFrame() {
        DispatchQueue.main.async {
            self.frameWindow?.orderOut(nil)
            self.captionWindow?.orderOut(nil)
        }
    }

    // The watched rect in global AppKit coordinates (bottom-left origin).
    func captureRegion() -> CGRect? {
        frameWindow?.frame
    }

    // MARK: - Build

    private func ensureWindows() {
        if frameWindow != nil { return }

        let frame = loadOrDefaultFrame()

        let fw = EyeFrameWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        fw.isOpaque = false
        fw.backgroundColor = .clear
        fw.level = .floating
        fw.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        fw.hasShadow = false
        fw.ignoresMouseEvents = false

        let view = EyeFrameView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        view.onLiveChange = { [weak self] in self?.repositionCaption() }
        view.onCommit = { [weak self] in self?.saveFrame() }
        view.onClose = { [weak self] in self?.onClose?() }
        fw.contentView = view
        frameView = view
        frameWindow = fw

        // Caption strip (non-interactive, sits below the frame).
        let cw = NSWindow(
            contentRect: NSRect(x: frame.minX, y: frame.minY - Self.captionHeight - Self.captionGap,
                                width: frame.width, height: Self.captionHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        cw.isOpaque = false
        cw.backgroundColor = .clear
        cw.level = .floating
        cw.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        cw.hasShadow = false
        cw.ignoresMouseEvents = true

        let bg = NSView(frame: NSRect(origin: .zero, size: NSSize(width: frame.width, height: Self.captionHeight)))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = CGColor(srgbRed: 6/255, green: 6/255, blue: 7/255, alpha: 0.92)
        bg.layer?.cornerRadius = 8
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]

        let lbl = NSTextField(frame: NSRect(x: 10, y: 4, width: frame.width - 20, height: Self.captionHeight - 8))
        lbl.isEditable = false
        lbl.isBordered = false
        lbl.drawsBackground = false
        lbl.textColor = .labelColor
        lbl.font = .systemFont(ofSize: 12, weight: .medium)
        lbl.maximumNumberOfLines = 2
        lbl.lineBreakMode = .byTruncatingTail
        lbl.cell?.wraps = true
        lbl.stringValue = "idle"
        lbl.autoresizingMask = [.width, .height]
        bg.addSubview(lbl)
        cw.contentView = bg
        captionLabel = lbl
        captionWindow = cw
    }

    // MARK: - Caption

    private func repositionCaption() {
        guard let fw = frameWindow, let cw = captionWindow else { return }
        let f = fw.frame
        cw.setFrame(
            NSRect(x: f.minX, y: f.minY - Self.captionHeight - Self.captionGap,
                   width: f.width, height: Self.captionHeight),
            display: true
        )
    }

    private func render(_ snap: EyeSignals.Snapshot) {
        let text = snap.summary.isEmpty ? snap.status : snap.summary
        if let layer = captionLabel?.superview?.layer {
            let t = CATransition()
            t.type = .fade
            t.duration = 0.12
            layer.add(t, forKey: kCATransition)
        }
        captionLabel?.stringValue = text
    }

    // MARK: - Persistence

    private func saveFrame() {
        guard let f = frameWindow?.frame else { return }
        let d = UserDefaults.standard
        d.set(true, forKey: Self.savedKey)
        d.set(Double(f.minX), forKey: Self.xKey)
        d.set(Double(f.minY), forKey: Self.yKey)
        d.set(Double(f.width), forKey: Self.wKey)
        d.set(Double(f.height), forKey: Self.hKey)
        repositionCaption()
    }

    private func loadOrDefaultFrame() -> NSRect {
        let d = UserDefaults.standard
        if d.object(forKey: Self.savedKey) != nil {
            let r = NSRect(x: d.double(forKey: Self.xKey), y: d.double(forKey: Self.yKey),
                           width: max(Self.minSize.width, d.double(forKey: Self.wKey)),
                           height: max(Self.minSize.height, d.double(forKey: Self.hKey)))
            if NSScreen.screens.contains(where: { $0.frame.intersects(r) }) {
                return r
            }
        }
        // Default: a centered-ish rectangle on the main screen.
        if let v = NSScreen.main?.visibleFrame {
            let w: CGFloat = 480, h: CGFloat = 320
            return NSRect(x: v.midX - w / 2, y: v.midY - h / 2, width: w, height: h)
        }
        return NSRect(x: 400, y: 400, width: 480, height: 320)
    }
}

// The frame window: borderless, never becomes key (so the user's real focus is
// never stolen), reports nothing on its own - the content view drives move/resize.
final class EyeFrameWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// The "look here" frame. Bulletproof interaction (no keyboard needed):
//   - drag ANYWHERE on the frame to move it,
//   - drag the bottom-right grip to resize,
//   - click the top-right X to close (stop watching).
// The whole frame captures clicks (it sits ON the region being watched, not
// something you work under), so it can always be grabbed - the old version made
// the interior click-through and the edges too thin to hit, which trapped it.
final class EyeFrameView: NSView {
    var gripSize: CGFloat = 26
    var closeSize: CGFloat = 28
    var onLiveChange: (() -> Void)?   // fired during a drag (reposition caption)
    var onCommit: (() -> Void)?       // fired on mouse-up (persist)
    var onClose: (() -> Void)?        // fired when the X is clicked

    private enum Mode { case move, resize }
    private var mode: Mode = .move
    private var startMouse: NSPoint = .zero
    private var startFrame: NSRect = .zero

    override var isFlipped: Bool { false }   // bottom-left origin, matches window coords

    // Capture clicks across the whole frame so it can always be moved/resized/closed.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let parent = superview else { return self }
        return bounds.contains(convert(point, from: parent)) ? self : nil
    }

    private var gripRect: NSRect {
        NSRect(x: bounds.maxX - gripSize, y: bounds.minY, width: gripSize, height: gripSize)
    }
    private var closeRect: NSRect {
        NSRect(x: bounds.maxX - closeSize, y: bounds.maxY - closeSize, width: closeSize, height: closeSize)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if closeRect.contains(local) {
            onClose?()
            return
        }
        startMouse = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
        mode = gripRect.contains(local) ? .resize : .move
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, startFrame.width > 0 else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - startMouse.x
        let dy = now.y - startMouse.y

        switch mode {
        case .move:
            window.setFrameOrigin(NSPoint(x: startFrame.minX + dx, y: startFrame.minY + dy))
        case .resize:
            // Bottom-right grip: top edge fixed, width follows x, bottom follows y.
            let newW = max(EyeOverlayLimits.minWidth, startFrame.width + dx)
            let newMinY = min(startFrame.maxY - EyeOverlayLimits.minHeight, startFrame.minY + dy)
            window.setFrame(
                NSRect(x: startFrame.minX, y: newMinY, width: newW, height: startFrame.maxY - newMinY),
                display: true
            )
        }
        onLiveChange?()
    }

    override func mouseUp(with event: NSEvent) {
        onCommit?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cyan = CGColor(srgbRed: 0.10, green: 0.85, blue: 0.95, alpha: 1.0)
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil)

        // Faint interior tint so it reads as a frame.
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.85, blue: 0.95, alpha: 0.06))
        ctx.fillPath()

        // Border.
        ctx.addPath(path)
        ctx.setStrokeColor(cyan.copy(alpha: 0.9)!)
        ctx.setLineWidth(2.0)
        ctx.strokePath()

        // Top-right CLOSE button: a filled disc with an X.
        let c = closeRect.insetBy(dx: 5, dy: 5)
        ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.12, blue: 0.13, alpha: 0.92))
        ctx.fillEllipse(in: c)
        ctx.setStrokeColor(cyan)
        ctx.setLineWidth(1.0)
        ctx.strokeEllipse(in: c)
        ctx.setLineWidth(2.0)
        ctx.setLineCap(.round)
        let pad: CGFloat = 5
        ctx.move(to: CGPoint(x: c.minX + pad, y: c.minY + pad))
        ctx.addLine(to: CGPoint(x: c.maxX - pad, y: c.maxY - pad))
        ctx.move(to: CGPoint(x: c.minX + pad, y: c.maxY - pad))
        ctx.addLine(to: CGPoint(x: c.maxX - pad, y: c.minY + pad))
        ctx.strokePath()

        // Bottom-right resize grip: two corner ticks.
        let g = gripRect
        ctx.setStrokeColor(cyan)
        ctx.setLineWidth(2.0)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: g.maxX - 4, y: g.minY + 7));  ctx.addLine(to: CGPoint(x: g.maxX - 4, y: g.minY + 4)); ctx.addLine(to: CGPoint(x: g.maxX - 7, y: g.minY + 4)); ctx.strokePath()
        ctx.move(to: CGPoint(x: g.maxX - 4, y: g.minY + 13)); ctx.addLine(to: CGPoint(x: g.maxX - 4, y: g.minY + 4)); ctx.addLine(to: CGPoint(x: g.maxX - 13, y: g.minY + 4)); ctx.strokePath()
    }
}

// Minimum size shared with the resize math (kept off the view so the static
// values do not depend on a live instance).
enum EyeOverlayLimits {
    static let minWidth: CGFloat = 160
    static let minHeight: CGFloat = 120
}
