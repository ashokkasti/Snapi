import AppKit
import Quartz

/// Review grid for a finished burst session. Multi-select, then copy
/// (⌘C — pastes straight into Figma), save (⌘S), drag out, delete (⌫),
/// Quick Look (Space) or open in the editor (double-click / Return).
@MainActor
final class BurstGalleryController: NSWindowController, NSWindowDelegate {
    private static var openGalleries: [BurstGalleryController] = []
    static var hasOpenGalleries: Bool { !openGalleries.isEmpty }

    private var shots: [BurstShot]
    private var collectionView: GalleryCollectionView!
    private var statusLabel: NSTextField!
    private var copyButton: NSButton!
    private var saveButton: NSButton!
    private var deleteButton: NSButton!
    private var editButton: NSButton!
    private var feedbackWorkItem: DispatchWorkItem?

    static func present(shots: [BurstShot]) {
        let controller = BurstGalleryController(shots: shots)
        openGalleries.append(controller)
        NSApp.setActivationPolicy(.regular)
        controller.showWindow(nil)
        controller.window?.makeFirstResponder(controller.collectionView)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(shots: [BurstShot]) {
        self.shots = shots
        let window = GalleryWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SnapiBurstGallery")
        super.init(window: window)
        window.delegate = self
        window.keyHandler = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
        buildUI()
        updateTitle()
        updateSelectionState()
        if window.frame.origin == .zero { window.center() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - UI

    private func buildUI() {
        guard let window, let content = window.contentView else { return }

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        background.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(background)

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = itemSize()
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 16
        layout.sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        collectionView = GalleryCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(BurstShotItem.self, forItemWithIdentifier: BurstShotItem.identifier)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.onDoubleClick = { [weak self] indexPath in self?.openInEditor(at: indexPath.item) }
        collectionView.onKey = { [weak self] event in self?.handleKey(event) ?? false }

        let scroll = NSScrollView()
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(divider)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        deleteButton = makeButton("Delete", symbol: "trash", action: #selector(deleteSelected))
        editButton = makeButton("Edit", symbol: "pencil.tip.crop.circle", action: #selector(editSelected))
        saveButton = makeButton("Save", symbol: "square.and.arrow.down", action: #selector(saveSelected))
        copyButton = makeButton("Copy", symbol: "doc.on.doc", action: #selector(copySelected))
        copyButton.bezelColor = .controlAccentColor
        copyButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [statusLabel, spacer, deleteButton, editButton, saveButton, copyButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),

            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 52),

            divider.topAnchor.constraint(equalTo: bar.topAnchor),
            divider.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: bar.trailingAnchor),

            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
    }

    private func makeButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        return button
    }

    /// All shots share one region, so size cards to its aspect ratio — no letterboxing.
    private func itemSize() -> NSSize {
        guard let first = shots.first else { return NSSize(width: 260, height: 180) }
        let aspect = CGFloat(first.image.width) / CGFloat(max(1, first.image.height))
        let width: CGFloat = aspect < 0.8 ? 200 : 280
        let height = min(max(width / aspect, 90), 380)
        return NSSize(width: width, height: height)
    }

    private func updateTitle() {
        window?.title = "Burst — \(shots.count) shot\(shots.count == 1 ? "" : "s")"
    }

    private var selectedIndices: [Int] {
        collectionView.selectionIndexPaths.map(\.item).sorted()
    }

    /// Actions target the selection, or every shot when nothing is selected.
    private var targetShots: [BurstShot] {
        let selected = selectedIndices
        return selected.isEmpty ? shots : selected.map { shots[$0] }
    }

    private func updateSelectionState() {
        let selected = selectedIndices.count
        let suffix = selected == 0 ? " All" : (selected == 1 ? "" : " \(selected)")
        copyButton.title = "Copy\(suffix)"
        saveButton.title = "Save\(suffix)"
        deleteButton.isEnabled = selected > 0
        editButton.isEnabled = selected == 1
        copyButton.isEnabled = !shots.isEmpty
        saveButton.isEnabled = !shots.isEmpty
        if feedbackWorkItem == nil {
            statusLabel.stringValue = selected == 0
                ? "Click or ⌘A to select · drag shots straight into Figma · Space to preview"
                : "\(selected) of \(shots.count) selected"
        }
        if let panel = QLPreviewPanel.shared(), QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.reloadData()
        }
    }

    private func showFeedback(_ message: String) {
        feedbackWorkItem?.cancel()
        statusLabel.stringValue = message
        statusLabel.textColor = .labelColor
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.feedbackWorkItem = nil
            self.statusLabel.textColor = .secondaryLabelColor
            self.updateSelectionState()
        }
        feedbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    // MARK: - Actions

    /// Single shot: PNG data (pastes as an image everywhere). Multiple: one
    /// pasteboard item per shot carrying both the file URL and PNG data, so
    /// Figma / Finder / Slack paste all of them at once.
    @objc private func copySelected() {
        let targets = targetShots
        guard !targets.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if targets.count == 1, let data = ExportService.shared.pngData(from: targets[0].image) {
            pasteboard.setData(data, forType: .png)
        } else {
            let items = targets.map { shot -> NSPasteboardItem in
                let item = NSPasteboardItem()
                item.setString(shot.ensureFile().absoluteString, forType: .fileURL)
                if let data = try? Data(contentsOf: shot.fileURL) {
                    item.setData(data, forType: .png)
                }
                return item
            }
            pasteboard.writeObjects(items)
        }
        Sound.success()
        showFeedback("Copied \(targets.count == 1 ? "1 shot" : "\(targets.count) shots") — paste into Figma with ⌘V")
    }

    @objc private func saveSelected() {
        let targets = targetShots
        guard !targets.isEmpty else { return }
        let settings = SettingsStore.shared
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let folder = settings.saveDirectory
            .appendingPathComponent("Snapi Burst \(formatter.string(from: Date()))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var saved: [URL] = []
            for (offset, shot) in targets.enumerated() {
                guard let data = ExportService.shared.encodedData(shot.image) else { continue }
                let url = folder.appendingPathComponent(
                    String(format: "Shot %02d.%@", offset + 1, settings.imageFormat.rawValue)
                )
                try data.write(to: url)
                saved.append(url)
            }
            Sound.success()
            showFeedback("Saved \(saved.count) to \(folder.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting(saved)
        } catch {
            Sound.failure()
            showFeedback("Save failed: \(error.localizedDescription)")
        }
    }

    @objc private func deleteSelected() {
        let indices = selectedIndices
        guard !indices.isEmpty else { return }
        for index in indices.reversed() {
            shots[index].deleteFile()
            shots.remove(at: index)
        }
        collectionView.animator().performBatchUpdates({
            collectionView.deleteItems(at: Set(indices.map { IndexPath(item: $0, section: 0) }))
        }, completionHandler: { [weak self] _ in
            // Renumber the badges.
            self?.collectionView.reloadData()
        })
        updateTitle()
        updateSelectionState()
    }

    @objc private func editSelected() {
        guard let index = selectedIndices.first else { return }
        openInEditor(at: index)
    }

    private func openInEditor(at index: Int) {
        guard shots.indices.contains(index) else { return }
        EditorWindowController.present(image: shots[index].image)
    }

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Keys

    /// Keys while the grid has focus.
    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49: toggleQuickLook(); return true                  // Space
        case 51, 117: deleteSelected(); return true              // ⌫, ⌦
        case 36, 76:                                             // Return, Enter
            if selectedIndices.count == 1 { editSelected() } else { copySelected() }
            return true
        default: return false
        }
    }

    /// ⌘ shortcuts — the app has no main menu, so the window routes them.
    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return false }
        switch event.charactersIgnoringModifiers {
        case "c": copySelected()
        case "s": saveSelected()
        case "a": collectionView.selectAll(nil); updateSelectionState()
        case "w": window?.performClose(nil)
        default: return false
        }
        return true
    }

