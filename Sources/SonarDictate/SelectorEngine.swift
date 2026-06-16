import AppKit
import ApplicationServices

// Tracks the set of target fields a dictation broadcasts to.
//
// The user builds the set up by clicking fields while holding the dictation
// key (or ControlOptionL to add the focused field). The set PERSISTS until removed/wiped,
// so you can set up your N agent inputs once and fire many prompts at all of
// them. On dictation release, the Dictator writes the transcript to every
// target via writeToLocked() (AX value-set, focus+inject fallback).
//
// This class only owns selection state + AX element discovery. The actual
// write lives in the Dictator so it can reuse the single-field path.

final class SelectorEngine {
    struct Target {
        let element: AXUIElement
        let appName: String
        let label: String
        // The exact screen point (Cocoa, bottom-left) the user clicked to add
        // this target. This is the RELIABLE focus anchor: the captured AX
        // element is flaky in Electron/web apps (returns toolbar junk), but the
        // click point is, by definition, on the real input. nil for ControlOptionL adds
        // (focused element, no click). Broadcast clicks here to focus, then types.
        let clickPoint: CGPoint?
    }

    private(set) var targets: [Target] = []

    var isEmpty: Bool { targets.isEmpty }
    var count: Int { targets.count }
    var summary: String {
        targets.isEmpty ? "no targets"
            : targets.map { $0.label }.joined(separator: ", ")
    }

    // Add the editable element at a screen point (from a click while the
    // dictation key is held). Y is expected in Cocoa (bottom-left) coords;
    // we flip it to Quartz top-left for the AX hit-test. Returns the label
    // if a new editable element was added, else nil.
    @discardableResult
    func addElement(atCocoaPoint cocoa: CGPoint) -> String? {
        // Flip against the primary display height (screens[0]). Multi-monitor
        // setups with displays above/left of primary need fuller handling;
        // v1 assumes the common single/right-of-primary arrangement.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? cocoa.y
        let quartz = CGPoint(x: cocoa.x, y: primaryHeight - cocoa.y)

        let system = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(system, Float(quartz.x), Float(quartz.y), &elementRef)
        guard err == .success, let element = elementRef else { return nil }
        return addIfEditable(element, clickPoint: cocoa)
    }

    // Add the currently system-focused element (ControlOptionL gesture).
    @discardableResult
    func addFocused() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        return addIfEditable(focused as! AXUIElement, clickPoint: nil)
    }

    func removeLast() {
        if !targets.isEmpty { targets.removeLast() }
    }

    func wipe() {
        targets.removeAll()
    }

    // MARK: - Internals

    private func addIfEditable(_ element: AXUIElement, clickPoint: CGPoint?) -> String? {
        guard isEditable(element) else { return nil }
        // Dedup: click-adds by point proximity (two web inputs in the same app
        // can return the SAME flaky AX element, so element-equality would wrongly
        // collapse them - the click point is what distinguishes them); focus-adds
        // by element identity.
        if let cp = clickPoint {
            if targets.contains(where: { t in
                guard let ep = t.clickPoint else { return false }
                return hypot(ep.x - cp.x, ep.y - cp.y) < 8
            }) { return nil }
        } else if targets.contains(where: { CFEqual($0.element, element) }) {
            return nil
        }
        let app = appName(of: element)
        let label = fieldLabel(of: element) ?? app
        targets.append(Target(element: element, appName: app, label: label, clickPoint: clickPoint))
        return label
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""
        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
        ]
        if editableRoles.contains(role) { return true }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue
    }

    private func appName(of element: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "app"
    }

    private func fieldLabel(of element: AXUIElement) -> String? {
        for attr in [kAXTitleAttribute, kAXPlaceholderValueAttribute, kAXDescriptionAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
               let s = ref as? String, !s.isEmpty {
                return s
            }
        }
        return nil
    }
}
