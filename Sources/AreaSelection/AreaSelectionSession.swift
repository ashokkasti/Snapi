import AppKit

struct AreaSelectionResult {
    let image: CGImage
    /// Selection in screen-local points, bottom-left origin (view coords).
    let viewRect: CGRect
    let screen: NSScreen

    /// Selection in display-local points, top-left origin (ScreenCaptureKit sourceRect space).
    var displayRect: CGRect {
        CGRect(
            x: viewRect.minX,
            y: screen.frame.height - viewRect.maxY,
            width: viewRect.width,
            height: viewRect.height
        )
    }
}

/// Coordinates the frozen-screen area selection across all displays.
/// Shows one overlay window per screen; the first view to receive a drag
/// owns the selection. Esc anywhere cancels.
@MainActor
final class AreaSelectionSession {
    private var windows: [OverlayWindow] = []
    private let captures: [DisplayCapture]
    private let completion: (AreaSelectionResult?) -> Void
    private var finished = false

    init(captures: [DisplayCapture], completion: @escaping (AreaSelectionResult?) -> Void) {
        self.captures = captures
        self.completion = completion
    }

    func begin() {
        for capture in captures {
            let window = OverlayWindow(capture: capture, session: self)
            windows.append(window)
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        // Key window follows the mouse so Esc works immediately.
        let mouse = NSEvent.mouseLocation
        let target = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
        target?.makeKey()
    }

    func complete(with result: AreaSelectionResult?) {
        guard !finished else { return }
        finished = true
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        completion(result)
    }

    func cancel() {
        complete(with: nil)
    }
}