    // MARK: - Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        }
        Self.openGalleries.removeAll { $0 === self }
        if Self.openGalleries.isEmpty && !EditorWindowController.hasOpenEditors {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Collection view

extension BurstGalleryController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        shots.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: BurstShotItem.identifier, for: indexPath)
        (item as? BurstShotItem)?.configure(with: shots[indexPath.item], position: indexPath.item + 1)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updateSelectionState()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updateSelectionState()
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        canDragItemsAt indexPaths: Set<IndexPath>,
        with event: NSEvent
    ) -> Bool { true }

    func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> NSPasteboardWriting? {
        shots[indexPath.item].ensureFile() as NSURL
    }
}

extension BurstGalleryController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var previewShots: [BurstShot] {
        let selected = selectedIndices
        return selected.isEmpty ? Array(shots.prefix(1)) : selected.map { shots[$0] }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewShots.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            let shots = previewShots
            guard shots.indices.contains(index) else { return nil }
            return shots[index].ensureFile() as NSURL
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Let Space close the panel and arrows move through the grid.
        MainActor.assumeIsolated {
            guard event.type == .keyDown else { return false }
            if event.keyCode == 49 {
                toggleQuickLook()
                return true
            }
            collectionView.keyDown(with: event)
            return true
        }
    }
}

// MARK: - Views

private final class GalleryWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

private final class GalleryCollectionView: NSCollectionView {
    var onDoubleClick: ((IndexPath) -> Void)?
    var onKey: ((NSEvent) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point) {
            onDoubleClick?(indexPath)
        }
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

private final class BurstShotItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("BurstShotItem")

    private let preview = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private let check = NSImageView()

    override func loadView() {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.masksToBounds = false
        card.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.18
        card.layer?.shadowRadius = 6
        card.layer?.shadowOffset = CGSize(width: 0, height: -2)

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 8
        preview.layer?.masksToBounds = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(preview)

        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.drawsBackground = true
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        badge.layer?.cornerRadius = 4
        badge.layer?.masksToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(badge)

        let checkConfig = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            .applying(.init(paletteColors: [.white, .controlAccentColor]))
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Selected")?
            .withSymbolConfiguration(checkConfig)
        check.translatesAutoresizingMaskIntoConstraints = false
        check.isHidden = true
        card.addSubview(check)

        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            preview.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
            preview.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4),
            preview.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),

            badge.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            badge.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),

            check.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            check.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
        ])
        view = card
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateSelection() }
    }

    func configure(with shot: BurstShot, position: Int) {
        preview.image = shot.thumbnail
        badge.stringValue = " \(position) "
        updateSelection()
    }

    private func updateSelection() {
        let selected = isSelected || highlightState == .forSelection
        view.layer?.borderWidth = selected ? 3 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.backgroundColor = (selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.06)).cgColor
        check.isHidden = !selected
    }
}
