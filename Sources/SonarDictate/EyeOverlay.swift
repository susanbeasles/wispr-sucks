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
        view.gripSize = 18
        view.borderBand = 10
        view.onLiveChange = { [weak self] in self?.repositionCaption() }
        view.onCommit = { [weak self] in self?.saveFrame() }
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

// Draws the "look here" border + grip, and handles move/resize from the border
// band and the bottom-right grip. The interior is click-through.
final class EyeFrameView: NSView {
    var gripSize: CGFloat = 18
    var borderBand: CGFloat = 10
    var onLiveChange: (() -> Void)?   // fired during a drag (reposition caption)
    var onCommit: (() -> Void)?       // fired on mouse-up (persist)

    private enum Mode { case move, resize }
    private var mode: Mode = .move
    private var startMouse: NSPoint = .zero
    private var startFrame: NSRect = .zero

    override var isFlipped: Bool { false }   // bottom-left origin, matches AppKit window coords

    // Only the border band and the grip are interactive; the interior passes
    // clicks through to whatever is underneath so the user keeps working.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let parent = superview else { return nil }
        let p = convert(point, from: parent)
        guard bounds.contains(p) else { return nil }
        if gripRect.contains(p) || nearBorder(p) { return self }
        return nil
    }

    private var gripRect: NSRect {
        NSRect(x: bounds.maxX - gripSize, y: bounds.minY, width: gripSize, height: gripSize)
    }

    private func nearBorder(_ p: NSPoint) -> Bool {
        p.x <= borderBand || p.x >= bounds.maxX - borderBand
            || p.y <= borderBand || p.y >= bounds.maxY - borderBand
    }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
        let local = convert(event.locationInWindow, from: nil)
        mode = gripRect.contains(local) ? .resize : .move
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - startMouse.x
        let dy = now.y - startMouse.y

        switch mode {
        case .move:
            var f = startFrame
            f.origin.x = startFrame.minX + dx
            f.origin.y = startFrame.minY + dy
            window.setFrame(f, display: true)
        case .resize:
            // Bottom-right grip: top edge fixed, right edge follows x, bottom edge
            // follows y. Enforce the minimum size.
            var f = startFrame
            let newW = max(EyeOverlayLimits.minWidth, startFrame.width + dx)
            let newMinY = min(startFrame.maxY - EyeOverlayLimits.minHeight, startFrame.minY + dy)
            f.size.width = newW
            f.origin.y = newMinY
            f.size.height = startFrame.maxY - newMinY
            window.setFrame(f, display: true)
        }
        onLiveChange?()
    }

    override func mouseUp(with event: NSEvent) {
        onCommit?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let inset: CGFloat = 1.5
        let r = bounds.insetBy(dx: inset, dy: inset)
        let path = CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil)

        // Faint interior tint so the frame is visible but you see through it.
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.85, blue: 0.95, alpha: 0.06))
        ctx.fillPath()

        // The "look here" border.
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(srgbRed: 0.10, green: 0.85, blue: 0.95, alpha: 0.9))
        ctx.setLineWidth(2.0)
        ctx.strokePath()

        // Bottom-right resize grip: two short corner ticks.
        let g = gripRect
        ctx.setStrokeColor(CGColor(srgbRed: 0.10, green: 0.85, blue: 0.95, alpha: 0.95))
        ctx.setLineWidth(2.0)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: g.maxX - 3, y: g.minY + 5))
        ctx.addLine(to: CGPoint(x: g.maxX - 3, y: g.minY + 3))
        ctx.addLine(to: CGPoint(x: g.maxX - 5, y: g.minY + 3))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: g.maxX - 3, y: g.minY + 11))
        ctx.addLine(to: CGPoint(x: g.maxX - 3, y: g.minY + 3))
        ctx.addLine(to: CGPoint(x: g.maxX - 11, y: g.minY + 3))
        ctx.strokePath()
    }
}

// Minimum size shared with the resize math (kept off the view so the static
// values do not depend on a live instance).
enum EyeOverlayLimits {
    static let minWidth: CGFloat = 160
    static let minHeight: CGFloat = 120
}
