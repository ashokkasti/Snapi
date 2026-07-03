import AppKit

@MainActor
protocol CanvasViewDelegate: AnyObject {
    func canvasDidPickColor(_ color: NSColor)
    func canvasDidChange()
    func canvasRequestsClose()
    func canvasSelectionChanged(_ index: Int?)
}

/// Annotation canvas. View coordinates == image pixel coordinates
/// (flipped, top-left origin), so cropping and blur math is 1:1.
final class CanvasView: NSView {
    let document: EditorDocument
    weak var delegate: CanvasViewDelegate?

    var tool: Tool = .arrow {
        didSet {
            if tool != .select, selectedIndex != nil {
                selectedIndex = nil
                needsDisplay = true
            }
        }
    }
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var fontSize: CGFloat = 36
    var textBackground = false
    var filled = false

    private var draft: Annotation?
    private var dragStart: CGPoint?
    private var draftPoints: [CGPoint] = []
    private var cropRect: CGRect?

    private(set) var selectedIndex: Int? {
        didSet {
            if oldValue != selectedIndex {
                delegate?.canvasSelectionChanged(selectedIndex)
            }
        }
    }
    private var lastDragPoint: CGPoint?
    private var didBeginTranslation = false

    var selectedAnnotation: Annotation? {
        guard let selectedIndex, document.annotations.indices.contains(selectedIndex) else { return nil }
        return document.annotations[selectedIndex]
    }

    /// Restyles the selected annotation (undoable) and repaints.
    func updateSelected(_ mutate: (inout Annotation) -> Void) {
        guard let selectedIndex else { return }
        document.updateAnnotation(at: selectedIndex, mutate)
        needsDisplay = true
        delegate?.canvasDidChange()
    }

    func clearSelection() {
        selectedIndex = nil
        needsDisplay = true
    }

    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    /// When set, the active text field edits this counter's label instead of creating a text annotation.
    private var editingCounterIndex: Int?

    /// Space-held hand-pan (Photoshop style): drag scrolls the clip view.
    private var isSpacePanning = false
    private var panLastScreenPoint: CGPoint?

