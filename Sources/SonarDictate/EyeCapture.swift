import AppKit
import CoreGraphics
import ScreenCaptureKit

// The eyes' capture stage: grab the screen region under the eye frame to a
// CGImage, on-device, via ScreenCaptureKit. Phase 1 is a one-shot per 3s
// heartbeat (the SCStream rolling replay buffer is Phase 3).
//
// Permission: the first SCShareableContent call triggers the Screen Recording
// TCC prompt. If denied (or capture returns nothing), this throws and the loop
// surfaces a "grant Screen Recording" status; nothing leaks.
//
// PHI: the returned CGImage is the user's screen - sensitive. It lives in memory,
// is consumed by OCR, and is dropped. It is never written to disk, never logged.
@available(macOS 14.0, *)
enum EyeCapture {
    enum CaptureError: Error { case noDisplay }

    // region: rect in GLOBAL AppKit screen coordinates (bottom-left origin, y up),
    // i.e. an NSWindow.frame. Returns a CGImage of just that region from the
    // display it sits on (Phase 1 targets the main display).
    static func capture(region: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        // The NSScreen backing this display gives us the point-space frame (for the
        // y-flip) and the backing scale (for crisp OCR pixels).
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        } ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2.0
        let screenFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))

        // Flip AppKit global (bottom-left origin) -> SCK display space (top-left
        // origin, points). sourceRect is in points relative to the display.
        let local = CGRect(
            x: region.minX - screenFrame.minX,
            y: screenFrame.maxY - region.maxY,
            width: region.width,
            height: region.height
        )

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = max(1, Int(region.width * scale))
        config.height = max(1, Int(region.height * scale))
        config.showsCursor = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
