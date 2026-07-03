import AppKit

/// Floating always-on-top screenshot pins.
/// Drag to move, scroll to resize, double-click or Esc to close,
/// right-click for copy/close menu.
@MainActor
final class PinManager {
    static let shared = PinManager()
    private var panels: [PinPanel] = []

    func pin(image: CGImage) {
        let panel = PinPanel(image: image) { [weak self] panel in
            self?.panels.removeAll { $0 === panel }
        }
        panels.append(panel)
        panel.orderFrontRegardless()
    }

    /// Pins the current clipboard image, if any. Returns false when clipboard has no image.
    @discardableResult
    func pinFromClipboard() -> Bool {
        guard let data = NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: data),
              let image = rep.cgImage
        else { return false }
        pin(image: image)
        return true
    }
}

final class PinPanel: NSPanel {
    private let onClose: (PinPanel) -> Void
    private let image: CGImage
    private var aspect: CGFloat { CGFloat(image.height) / CGFloat(image.width) }

    @MainActor
    init(image: CGImage, onClose: @escaping (PinPanel) -> Void) {
        self.image = image
        self.onClose = onClose

        let screen = NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        var size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        if let visible = screen?.visibleFrame {
            let fit = min(1, visible.width * 0.6 / size.width, visible.height * 0.6 / size.height)
            size = CGSize(width: size.width * fit, height: size.height * fit)
        }
        let mouse = NSEvent.mouseLocation
        let origin = CGPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2)

        super.init(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let imageView = PinImageView(image: image)
        imageView.panel = self
        contentView = imageView
    }

    override var canBecomeKey: Bool { true }

    func closePin() {
        orderOut(nil)
        onClose(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closePin() } else { super.keyDown(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        let factor = 1 + event.scrollingDeltaY * 0.01
        var f = frame
        let newWidth = min(max(f.width * factor, 80), 3000)
        let newHeight = newWidth * aspect
        f.origin.x += (f.width - newWidth) / 2
        f.origin.y += (f.height - newHeight) / 2
        f.size = CGSize(width: newWidth, height: newHeight)
        setFrame(f, display: true)
    }

    func copyImage() {
        ExportService.shared.copyToClipboard(image)
    }
}

private final class PinImageView: NSView {
    weak var panel: PinPanel?
    private let cgImage: CGImage

    init(image: CGImage) {
        self.cgImage = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            panel?.closePin()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Close Pin", action: #selector(closeAction), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyAction() { panel?.copyImage() }
    @objc private func closeAction() { panel?.closePin() }
}
