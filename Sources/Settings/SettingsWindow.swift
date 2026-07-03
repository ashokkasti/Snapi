import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Snapi Settings"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 480, height: 520))
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    private let settings = SettingsStore.shared

    @State private var copyToClipboard = SettingsStore.shared.copyToClipboard
    @State private var saveToFile = SettingsStore.shared.saveToFile
    @State private var showEditor = SettingsStore.shared.showEditor
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var saveFolder = SettingsStore.shared.saveDirectory.path
    @State private var format = SettingsStore.shared.imageFormat

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            NSLog("Snapi: launch-at-login change failed: \(error)")
                        }
                    }
                Toggle("Open editor after capture", isOn: $showEditor)
                    .onChange(of: showEditor) { _, value in settings.showEditor = value }
                Toggle("Copy capture to clipboard", isOn: $copyToClipboard)
                    .onChange(of: copyToClipboard) { _, value in settings.copyToClipboard = value }
                Toggle("Save capture to file", isOn: $saveToFile)
                    .onChange(of: saveToFile) { _, value in settings.saveToFile = value }

                Picker("Format", selection: $format) {
                    Text("PNG").tag(ImageFormat.png)
                    Text("JPG").tag(ImageFormat.jpg)
                }
                .onChange(of: format) { _, value in settings.imageFormat = value }

                HStack {
                    Text("Save folder")
                    Spacer()
                    Text((saveFolder as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                }
            }

            Section("Hotkeys") {
                ForEach(HotkeyAction.allCases, id: \.rawValue) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        HotkeyRecorder(action: action)
                            .frame(width: 130, height: 24)
                    }
                }
                Text("Click a shortcut, then press the new key combination (must include ⌘, ⌥ or ⌃).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectory = url
            saveFolder = url.path
        }
    }
}

/// Click-to-record hotkey button. Captures the next keyDown with modifiers.
struct HotkeyRecorder: NSViewRepresentable {
    let action: HotkeyAction

    func makeNSView(context: Context) -> RecorderButton {
        RecorderButton(action: action)
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {}
}

final class RecorderButton: NSButton {
    private let hotkeyAction: HotkeyAction
    private var monitor: Any?

    init(action: HotkeyAction) {
        self.hotkeyAction = action
        super.init(frame: .zero)
        bezelStyle = .rounded
        title = SettingsStore.shared.hotkey(for: action).display
        target = self
        self.action = #selector(beginRecording)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func beginRecording() {
        guard monitor == nil else { return }
        title = "Press keys…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    private func endRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        title = SettingsStore.shared.hotkey(for: hotkeyAction).display
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { // Esc cancels
            endRecording()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        guard carbon != 0, flags.subtracting(.shift) != [] else {
            // Require at least one non-shift modifier.
            NSSound.beep()
            return
        }
        let keyLabel = (event.charactersIgnoringModifiers ?? "?").uppercased()
        let combo = HotkeyCombo(keyCode: UInt32(event.keyCode), modifiers: carbon, display: symbols + keyLabel)
        SettingsStore.shared.setHotkey(combo, for: hotkeyAction)
        endRecording()
    }
}
