import AppKit

/// Right-hand sidebar listing recent captures as clickable thumbnails.
final class HistoryPanel: NSView {
    private let onSelect: (URL, CGImage) -> Void
    private let stack = NSStackView()
    private let scroll = NSScrollView()

    init(onSelect: @escaping (URL, CGImage) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor

        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let flipped = FlippedStackContainer()
        flipped.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: flipped.topAnchor),
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: flipped.bottomAnchor),
        ])

        scroll.documentView = flipped
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(historyChanged),
            name: HistoryStore.changedNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        if let doc = scroll.documentView {
            doc.setFrameSize(NSSize(width: bounds.width, height: stack.fittingSize.height))
        }
    }

    @objc private func historyChanged() {
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for url in HistoryStore.shared.entries() {
            guard let thumb = HistoryStore.shared.thumbnail(at: url) else { continue }
            let button = HistoryThumbButton(image: thumb) { [weak self] in
                if let image = HistoryStore.shared.image(at: url) {
                    self?.onSelect(url, image)
                }
            }
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
            let ratio = thumb.size.height / max(thumb.size.width, 1)
            button.heightAnchor.constraint(equalTo: button.widthAnchor, multiplier: min(ratio, 1.4)).isActive = true
        }
        needsLayout = true
    }
}

private final class FlippedStackContainer: NSView {
    override var isFlipped: Bool { true }
}

private final class HistoryThumbButton: NSButton {
    private let onClick: () -> Void

    init(image: NSImage, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        self.image = image
        imageScaling = .scaleProportionallyUpOrDown
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.8, alpha: 1).cgColor
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func clicked() { onClick() }

    override func mouseEntered(with event: NSEvent) {
        layer?.borderColor = NSColor.systemOrange.cgColor
        layer?.borderWidth = 2
    }

    override func mouseExited(with event: NSEvent) {
        layer?.borderColor = NSColor(white: 0.8, alpha: 1).cgColor
        layer?.borderWidth = 1
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        ))
    }
}
