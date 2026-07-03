import AppKit

/// Floating property bar (Figma-style). Edits either the selected
/// annotation or the defaults for new ones.
@MainActor
final class PropBar: NSView {
    struct Props {
        var color: NSColor
        var lineWidth: CGFloat
        var fontSize: CGFloat
        var textBackground: Bool
        var filled: Bool = false
    }

    var onChange: ((Props) -> Void)?

    static let presets: [NSColor] = [
        .systemRed, .systemGreen, .systemBlue, .systemYellow, .white, .systemGray, .black,
    ]

    private var swatches: [SwatchButton] = []
    private var moreButton: NSButton!
    private var widthPopup: NSPopUpButton!
    private var fontPopup: NSPopUpButton!
    private var bgToggle: NSButton!
    private var fillToggle: NSButton!

    private(set) var props = Props(color: .systemRed, lineWidth: 4, fontSize: 36, textBackground: false)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.96).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.82, alpha: 1).cgColor
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.18).cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowRadius = 8
        layer?.shadowOpacity = 1

        for color in Self.presets {
            let swatch = SwatchButton(color: color) { [weak self] picked in
                self?.set(color: picked)
            }
            swatches.append(swatch)
        }

        moreButton = NSButton(title: "", target: self, action: #selector(openColorPanel))
        moreButton.isBordered = false
        moreButton.wantsLayer = true
        moreButton.layer?.cornerRadius = 8
        moreButton.toolTip = "More colors…"
        moreButton.image = rainbowImage(diameter: 22)
        moreButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        moreButton.heightAnchor.constraint(equalToConstant: 24).isActive = true

        widthPopup = NSPopUpButton()
        widthPopup.addItems(withTitles: ["2", "4", "6", "10"])
        widthPopup.selectItem(at: 1)
        widthPopup.target = self
        widthPopup.action = #selector(widthChanged)
        widthPopup.toolTip = "Stroke width"
        widthPopup.font = .systemFont(ofSize: 12)

        fontPopup = NSPopUpButton()
        fontPopup.addItems(withTitles: ["24", "36", "48", "64", "96"])
        fontPopup.selectItem(at: 1)
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged)
        fontPopup.toolTip = "Text size"
        fontPopup.font = .systemFont(ofSize: 12)

        bgToggle = NSButton(
            image: NSImage(systemSymbolName: "character.textbox", accessibilityDescription: "Text background")!,
            target: self,
            action: #selector(bgToggled)
        )
        bgToggle.setButtonType(.toggle)
        bgToggle.bezelStyle = .texturedRounded
        bgToggle.toolTip = "Text background plate"

        fillToggle = NSButton(
            image: NSImage(systemSymbolName: "square.fill", accessibilityDescription: "Fill shape")!,
            target: self,
            action: #selector(fillToggled)
        )
        fillToggle.setButtonType(.toggle)
        fillToggle.bezelStyle = .texturedRounded
        fillToggle.toolTip = "Fill shape (vs. outline)"

        let widthLabel = NSTextField(labelWithString: "line")
        widthLabel.font = .systemFont(ofSize: 11)
        widthLabel.textColor = .tertiaryLabelColor
        let fontLabel = NSTextField(labelWithString: "text")
        fontLabel.font = .systemFont(ofSize: 11)
        fontLabel.textColor = .tertiaryLabelColor

        func separator() -> NSView {
            let line = NSBox()
            line.boxType = .separator
            line.translatesAutoresizingMaskIntoConstraints = false
            line.widthAnchor.constraint(equalToConstant: 1).isActive = true
            line.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return line
        }

        let stack = NSStackView(views: swatches + [
            moreButton,
            separator(),
            widthLabel, widthPopup, fillToggle,
            separator(),
            fontLabel, fontPopup, bgToggle,
        ])
        stack.orientation = .horizontal
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 11, left: 18, bottom: 11, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        refreshSwatchSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Reflect an existing annotation's props (or defaults when nil).
    func load(_ annotation: Annotation?) {
        if let annotation {
            props.color = annotation.color
            props.lineWidth = annotation.lineWidth
            props.textBackground = annotation.textBackground
            props.filled = annotation.filled
            if let size = annotation.fontSize {
                props.fontSize = size
            }
        }
        let widths: [CGFloat] = [2, 4, 6, 10]
        widthPopup.selectItem(at: widths.firstIndex(of: props.lineWidth) ?? 1)
        let sizes: [CGFloat] = [24, 36, 48, 64, 96]
        fontPopup.selectItem(at: sizes.firstIndex(of: props.fontSize) ?? 1)
        bgToggle.state = props.textBackground ? .on : .off
        fillToggle.state = props.filled ? .on : .off
        refreshSwatchSelection()
    }

    /// Externally set the current color (e.g. from the eyedropper) without firing onChange.
    func adoptColor(_ color: NSColor) {
        props.color = color
        refreshSwatchSelection()
    }

    // MARK: - Actions

    private func set(color: NSColor) {
        props.color = color
        refreshSwatchSelection()
        onChange?(props)
    }

    @objc private func openColorPanel() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.color = props.color
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        set(color: sender.color)
    }

    @objc private func widthChanged() {
        props.lineWidth = [2, 4, 6, 10][max(0, widthPopup.indexOfSelectedItem)]
        onChange?(props)
    }

    @objc private func fontChanged() {
        props.fontSize = [24, 36, 48, 64, 96][max(0, fontPopup.indexOfSelectedItem)]
        onChange?(props)
    }

    @objc private func bgToggled() {
        props.textBackground = bgToggle.state == .on
        onChange?(props)
    }

    @objc private func fillToggled() {
        props.filled = fillToggle.state == .on
        onChange?(props)
    }

    private func refreshSwatchSelection() {
        for swatch in swatches {
            swatch.isSelected = swatch.color.isClose(to: props.color)
        }
    }

    private func rainbowImage(diameter: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2
            for (i, color) in colors.enumerated() {
                let start = CGFloat(i) / CGFloat(colors.count) * 360
                let end = CGFloat(i + 1) / CGFloat(colors.count) * 360
                let path = NSBezierPath()
                path.move(to: center)
                path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end)
                path.close()
                color.setFill()
                path.fill()
            }
            return true
        }
    }
}

private final class SwatchButton: NSButton {
    let color: NSColor
    private let onPick: (NSColor) -> Void

    var isSelected = false {
        didSet {
            layer?.borderWidth = isSelected ? 2.5 : 1
            layer?.borderColor = isSelected
                ? NSColor.systemOrange.cgColor
                : NSColor(white: 0.75, alpha: 1).cgColor
        }
    }

    init(color: NSColor, onPick: @escaping (NSColor) -> Void) {
        self.color = color
        self.onPick = onPick
        super.init(frame: .zero)
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 11
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.75, alpha: 1).cgColor
        target = self
        action = #selector(clicked)
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func clicked() { onPick(color) }
}

extension NSColor {
    func isClose(to other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.02
            && abs(a.greenComponent - b.greenComponent) < 0.02
            && abs(a.blueComponent - b.blueComponent) < 0.02
    }
}
