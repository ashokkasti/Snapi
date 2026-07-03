import AppKit

enum Tool: Int, CaseIterable {
    case select, arrow, line, rect, oval, pen, highlight, text, counter, blur, ruler, crop, picker

    var label: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rect: return "Rect"
        case .oval: return "Oval"
        case .pen: return "Pen"
        case .highlight: return "Highlight"
        case .text: return "Text"
        case .counter: return "1·2·3"
        case .blur: return "Blur"
        case .ruler: return "Ruler"
        case .crop: return "Crop"
        case .picker: return "Color"
        }
    }

    var key: String {
        switch self {
        case .select: return "V"
        case .arrow: return "A"
        case .line: return "L"
        case .rect: return "R"
        case .oval: return "O"
        case .pen: return "P"
        case .highlight: return "H"
        case .text: return "T"
        case .counter: return "N"
        case .blur: return "B"
        case .ruler: return "M"
        case .crop: return "K"
        case .picker: return "I"
        }
    }
}

/// One drawn annotation. Value type so undo is a plain array snapshot.
/// All coordinates are image-pixel space with top-left origin (flipped view coords).
struct Annotation {
    enum Shape {
        case arrow(from: CGPoint, to: CGPoint)
        case line(from: CGPoint, to: CGPoint)
        case rect(CGRect)
        case oval(CGRect)
        case pen(points: [CGPoint])
        case highlight(CGRect)
        case text(string: String, origin: CGPoint, fontSize: CGFloat)
        case counter(center: CGPoint, number: Int, label: String)
        case blur(CGRect)
        case ruler(from: CGPoint, to: CGPoint)
    }

    var shape: Shape
    var color: NSColor
    var lineWidth: CGFloat
    /// Text annotations: draw a filled rounded background behind the string.
    var textBackground: Bool = false
    /// Rect/oval: fill the shape with the color instead of stroking its border.
    var filled: Bool = false
    /// Counter annotations: label font size (text annotations keep theirs in the shape).
    var counterLabelSize: CGFloat = 36

    static func counterRadius(lineWidth: CGFloat) -> CGFloat {
        max(14, lineWidth * 4)
    }

    var counterLabel: String? {
        get {
            if case let .counter(_, _, label) = shape { return label }
            return nil
        }
        set {
            guard let newValue, case let .counter(center, number, _) = shape else { return }
            shape = .counter(center: center, number: number, label: newValue)
        }
    }

    var fontSize: CGFloat? {
        get {
            if case let .text(_, _, size) = shape { return size }
            if case .counter = shape { return counterLabelSize }
            return nil
        }
        set {
            guard let newValue else { return }
            if case let .text(string, origin, _) = shape {
                shape = .text(string: string, origin: origin, fontSize: newValue)
            } else if case .counter = shape {
                counterLabelSize = newValue
            }
        }
    }

    var boundingBox: CGRect {
        switch shape {
        case let .arrow(a, b), let .line(a, b), let .ruler(a, b):
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                .insetBy(dx: -8, dy: -8)
        case let .rect(r), let .oval(r), let .blur(r), let .highlight(r):
            return r.insetBy(dx: -8, dy: -8)
        case let .pen(points):
            guard let first = points.first else { return .zero }
            var box = CGRect(origin: first, size: .zero)
            for p in points { box = box.union(CGRect(origin: p, size: .zero)) }
            return box.insetBy(dx: -8, dy: -8)
        case let .text(string, origin, fontSize):
            let size = (string as NSString).size(withAttributes: [.font: annotationFont(size: fontSize)])
            return CGRect(origin: origin, size: size).insetBy(dx: -8, dy: -8)
        case let .counter(center, _, label):
            let radius = Annotation.counterRadius(lineWidth: lineWidth)
            let labelSize = (label as NSString).size(withAttributes: [
                .font: annotationFont(size: counterLabelSize),
            ])
            return CGRect(
                x: center.x - radius - 6,
                y: center.y - max(radius, labelSize.height / 2) - 6,
                width: radius * 2 + 12 + labelSize.width + 12,
                height: max(radius * 2, labelSize.height) + 12
            )
        }
    }

