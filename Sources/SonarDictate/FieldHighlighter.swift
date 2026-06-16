import AppKit
import ApplicationServices

// Draws a gold border around every field in the selector set so the user can
// see exactly what a dictation will broadcast to. Each highlight is a
// borderless, click-through, floating window positioned over the field's
// screen rect - so it shows even when the field's window is behind others
// ("see through my windows").
//
// Positions are read from the AX element (kAXPosition / kAXSize) and redrawn
// whenever the selector changes. v1 doesn't track live window moves/scrolls;
// the highlights refresh on the next selector mutation. A low-rate position
// refresh timer could be added later if drift is annoying.

final class FieldHighlighter {
    private var windows: [NSWindow] = []

    // Redraw highlights for the current target set.
    func update(targets: [SelectorEngine.Target]) {
        DispatchQueue.main.async {
            self.clearWindows()
            NSLog("SonarDictate.hl: update with \(targets.count) target(s)")
            for t in targets {
                guard let rect = Self.screenRect(of: t.element) else {
                    NSLog("SonarDictate.hl: NO screenRect for '\(t.label)' - AX position/size unavailable")
                    continue
                }
                NSLog("SonarDictate.hl: gold rect \(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height)) for '\(t.label)'")
                self.windows.append(self.makeHighlight(rect))
            }
            NSLog("SonarDictate.hl: \(self.windows.count) highlight window(s) live (screens=\(NSScreen.screens.count))")
        }
    }

    func clear() {
        DispatchQueue.main.async { self.clearWindows() }
    }

    // MARK: - Internals

    private func clearWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func makeHighlight(_ frame: NSRect) -> NSWindow {
        // Inset slightly and pad the border so it hugs the field cleanly.
        let w = NSWindow(contentRect: frame.insetBy(dx: -3, dy: -3),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.hasShadow = false

        let v = NSView(frame: NSRect(origin: .zero, size: w.frame.size))
        v.wantsLayer = true
        let gold = NSColor.systemYellow
        // Just the border - no interior fill. The field shows clean through the
        // transparent middle; only a gold outline hugs it all the way around.
        v.layer?.borderColor = gold.cgColor
        v.layer?.borderWidth = 2.5
        v.layer?.cornerRadius = 7
        v.layer?.backgroundColor = NSColor.clear.cgColor
        // Soft glow so the outline brightens up and reads through busy windows.
        v.layer?.shadowColor = gold.cgColor
        v.layer?.shadowRadius = 6
        v.layer?.shadowOpacity = 0.7
        v.layer?.shadowOffset = .zero
        w.contentView = v
        w.orderFront(nil)
        return w
    }

    // AX gives top-left (Quartz) coords; NSWindow wants bottom-left (Cocoa).
    static func screenRect(of element: AXUIElement) -> NSRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef
        else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaY = primaryHeight - pos.y - size.height
        return NSRect(x: pos.x, y: cocoaY, width: size.width, height: size.height)
    }
}