    init(document: EditorDocument) {
        self.document = document
        super.init(frame: CGRect(origin: .zero, size: document.pixelSize))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func refreshSize() {
        setFrameSize(document.pixelSize)
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Base image: un-flip for CGContext.draw.
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(document.base, in: bounds)
        context.restoreGState()

        AnnotationRenderer.draw(document.annotations, in: context, baseImage: document.base)
        if let draft {
            AnnotationRenderer.draw(draft, in: context, baseImage: document.base)
        }

        if let selectedIndex, document.annotations.indices.contains(selectedIndex) {
            let box = document.annotations[selectedIndex].boundingBox
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [5, 4])
            context.stroke(box)
            context.setLineDash(phase: 0, lengths: [])
        }

        if let cropRect {
            context.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
            context.saveGState()
            context.addRect(bounds)
            context.addRect(cropRect)
            context.clip(using: .evenOdd)
            context.fill(bounds)
            context.restoreGState()
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1.5)
            context.stroke(cropRect)
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if isSpacePanning {
            panLastScreenPoint = event.locationInWindow
            NSCursor.closedHand.set()
            return
        }
        commitTextEditing()
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        draftPoints = [point]

        switch tool {
        case .select:
            selectedIndex = document.annotations.lastIndex { $0.boundingBox.contains(point) }
            lastDragPoint = point
            didBeginTranslation = false
            needsDisplay = true
            // Double-click a counter to edit its label.
            if event.clickCount == 2, let index = selectedIndex,
               let annotation = selectedAnnotation, annotation.counterLabel != nil {
                beginCounterLabelEditing(index: index, annotation: annotation)
            }
        case .text:
            beginTextEditing(at: point)
        case .counter:
            let number = document.counterValue
            let annotation = Annotation(
                shape: .counter(center: point, number: number, label: "Counter \(number) label"),
                color: color, lineWidth: lineWidth,
                textBackground: textBackground, counterLabelSize: fontSize
            )
            document.add(annotation)
            document.counterValue += 1
            changed()
            beginCounterLabelEditing(index: document.annotations.count - 1, annotation: annotation)
        case .picker:
            pickColor(at: point)
        default:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isSpacePanning {
            panBy(event: event)
            return
        }
        guard let start = dragStart else { return }
        var point = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)

        // Shift constrains: lines snap to 45° steps, boxes become squares/circles.
        if shift {
            switch tool {
            case .line, .arrow, .ruler:
                let dx = point.x - start.x
                let dy = point.y - start.y
                let length = hypot(dx, dy)
                let snapped = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
                point = CGPoint(x: start.x + length * cos(snapped), y: start.y + length * sin(snapped))
            case .rect, .oval, .blur, .highlight, .crop:
                let side = max(abs(point.x - start.x), abs(point.y - start.y))
                point = CGPoint(
                    x: start.x + side * (point.x >= start.x ? 1 : -1),
                    y: start.y + side * (point.y >= start.y ? 1 : -1)
                )
            default:
                break
            }
        }

        let rect = CGRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y)
        )

        switch tool {
        case .arrow:
            draft = Annotation(shape: .arrow(from: start, to: point), color: color, lineWidth: lineWidth)
        case .line:
            draft = Annotation(shape: .line(from: start, to: point), color: color, lineWidth: lineWidth)
        case .ruler:
            draft = Annotation(shape: .ruler(from: start, to: point), color: color, lineWidth: max(2, lineWidth / 2))
        case .rect:
            draft = Annotation(shape: .rect(rect), color: color, lineWidth: lineWidth, filled: filled)
        case .oval:
            draft = Annotation(shape: .oval(rect), color: color, lineWidth: lineWidth, filled: filled)
        case .blur:
            draft = Annotation(shape: .blur(rect), color: color, lineWidth: lineWidth)
        case .highlight:
            draft = Annotation(shape: .highlight(rect), color: color, lineWidth: lineWidth)
        case .pen:
            draftPoints.append(point)
            draft = Annotation(shape: .pen(points: draftPoints), color: color, lineWidth: lineWidth)
        case .crop:
            cropRect = rect
        case .select:
            guard let selectedIndex, let last = lastDragPoint else { break }
            if !didBeginTranslation {
                document.beginTranslation()
                didBeginTranslation = true
            }
            document.translateAnnotation(at: selectedIndex, by: CGPoint(x: point.x - last.x, y: point.y - last.y))
            lastDragPoint = point
        case .picker:
            pickColor(at: point)
        case .text, .counter:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            draftPoints = []
            lastDragPoint = nil
        }

        if isSpacePanning {
            panLastScreenPoint = nil
            NSCursor.openHand.set()
            return
        }

        if tool == .crop {
            if let rect = cropRect, rect.width > 8, rect.height > 8 {
                cropRect = nil
                document.crop(to: rect)
                refreshSize()
                changed()
            } else {
                cropRect = nil
                needsDisplay = true
            }
            return
        }

        if let draft {
            self.draft = nil
            if draft.boundingBox.width > 2 || draft.boundingBox.height > 2 {
                document.add(draft)
                changed()
            } else {
                needsDisplay = true
            }
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: // Space — enter hand-pan mode (ignore auto-repeat)
            if textField == nil, !event.isARepeat, !isSpacePanning {
                isSpacePanning = true
                NSCursor.openHand.set()
            }
        case 53: // Esc
            if textField != nil {
                cancelTextEditing()
            } else if cropRect != nil {
                cropRect = nil
                needsDisplay = true
            } else {
                delegate?.canvasRequestsClose()
            }
        case 51, 117: // Delete / Forward-delete
            if let selectedIndex {
                document.remove(at: selectedIndex)
                self.selectedIndex = nil
                changed()
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49, isSpacePanning {
            isSpacePanning = false
            panLastScreenPoint = nil
            NSCursor.arrow.set()
            window?.invalidateCursorRects(for: self)
        } else {
            super.keyUp(with: event)
        }
    }

    /// Scrolls the enclosing clip view to follow a space-drag.
    private func panBy(event: NSEvent) {
        guard let clip = enclosingScrollView?.contentView,
              let last = panLastScreenPoint else {
            panLastScreenPoint = event.locationInWindow
            return
        }
        let current = event.locationInWindow
        let dx = current.x - last.x
        let dy = current.y - last.y
        var origin = clip.bounds.origin
        // Flipped clip view: dragging right/up should reveal content to the left/down.
        origin.x -= dx
        origin.y += clip.isFlipped ? dy : -dy
        clip.scroll(to: origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
        panLastScreenPoint = current
    }

    // MARK: - Text editing

    private func beginTextEditing(at point: CGPoint) {
        textOrigin = point
        let field = NSTextField(frame: CGRect(x: point.x, y: point.y, width: 360, height: fontSize * 1.5))
        field.font = annotationFont(size: fontSize)
        field.textColor = color
        field.backgroundColor = NSColor.black.withAlphaComponent(0.25)
        field.isBordered = false
        field.focusRingType = .none
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    /// Opens the label editor beside a counter badge, prefilled and selected.
    private func beginCounterLabelEditing(index: Int, annotation: Annotation) {
        commitTextEditing()
        guard case let .counter(center, _, label) = annotation.shape else { return }
        let radius = Annotation.counterRadius(lineWidth: annotation.lineWidth)
        let size = annotation.counterLabelSize
        editingCounterIndex = index
        let field = NSTextField(frame: CGRect(
            x: center.x + radius + radius * 0.5,
            y: center.y - size * 0.75,
            width: 420, height: size * 1.5
        ))
        field.stringValue = label
        field.font = annotationFont(size: size)
        field.textColor = annotation.color
        field.backgroundColor = NSColor.black.withAlphaComponent(0.25)
        field.isBordered = false
        field.focusRingType = .none
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        textField = field
    }

    func commitTextEditing() {
        guard let field = textField else { return }
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        textField = nil
        if let index = editingCounterIndex {
            editingCounterIndex = nil
            document.updateAnnotation(at: index) { $0.counterLabel = string }
            changed()
        } else if !string.isEmpty {
            document.add(Annotation(
                shape: .text(string: string, origin: textOrigin, fontSize: fontSize),
                color: color, lineWidth: lineWidth, textBackground: textBackground
            ))
            changed()
        }
        window?.makeFirstResponder(self)
    }

    private func cancelTextEditing() {
        textField?.removeFromSuperview()
        textField = nil
        editingCounterIndex = nil
        window?.makeFirstResponder(self)
    }

    // MARK: - Color picking

    private func pickColor(at point: CGPoint) {
        guard let picked = document.base.pixelColor(
            x: Int(point.x), y: Int(point.y)
        ) else { return }
        delegate?.canvasDidPickColor(picked)
    }

    private func changed() {
        needsDisplay = true
        delegate?.canvasDidChange()
    }
}

extension CanvasView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitTextEditing()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTextEditing()
            return true
        }
        return false
    }
}

extension CGImage {
    /// Samples one pixel. Coordinates are top-left origin image pixels.
    func pixelColor(x: Int, y: Int) -> NSColor? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(self, in: CGRect(x: -x, y: y - height + 1, width: width, height: height))
        return NSColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }
}
