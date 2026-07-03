import AppKit

/// Photoshop-style vertical tool palette.
@MainActor
final class ToolStrip: NSView {
    var onSelect: ((Tool) -> Void)?
    private var buttons: [ToolButton] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.965, alpha: 1).cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 5, bottom: 10, right: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for tool in Tool.allCases {
            let button = ToolButton(tool: tool) { [weak self] picked in
                self?.select(picked)
                self?.onSelect?(picked)
            }
            buttons.append(button)
            stack.addArrangedSubview(button)
        }

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        addSubview(divider)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func select(_ tool: Tool) {
        for button in buttons {
            button.isSelectedTool = button.tool == tool
        }
    }
}

private final class ToolButton: NSButton {
    let tool: Tool
    private let onPick: (Tool) -> Void

    var isSelectedTool = false {
        didSet {
            layer?.backgroundColor = isSelectedTool
                ? NSColor.systemOrange.cgColor
                : NSColor.clear.cgColor
            contentTintColor = isSelectedTool ? .white : NSColor(white: 0.28, alpha: 1)
        }
    }

    init(tool: Tool, onPick: @escaping (Tool) -> Void) {
        self.tool = tool
        self.onPick = onPick
        super.init(frame: .zero)
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.label)?
            .withSymbolConfiguration(config)
        contentTintColor = NSColor(white: 0.28, alpha: 1)
        toolTip = "\(tool.label)  (\(tool.key))"
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 34).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func clicked() { onPick(tool) }
}