    mutating func translate(by delta: CGPoint) {
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + delta.x, y: p.y + delta.y) }
        switch shape {
        case let .arrow(a, b): shape = .arrow(from: move(a), to: move(b))
        case let .line(a, b): shape = .line(from: move(a), to: move(b))
        case let .ruler(a, b): shape = .ruler(from: move(a), to: move(b))
        case let .rect(r): shape = .rect(r.offsetBy(dx: delta.x, dy: delta.y))
        case let .oval(r): shape = .oval(r.offsetBy(dx: delta.x, dy: delta.y))
        case let .blur(r): shape = .blur(r.offsetBy(dx: delta.x, dy: delta.y))
        case let .highlight(r): shape = .highlight(r.offsetBy(dx: delta.x, dy: delta.y))
        case let .pen(points): shape = .pen(points: points.map(move))
        case let .text(s, origin, size): shape = .text(string: s, origin: move(origin), fontSize: size)
        case let .counter(center, n, label): shape = .counter(center: move(center), number: n, label: label)
        }
    }
}

/// Handwriting-style font for text annotations (bundled Caveat, Google Fonts OFL).
func annotationFont(size: CGFloat) -> NSFont {
    NSFont(name: "Caveat-Regular", size: size)
        ?? NSFont(name: "Caveat", size: size)
        ?? NSFont.boldSystemFont(ofSize: size)
}

/// Renders annotations into a CGContext whose coordinate space is
/// image pixels with top-left origin (i.e. a flipped context).
enum AnnotationRenderer {
    static func draw(_ annotations: [Annotation], in context: CGContext, baseImage: CGImage) {
        for annotation in annotations {
            draw(annotation, in: context, baseImage: baseImage)
        }
    }

    static func draw(_ a: Annotation, in context: CGContext, baseImage: CGImage) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(a.color.cgColor)
        context.setFillColor(a.color.cgColor)
        context.setLineWidth(a.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch a.shape {
        case let .line(from, to):
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()

        case let .arrow(from, to):
            drawArrow(from: from, to: to, lineWidth: a.lineWidth, in: context)

        case let .rect(r):
            if a.filled { context.fill(r) } else { context.stroke(r) }

        case let .oval(r):
            if a.filled { context.fillEllipse(in: r) } else { context.strokeEllipse(in: r) }

        case let .pen(points):
            strokePolyline(points, in: context)

        case let .highlight(r):
            context.setFillColor(a.color.withAlphaComponent(0.35).cgColor)
            context.fill(r)

        case let .text(string, origin, fontSize):
            drawText(
                string, at: origin, fontSize: fontSize, color: a.color,
                background: a.textBackground, in: context
            )

        case let .counter(center, number, label):
            // Numbered badge with an editable label to its right.
            let radius = Annotation.counterRadius(lineWidth: a.lineWidth)
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fillEllipse(in: circle)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(max(2, radius * 0.14))
            context.strokeEllipse(in: circle)

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

            let numberAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: radius * 1.1),
                .foregroundColor: NSColor.white,
            ]
            let numberString = "\(number)" as NSString
            let numberSize = numberString.size(withAttributes: numberAttributes)
            numberString.draw(
                at: CGPoint(x: center.x - numberSize.width / 2, y: center.y - numberSize.height / 2),
                withAttributes: numberAttributes
            )

            NSGraphicsContext.restoreGraphicsState()

            if !label.isEmpty {
                let labelHeight = (label as NSString).size(withAttributes: [
                    .font: annotationFont(size: a.counterLabelSize),
                ]).height
                drawText(
                    label,
                    at: CGPoint(x: circle.maxX + radius * 0.5, y: center.y - labelHeight / 2),
                    fontSize: a.counterLabelSize,
                    color: a.color,
                    background: a.textBackground,
                    in: context
                )
            }

        case let .blur(r):
            drawPixelated(rect: r, baseImage: baseImage, in: context)

