import AppKit

/// Scrolling capture: after area selection, samples the region on a timer
/// while the user scrolls, stitches frames, then hands the tall image on.
@MainActor
final class ScrollCaptureController {
    private let engine: CaptureEngine
    private let displayID: CGDirectDisplayID
    private let displayRect: CGRect
    private let screen: NSScreen
    private let completion: (CGImage?) -> Void

    private let stitcher = Stitcher()
    private var timer: Timer?
    private var borderWindow: NSWindow?
    private var controlPanel: NSPanel?
    private var capturing = false
    private var finished = false

    init(
        engine: CaptureEngine,
        displayID: CGDirectDisplayID,
        displayRect: CGRect,
        screen: NSScreen,
        completion: @escaping (CGImage?) -> Void
    ) {
        self.engine = engine
        self.displayID = displayID
        self.displayRect = displayRect
        self.screen = screen
        self.completion = completion
    }

    func start() {
        showBorder()
        showControlPanel()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.captureFrame()
            }
        }
        captureFrame()
    }

    private func captureFrame() {
        guard !capturing, !finished else { return }
        capturing = true
        Task { @MainActor in
            defer { capturing = false }
            do {
                let frame = try await engine.captureRegion(displayID: displayID, rect: displayRect)
                stitcher.add(frame)
            } catch {
                NSLog("Snapi: scroll frame capture failed: \(error)")
            }
        }
    }

    private func finish(cancelled: Bool) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        borderWindow?.orderOut(nil)
        borderWindow = nil
        controlPanel?.orderOut(nil)
        controlPanel = nil
        completion(cancelled ? nil : stitcher.assemble())
    }

    @objc private func doneTapped() { finish(cancelled: false) }
    @objc private func cancelTapped() { finish(cancelled: true) }

    // MARK: - Chrome

    /// Border sits strictly OUTSIDE the capture region so it never
    /// appears in the stitched frames.
    private func showBorder() {
        // displayRect is display-local, top-left origin → convert to global AppKit coords.
        let screenFrame = screen.frame
        let appKitRect = CGRect(
            x: screenFrame.minX + displayRect.minX,
            y: screenFrame.minY + (screenFrame.height - displayRect.maxY),
            width: displayRect.width,
            height: displayRect.height
        )
        let margin: CGFloat = 4
        let window = NSWindow(
            contentRect: appKitRect.insetBy(dx: -margin, dy: -margin),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false

        let border = NSView()
        border.wantsLayer = true
        border.layer?.borderColor = NSColor.systemOrange.cgColor
        border.layer?.borderWidth = 3
        window.contentView = border
        window.orderFrontRegardless()
        borderWindow = window
    }

    private func showControlPanel() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Scrolling capture"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let label = NSTextField(labelWithString: "Scroll the content, then press Done")
        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded

        let stack = NSStackView(views: [label, done, cancel])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)

        // Place above the region, or below when there is no room.
        let screenFrame = screen.frame
        let regionTopAppKit = screenFrame.minY + (screenFrame.height - displayRect.minY)
        let regionBottomAppKit = screenFrame.minY + (screenFrame.height - displayRect.maxY)
        var origin = CGPoint(
            x: screenFrame.minX + displayRect.midX - stack.fittingSize.width / 2,
            y: regionTopAppKit + 12
        )
        if origin.y + 60 > screenFrame.maxY {
            origin.y = regionBottomAppKit - 70
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        controlPanel = panel
    }
}
