import AppKit
import ScreenCaptureKit

/// Window capture: frozen displays with hover-highlighted windows.
/// Click captures the highlighted window; Esc cancels.
@MainActor
final class WindowSelectionSession {
    private var windows: [NSWindow] = []
    private let captures: [DisplayCapture]
    private let candidates: [SCWindow]
    private let completion: (SCWindow?) -> Void
    private var finished = false

    init(captures: [DisplayCapture], candidates: [SCWindow], completion: @escaping (SCWindow?) -> Void) {
        self.captures = captures
        self.candidates = candidates
        self.completion = completion
    }

    func begin() {
        for capture in captures {
            let overlay = WindowPickOverlay(capture: capture, session: self)
            windows.append(overlay)
            overlay.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        let target = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
        target?.makeKey()
    }

    /// Topmost candidate window containing a global CG point (top-left origin).
    func window(atCGPoint point: CGPoint) -> SCWindow? {
        candidates.first { $0.frame.contains(point) }
    }

    func complete(with window: SCWindow?) {
        guard !finished else { return }
        finished = true
        for overlay in windows {
            overlay.orderOut(nil)
        }
        windows.removeAll()
        completion(window)
    }

    func cancel() {
        complete(with: nil)
    }
}

private final class WindowPickOverlay: NSWindow {
    @MainActor
    init(capture: DisplayCapture, session: WindowSelectionSession) {
        super.init(
            contentRect: capture.screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = WindowPickView(capture: capture, session: session)
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
}

private final class WindowPickView: NSView {
    private let capture: DisplayCapture
    private weak var session: WindowSelectionSession?
    private var highlighted: SCWindow?

    @MainActor
    init(capture: DisplayCapture, session: WindowSelectionSession) {
        self.capture = capture
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        updateTrackingAreas()
        updateHighlight(for: NSEvent.mouseLocation)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHighlight(for: NSEvent.mouseLocation)
    }

    private func updateHighlight(for globalAppKitPoint: CGPoint) {
        let primaryHeight = NSScreen.screens[0].frame.height
        let cgPoint = CGPoint(x: globalAppKitPoint.x, y: primaryHeight - globalAppKitPoint.y)
        highlighted = session?.window(atCGPoint: cgPoint)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        session?.complete(with: highlighted)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            session?.cancel()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Converts a global CG rect (top-left origin) to this view's coords (bottom-left origin, screen-local).
    private func viewRect(fromCGRect rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens[0].frame.height
        let globalAppKit = CGRect(
            x: rect.minX,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        return CGRect(
            x: globalAppKit.minX - capture.screen.frame.minX,
            y: globalAppKit.minY - capture.screen.frame.minY,
            width: globalAppKit.width,
            height: globalAppKit.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(capture.image, in: bounds)
        context.restoreGState()

        context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        if let highlighted {
            let rect = viewRect(fromCGRect: highlighted.frame)
            context.saveGState()
            context.addRect(bounds)
            context.addRect(rect)
            context.clip(using: .evenOdd)
            context.fill(bounds)
            context.restoreGState()
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(3)
            context.stroke(rect)
        } else {
            context.fill(bounds)
        }
    }
}