        case let .ruler(from, to):
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()
            let distance = Int(hypot(to.x - from.x, to.y - from.y).rounded())
            let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            drawText("\(distance) px", at: mid, fontSize: 22, color: a.color, background: true, in: context)
        }
    }

    private static func strokePolyline(_ points: [CGPoint], in context: CGContext) {
        guard points.count > 1 else { return }
        context.move(to: points[0])
        for p in points.dropFirst() {
            context.addLine(to: p)
        }
        context.strokePath()
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, lineWidth: CGFloat, in context: CGContext) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLength = max(14, lineWidth * 5)
        let headAngle: CGFloat = .pi / 7
        let lineEnd = CGPoint(
            x: to.x - headLength * 0.6 * cos(angle),
            y: to.y - headLength * 0.6 * sin(angle)
        )
        context.move(to: from)
        context.addLine(to: lineEnd)
        context.strokePath()

        let p1 = CGPoint(x: to.x - headLength * cos(angle - headAngle), y: to.y - headLength * sin(angle - headAngle))
        let p2 = CGPoint(x: to.x - headLength * cos(angle + headAngle), y: to.y - headLength * sin(angle + headAngle))
        context.move(to: to)
        context.addLine(to: p1)
        context.addLine(to: p2)
        context.closePath()
        context.fillPath()
    }

    private static func drawText(
        _ string: String, at origin: CGPoint, fontSize: CGFloat, color: NSColor,
        background: Bool, in context: CGContext
    ) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: annotationFont(size: fontSize),
            .foregroundColor: color,
        ]
        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext
        if background {
            // Filled plate in the annotation color; text flips black/white by luminance.
            let size = (string as NSString).size(withAttributes: attributes)
            let padX = fontSize * 0.28
            let padY = fontSize * 0.10
            let plate = CGRect(
                x: origin.x - padX, y: origin.y - padY,
                width: size.width + padX * 2, height: size.height + padY * 2
            )
            let path = CGPath(
                roundedRect: plate,
                cornerWidth: min(10, plate.height * 0.25),
                cornerHeight: min(10, plate.height * 0.25),
                transform: nil
            )
            context.setFillColor(color.cgColor)
            context.addPath(path)
            context.fillPath()
            let rgb = color.usingColorSpace(.sRGB) ?? color
            let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
            attributes[.foregroundColor] = luminance > 0.6 ? NSColor.black : NSColor.white
        } else {
            attributes[.strokeColor] = NSColor.black.withAlphaComponent(0.5)
            attributes[.strokeWidth] = -2.0
        }
        (string as NSString).draw(at: origin, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawPixelated(rect: CGRect, baseImage: CGImage, in context: CGContext) {
        let clamped = rect.integral.intersection(CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height))
        guard !clamped.isEmpty, let cropped = baseImage.cropping(to: clamped) else { return }
        let blockSize: CGFloat = 14
        let smallW = max(1, Int(clamped.width / blockSize))
        let smallH = max(1, Int(clamped.height / blockSize))
        guard let small = CGContext(
            data: nil, width: smallW, height: smallH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        small.interpolationQuality = .low
        small.draw(cropped, in: CGRect(x: 0, y: 0, width: smallW, height: smallH))
        guard let smallImage = small.makeImage() else { return }

        context.saveGState()
        context.interpolationQuality = .none
        // Context is flipped (top-left origin); CGContext.draw expects bottom-left.
        context.translateBy(x: clamped.minX, y: clamped.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(smallImage, in: CGRect(x: 0, y: 0, width: clamped.width, height: clamped.height))
        context.restoreGState()
    }
}

/// Flattens the base image plus annotations into a single CGImage.
enum ImageFlattener {
    static func flatten(base: CGImage, annotations: [Annotation]) -> CGImage {
        guard !annotations.isEmpty else { return base }
        let width = base.width
        let height = base.height
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return base }
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Flip so annotation coords (top-left origin) render correctly.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        AnnotationRenderer.draw(annotations, in: context, baseImage: base)
        return context.makeImage() ?? base
    }
}
