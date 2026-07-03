import AppKit

/// Renders the frozen screen, dims it, and lets the user drag a selection.
/// Drag → crop → session completes. Esc → cancel.
final class SelectionView: NSView {
    private let capture: DisplayCapture
    private weak var session: AreaSelectionSession?

    private var dragOrigin: CGPoint?
    private var selectionRect: CGRect?
    private var mousePosition: CGPoint?

    private let dimAlpha: CGFloat = 0.4
    private let minSelectionSize: CGFloat = 4

    @MainActor
    init(capture: DisplayCapture, session: AreaSelectionSession) {
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
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        mousePosition = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        selectionRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let current = convert(event.locationInWindow, from: nil)
        selectionRect = CGRect(
            x: min(origin.x, current.x),
            y: min(origin.y, current.y),
            width: abs(current.x - origin.x),
            height: abs(current.y - origin.y)
        )
        mousePosition = current
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil }
        guard let rect = selectionRect,
              rect.width >= minSelectionSize, rect.height >= minSelectionSize,
              let cropped = crop(to: rect)
        else {
            session?.cancel()
            return
        }
        session?.complete(with: AreaSelectionResult(image: cropped, viewRect: rect, screen: capture.screen))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            session?.cancel()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Cropping

    private func crop(to viewRect: CGRect) -> CGImage? {
        let image = capture.image
        let scaleX = CGFloat(image.width) / bounds.width
        let scaleY = CGFloat(image.height) / bounds.height
        // View origin is bottom-left; CGImage origin is top-left.
        let pixelRect = CGRect(
            x: viewRect.minX * scaleX,
            y: (bounds.height - viewRect.maxY) * scaleY,
            width: viewRect.width * scaleX,
            height: viewRect.height * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixelRect.isEmpty else { return nil }
        return image.cropping(to: pixelRect)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Frozen screen frame.
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(capture.image, in: bounds)
        context.restoreGState()

        // Dim everything outside the selection.
        context.setFillColor(NSColor.black.withAlphaComponent(dimAlpha).cgColor)
        if let selection = selectionRect {
            context.saveGState()
            context.addRect(bounds)
            context.addRect(selection)
            context.clip(using: .evenOdd)
            context.fill(bounds)
            context.restoreGState()
            drawSelectionChrome(selection, in: context)
        } else {
            context.fill(bounds)
            if let mouse = mousePosition {
                drawCrosshair(at: mouse, in: context)
            }
        }
    }

    private func drawSelectionChrome(_ rect: CGRect, in context: CGContext) {
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(rect.insetBy(dx: -0.5, dy: -0.5))

        // Size label in device pixels.
        let scale = CGFloat(capture.image.width) / bounds.width
        let label = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        let padding: CGFloat = 5
        var origin = CGPoint(x: rect.minX, y: rect.minY - size.height - padding * 2 - 4)
        if origin.y < 0 { origin.y = rect.minY + 4 }
        let background = CGRect(
            x: origin.x, y: origin.y,
            width: size.width + padding * 2, height: size.height + padding * 2
        )
        let path = CGPath(roundedRect: background, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        context.addPath(path)
        context.fillPath()
        label.draw(at: CGPoint(x: origin.x + padding, y: origin.y + padding), withAttributes: attributes)
    }

    private func drawCrosshair(at point: CGPoint, in context: CGContext) {
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: point.x, y: 0))
        context.addLine(to: CGPoint(x: point.x, y: bounds.height))
        context.move(to: CGPoint(x: 0, y: point.y))
        context.addLine(to: CGPoint(x: bounds.width, y: point.y))
        context.strokePath()
    }
}
