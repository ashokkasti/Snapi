import AppKit
import ScreenCaptureKit

struct DisplayCapture {
    let screen: NSScreen
    let image: CGImage
}

enum CaptureError: Error {
    case noDisplay
    case noPermission
}

/// ScreenCaptureKit wrapper. Captures full-resolution frozen frames of displays.
final class CaptureEngine {
    /// Captures every connected display at native pixel resolution.
    func captureAllDisplays() async throws -> [DisplayCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var results: [DisplayCapture] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID })
            else { continue }
            let image = try await capture(display: display)
            results.append(DisplayCapture(screen: screen, image: image))
        }
        guard !results.isEmpty else { throw CaptureError.noDisplay }
        return results
    }

    /// Captures the display currently containing the mouse cursor.
    func captureDisplayUnderMouse() async throws -> DisplayCapture {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen, let displayID = screen.displayID else { throw CaptureError.noDisplay }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplay
        }
        let image = try await capture(display: display)
        return DisplayCapture(screen: screen, image: image)
    }

    /// Captures a region of a display. `rect` is in display-local points, top-left origin.
    func captureRegion(displayID: CGDirectDisplayID, rect: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = regionConfiguration(rect: rect, scale: CGFloat(filter.pointPixelScale))
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Prepares a reusable capturer for repeated shots of one region. The
    /// shareable-content lookup and filter are built once, so each shot is a
    /// single screenshot call. Snapi's own windows (dim overlay, HUD) are
    /// excluded. `rect` is in display-local points, top-left origin.
    func makeRegionCapturer(displayID: CGDirectDisplayID, rect: CGRect) async throws -> RegionCapturer {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplay
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == myPID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = regionConfiguration(rect: rect, scale: CGFloat(filter.pointPixelScale))
        return RegionCapturer(filter: filter, config: config)
    }

    /// Region config snapped to whole device pixels. Selection rects from mouse
    /// drags are fractional; passing them through makes ScreenCaptureKit
    /// resample the frame, which comes out visibly blurry. Snapped, pixels are
    /// copied 1:1.
    private func regionConfiguration(rect: CGRect, scale: CGFloat) -> SCStreamConfiguration {
        let x = (rect.minX * scale).rounded()
        let y = (rect.minY * scale).rounded()
        let width = max(1, (rect.width * scale).rounded())
        let height = max(1, (rect.height * scale).rounded())
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: x / scale, y: y / scale, width: width / scale, height: height / scale)
        config.width = Int(width)
        config.height = Int(height)
        config.scalesToFit = false
        config.captureResolution = .best
        config.showsCursor = false
        return config
    }

    /// Captures a single window at native resolution (no shadow).
    func captureWindow(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.captureResolution = .best
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// On-screen, normal-layer windows suitable for window capture, front-to-back.
    func selectableWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let myPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { window in
            window.windowLayer == 0 &&
            window.frame.width > 40 && window.frame.height > 40 &&
            window.owningApplication?.processID != pid_t(myPID)
        }
    }

    private func capture(display: SCDisplay) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.captureResolution = .best
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

/// Pre-built filter + configuration for repeated captures of one region.
final class RegionCapturer {
    private let filter: SCContentFilter
    private let config: SCStreamConfiguration

    init(filter: SCContentFilter, config: SCStreamConfiguration) {
        self.filter = filter
        self.config = config
    }

    func capture() async throws -> CGImage {
        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
