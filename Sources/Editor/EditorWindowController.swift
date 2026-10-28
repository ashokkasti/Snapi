import AppKit

extension Tool {
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .oval: return "circle"
        case .pen: return "scribble"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .blur: return "checkerboard.rectangle"
        case .ruler: return "ruler"
        case .crop: return "crop"
        case .picker: return "eyedropper"
        }
    }
}

/// Post-capture annotation editor window.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [EditorWindowController] = []

    static var hasOpenEditors: Bool { !openControllers.isEmpty }

    private let editorDocument: EditorDocument
    private var canvas: CanvasView!
    private var scrollView: NSScrollView!
    private var toolStrip: ToolStrip!
    private var propBar: PropBar!
    private var statusLabel: NSTextField!
    private var historyPanel: HistoryPanel!
    private var historyWidth: NSLayoutConstraint!
    /// History entry backing this editor; annotated output is written back to it.
    private var historyURL: URL?

    static func present(image: CGImage, historyURL: URL? = nil) {
        // Reuse the existing editor window when one is open.
        if let existing = openControllers.last {
            existing.adopt(image: image, historyURL: historyURL)
            return
        }
        let controller = EditorWindowController(image: image)
        controller.historyURL = historyURL
        openControllers.append(controller)
        // Give the app a Dock/⌘Tab presence while editors are open.
        NSApp.setActivationPolicy(.regular)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Demo support (README GIF generation)

    static func demoController() -> EditorWindowController? {
        openControllers.last
    }

    func injectDemo(annotations: [Annotation]) {
        editorDocument.reset(base: editorDocument.base)
        for annotation in annotations {
            editorDocument.add(annotation)
        }
        canvas.refreshSize()
    }

    func snapshotWindow() -> CGImage? {
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// Loads a new capture into this window, preserving the previous
    /// entry's annotations in history first.
    private func adopt(image: CGImage, historyURL: URL?) {
        canvas.commitTextEditing()
        if !editorDocument.annotations.isEmpty {
            syncHistory()
        }
        self.historyURL = historyURL
        editorDocument.reset(base: image)
        canvas.clearSelection()
        canvas.refreshSize()
        historyPanel.reload()
        sizeWindowToImage()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(image: CGImage) {
        self.editorDocument = EditorDocument(base: image)
        let window = EditorWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Snapi"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua)
        window.minSize = NSSize(width: 840, height: 560)
        super.init(window: window)
        window.delegate = self
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        buildUI()
        sizeWindowToImage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - UI

    private func buildUI() {
        canvas = CanvasView(document: editorDocument)
        canvas.delegate = self

        scrollView = EditorScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true          // only show scrollers when needed
        scrollView.scrollerStyle = .overlay           // floating, no permanent gutter
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 8
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.93, alpha: 1)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        historyPanel = HistoryPanel { [weak self] url, image in
            self?.loadFromHistory(url: url, image: image)
        }
        historyPanel.translatesAutoresizingMaskIntoConstraints = false

        let header = buildHeader()
        header.translatesAutoresizingMaskIntoConstraints = false

        propBar = PropBar()
        propBar.translatesAutoresizingMaskIntoConstraints = false
        propBar.onChange = { [weak self] props in
            self?.applyProps(props)
        }

        toolStrip = ToolStrip()
        toolStrip.translatesAutoresizingMaskIntoConstraints = false
        toolStrip.onSelect = { [weak self] tool in
            self?.canvas.commitTextEditing()
            self?.canvas.tool = tool
        }
        toolStrip.select(.arrow)

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(historyPanel)
        container.addSubview(toolStrip)
        container.addSubview(header)
        container.addSubview(propBar)
        historyWidth = historyPanel.widthAnchor.constraint(equalToConstant: 128) // open by default
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),
            toolStrip.topAnchor.constraint(equalTo: header.bottomAnchor),
            toolStrip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolStrip.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            toolStrip.widthAnchor.constraint(equalToConstant: 44),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: toolStrip.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            historyPanel.topAnchor.constraint(equalTo: header.bottomAnchor),
            historyPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            historyPanel.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            historyPanel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            historyWidth,
            // Keep autolayout from collapsing the window to its fitting size.
            scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 640),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 480),
            propBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            propBar.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
        ])
        window?.contentView = container
    }

    private func buildHeader() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .headerView
        effect.blendingMode = .withinWindow
        effect.state = .active

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        func iconButton(_ symbol: String, _ action: Selector, tip: String) -> NSButton {
            let button = NSButton(image: symbolImage(symbol, size: 13), target: self, action: action)
            button.bezelStyle = .texturedRounded
            button.toolTip = tip
            button.contentTintColor = NSColor(white: 0.25, alpha: 1)
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            return button
        }

        // Secondary actions collapse into one "…" pull-down.
        let moreMenu = NSMenu()
        func moreItem(_ title: String, _ symbol: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = symbolImage(symbol, size: 13)
            moreMenu.addItem(item)
        }
        moreItem("Copy Text (OCR)", "text.viewfinder", #selector(copyText))
        moreItem("Remove Background", "person.and.background.dotted", #selector(removeBackground))
        moreItem("Pin  ⌘D", "pin", #selector(pin))
        let moreButton = NSPopUpButton()
        moreButton.pullsDown = true
        moreButton.bezelStyle = .texturedRounded
        moreButton.toolTip = "More actions"
        moreButton.menu = moreMenu
        moreMenu.insertItem(NSMenuItem(), at: 0) // pull-down title slot
        (moreButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        moreButton.insertItem(withTitle: "", at: 0)
        moreButton.item(at: 0)?.image = symbolImage("ellipsis.circle", size: 13)
        moreButton.widthAnchor.constraint(equalToConstant: 36).isActive = true

        let appTitle = NSTextField(labelWithString: "Snapi")
        appTitle.font = .systemFont(ofSize: 14, weight: .bold)
        appTitle.textColor = .labelColor
        let appTagline = NSTextField(labelWithString: "Snap · annotate · share")
        appTagline.font = .systemFont(ofSize: 10, weight: .regular)
        appTagline.textColor = .tertiaryLabelColor
        let titleStack = NSStackView(views: [appTitle, appTagline])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 0

        let stack = NSStackView(views: [
            titleStack,
            iconButton("arrow.uturn.backward", #selector(undo), tip: "Undo  ⌘Z"),
            iconButton("arrow.uturn.forward", #selector(redo), tip: "Redo  ⇧⌘Z"),
            statusLabel,
            moreButton,
            iconButton("clock.arrow.circlepath", #selector(toggleHistory), tip: "History"),
            iconButton("doc.on.doc", #selector(copyImage), tip: "Copy & close  ⌘C"),
            iconButton("square.and.arrow.down", #selector(save), tip: "Save  ⌘S"),
        ])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 76, bottom: 0, right: 10) // clear the traffic lights
        stack.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
        return effect
    }

    private func symbolImage(_ name: String, size: CGFloat) -> NSImage {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: name) ?? NSImage()
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        return base.withSymbolConfiguration(config) ?? base
    }

    private func sizeWindowToImage() {
        guard let window, let screen = NSScreen.main else { return }
        let backingScale = screen.backingScaleFactor
        let imageSize = editorDocument.pixelSize
        let naturalSize = CGSize(width: imageSize.width / backingScale, height: imageSize.height / backingScale)
        let maxSize = CGSize(width: screen.visibleFrame.width * 0.85, height: screen.visibleFrame.height * 0.85 - 48)
        let scale = min(1, maxSize.width / naturalSize.width, maxSize.height / naturalSize.height)
        let contentSize = CGSize(
            width: max(840, naturalSize.width * scale),
            height: max(560, naturalSize.height * scale + 48)
        )
        window.setContentSize(contentSize)
        window.center()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollView.magnification = min(
                1 / backingScale,
                (self.scrollView.bounds.width) / imageSize.width
            )
        }
    }

    // MARK: - History

    @objc private func toggleHistory() {
        let showing = historyWidth.constant > 0
        historyWidth.constant = showing ? 0 : 128
        if !showing {
            historyPanel.reload()
        }
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func loadFromHistory(url: URL, image: CGImage) {
        historyURL = url
        editorDocument.replaceBase(with: image)
        canvas.refreshSize()
        DispatchQueue.main.async { [weak self] in
            guard let self, let screen = self.window?.screen else { return }
            self.scrollView.magnification = min(
                1 / screen.backingScaleFactor,
                self.scrollView.bounds.width / self.editorDocument.pixelSize.width
            )
        }
    }

    // MARK: - Toolbar actions

    /// Prop bar changed: restyle the selection, or set defaults for new shapes.
    private func applyProps(_ props: PropBar.Props) {
        if canvas.selectedIndex != nil {
            canvas.updateSelected { annotation in
                annotation.color = props.color
                annotation.lineWidth = props.lineWidth
                annotation.textBackground = props.textBackground
                annotation.filled = props.filled
                if annotation.fontSize != nil {
                    annotation.fontSize = props.fontSize
                }
            }
        }
        canvas.color = props.color
        canvas.lineWidth = props.lineWidth
        canvas.fontSize = props.fontSize
        canvas.textBackground = props.textBackground
        canvas.filled = props.filled
    }

    /// Writes the annotated image back to this capture's history entry.
    private func syncHistory() {
        guard let historyURL else { return }
        HistoryStore.shared.update(historyURL, with: editorDocument.flattened)
    }

    @objc private func undo() {
        editorDocument.undo()
        canvas.refreshSize()
    }

    @objc private func redo() {
        editorDocument.redo()
        canvas.refreshSize()
    }

    /// Copies the flattened image and closes the editor.
    @objc private func copyImage() {
        canvas.commitTextEditing()
        ExportService.shared.copyToClipboard(editorDocument.flattened)
        syncHistory()
        window?.close()
    }

    @objc private func save() {
        canvas.commitTextEditing()
        if let url = ExportService.shared.saveToFile(editorDocument.flattened) {
            syncHistory()
            flashStatus("Saved \(url.lastPathComponent)")
        }
    }

    @objc private func pin() {
        canvas.commitTextEditing()
        PinManager.shared.pin(image: editorDocument.flattened)
        syncHistory()
    }

    @objc private func copyText() {
        let image = editorDocument.flattened
        flashStatus("Recognizing…")
        Task { @MainActor in
            do {
                let text = try await OCRService.recognizeText(in: image)
                if text.isEmpty {
                    flashStatus("No text found")
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    flashStatus("Text copied")
                }
            } catch {
                flashStatus("OCR failed")
            }
        }
    }

    @objc private func removeBackground() {
        let image = editorDocument.base
        flashStatus("Removing background…")
        Task { @MainActor in
            do {
                let cutout = try await BackgroundRemovalService.removeBackground(from: image)
                editorDocument.replaceBase(with: cutout)
                canvas.refreshSize()
                flashStatus("Background removed")
            } catch {
                flashStatus("No subject found")
            }
        }
    }

    private func flashStatus(_ message: String) {
        statusLabel.stringValue = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.statusLabel.stringValue == message {
                self?.statusLabel.stringValue = ""
            }
        }
    }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        // Ignore while typing in the text tool's field.
        if window?.firstResponder is NSTextView { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if flags == .command {
            switch chars {
            case "c": copyImage(); return true
            case "s": save(); return true
            case "d": pin(); return true
            case "z": undo(); return true
            case "k": selectTool(.crop); return true
            case "y": toggleHistory(); return true
            case "+", "=": scrollView.magnification *= 1.25; return true
            case "-": scrollView.magnification /= 1.25; return true
            case "0":
                if let screen = window?.screen {
                    scrollView.magnification = 1 / screen.backingScaleFactor
                }
                return true
            default: return false
            }
        }
        if flags == [.command, .shift], chars == "z" {
            redo()
            return true
        }
        if flags.isEmpty || flags == .shift {
            if let tool = Tool.allCases.first(where: { $0.key.lowercased() == chars }) {
                selectTool(tool)
                return true
            }
        }
        return false
    }

    private func selectTool(_ tool: Tool) {
        canvas.commitTextEditing()
        canvas.tool = tool
        toolStrip.select(tool)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Keep annotations even when closing without an explicit copy/save.
        if !editorDocument.annotations.isEmpty {
            syncHistory()
        }
        Self.openControllers.removeAll { $0 === self }
        if Self.openControllers.isEmpty && !BurstGalleryController.hasOpenGalleries {
            // Back to menu-bar-only once the last editor closes.
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

extension EditorWindowController: CanvasViewDelegate {
    func canvasSelectionChanged(_ index: Int?) {
        // Reflect the selected annotation's props; keep defaults otherwise.
        propBar.load(canvas.selectedAnnotation)
    }

    func canvasDidPickColor(_ color: NSColor) {
        propBar.adoptColor(color)
        canvas.color = color
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let hex = String(
            format: "#%02X%02X%02X",
            Int(rgb.redComponent * 255),
            Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255)
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        flashStatus("\(hex) copied")
    }

    func canvasDidChange() {}

    func canvasRequestsClose() {
        window?.close()
    }
}

/// Window that routes key events to the controller before standard handling.
final class EditorWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Scroll view with Photoshop-style zoom: Control+scroll (or pinch) magnifies
/// around the cursor. Plain scroll pans. Space+drag panning lives in CanvasView.
final class EditorScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else {
            super.scrollWheel(with: event)
            return
        }
        let point = contentView.convert(event.locationInWindow, from: nil)
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        let factor = 1 + delta * 0.01
        let target = max(minMagnification, min(maxMagnification, magnification * factor))
        setMagnification(target, centeredAt: point)
    }
}

/// Keeps the document view centered when smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if doc.frame.width < rect.width {
            rect.origin.x = (doc.frame.width - rect.width) / 2
        }
        if doc.frame.height < rect.height {
            rect.origin.y = (doc.frame.height - rect.height) / 2
        }
        return rect
    }
}
