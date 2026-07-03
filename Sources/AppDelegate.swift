import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyManager()
    private let capture = CaptureController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hidden README-GIF generator: Snapi --demo-gif /path/out.gif
        let args = CommandLine.arguments
        if let flagIndex = args.firstIndex(of: "--demo-gif"), args.indices.contains(flagIndex + 1) {
            DemoScene.exportGif(to: args[flagIndex + 1])
            return
        }
        setupStatusItem()
        registerHotkeys()
        ScreenPermission.ensure()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeysChanged),
            name: .snapiHotkeysChanged,
            object: nil
        )
    }

    // MARK: - Menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snapi")
        }
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        func item(_ title: String, _ symbol: String?, _ selector: Selector, _ action: HotkeyAction?) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            if let symbol {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            }
            if let action {
                item.title = "\(title)   \(SettingsStore.shared.hotkey(for: action).display)"
            }
            return item
        }

        menu.addItem(item("Capture Area", "viewfinder", #selector(captureArea), .area))
        menu.addItem(item("Capture Fullscreen", "macwindow.on.rectangle", #selector(captureFullscreen), .fullscreen))
        menu.addItem(item("Capture Window", "macwindow", #selector(captureWindow), .window))
        menu.addItem(item("Scrolling Capture", "arrow.up.and.down.square", #selector(scrollingCapture), .scrolling))
        menu.addItem(item("Repeat Last Area", "arrow.counterclockwise.square", #selector(repeatLast), .repeatLast))

        let delayed = NSMenuItem(title: "Delayed Capture", action: nil, keyEquivalent: "")
        delayed.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Delayed Capture")
        let delayedMenu = NSMenu()
        delayedMenu.addItem(item("In 3 Seconds", "3.circle", #selector(delayed3), nil))
        delayedMenu.addItem(item("In 10 Seconds", "10.circle", #selector(delayed10), nil))
        delayed.submenu = delayedMenu
        menu.addItem(delayed)

        menu.addItem(.separator())
        menu.addItem(item("OCR Area to Text", "text.viewfinder", #selector(ocrArea), .ocr))
        menu.addItem(item("Pin Clipboard / Area", "pin", #selector(pinClipboard), .pin))

        menu.addItem(.separator())
        menu.addItem(item("Open Screenshots Folder", "folder", #selector(openFolder), nil))
        menu.addItem(item("Settings…", "gearshape", #selector(openSettings), nil))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Snapi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        let bindings: [(HotkeyAction, () -> Void)] = [
            (.area, { [weak self] in self?.capture.beginAreaCapture() }),
            (.fullscreen, { [weak self] in self?.capture.captureFullscreen() }),
            (.window, { [weak self] in self?.capture.beginWindowCapture() }),
            (.scrolling, { [weak self] in self?.capture.beginScrollingCapture() }),
            (.ocr, { [weak self] in self?.capture.beginOCRCapture() }),
            (.pin, { [weak self] in self?.capture.pinClipboardOrArea() }),
            (.repeatLast, { [weak self] in self?.capture.repeatLastArea() }),
        ]
        for (index, binding) in bindings.enumerated() {
            let combo = SettingsStore.shared.hotkey(for: binding.0)
            hotkeys.register(
                id: UInt32(index + 1),
                keyCode: combo.keyCode,
                carbonModifiers: combo.modifiers,
                action: binding.1
            )
        }
    }

    @objc private func hotkeysChanged() {
        hotkeys.unregisterAll()
        registerHotkeys()
        statusItem.menu = buildMenu()
    }

    // MARK: - Actions

    @objc private func captureArea() { capture.beginAreaCapture() }
    @objc private func captureFullscreen() { capture.captureFullscreen() }
    @objc private func captureWindow() { capture.beginWindowCapture() }
    @objc private func scrollingCapture() { capture.beginScrollingCapture() }
    @objc private func repeatLast() { capture.repeatLastArea() }
    @objc private func delayed3() { capture.delayedFullscreen(seconds: 3) }
    @objc private func delayed10() { capture.delayedFullscreen(seconds: 10) }
    @objc private func ocrArea() { capture.beginOCRCapture() }
    @objc private func pinClipboard() { capture.pinClipboardOrArea() }
    @objc private func openFolder() { NSWorkspace.shared.open(SettingsStore.shared.saveDirectory) }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
}
