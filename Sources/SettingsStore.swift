import AppKit
import Carbon.HIToolbox

enum HotkeyAction: String, CaseIterable {
    case area, fullscreen, window, scrolling, burst, ocr, pin, repeatLast

    var title: String {
        switch self {
        case .area: return "Capture Area"
        case .fullscreen: return "Capture Fullscreen"
        case .window: return "Capture Window"
        case .scrolling: return "Scrolling Capture"
        case .burst: return "Burst Capture / Shoot"
        case .ocr: return "OCR Area to Text"
        case .pin: return "Pin Clipboard / Area"
        case .repeatLast: return "Repeat Last Area"
        }
    }

    var defaultCombo: HotkeyCombo {
        let cmdShift = UInt32(cmdKey | shiftKey)
        switch self {
        case .area: return HotkeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: cmdShift, display: "⌘⇧2")
        case .fullscreen: return HotkeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: cmdShift, display: "⌘⇧1")
        case .window: return HotkeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: cmdShift, display: "⌘⇧3")
        case .scrolling: return HotkeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: cmdShift, display: "⌘⇧5")
        case .burst: return HotkeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(controlKey), display: "⌃3")
        case .ocr: return HotkeyCombo(keyCode: UInt32(kVK_ANSI_O), modifiers: cmdShift, display: "⌘⇧O")
        case .pin: return HotkeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: cmdShift, display: "⌘⇧P")
        case .repeatLast: return HotkeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: cmdShift, display: "⌘⇧R")
        }
    }
}

struct HotkeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey | shiftKey | ...).
    var modifiers: UInt32
    var display: String
}

extension Notification.Name {
    static let snapiHotkeysChanged = Notification.Name("SnapiHotkeysChanged")
}

enum ImageFormat: String, CaseIterable {
    case png, jpg
}

final class SettingsStore {
    static let shared = SettingsStore()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let saveDirectory = "saveDirectory"
        static let copyToClipboard = "copyToClipboard"
        static let saveToFile = "saveToFile"
        static let showEditor = "showEditor"
        static let imageFormat = "imageFormat"
        static let jpegQuality = "jpegQuality"
        static let hotkeys = "hotkeys"
    }

    var saveDirectory: URL {
        get {
            if let path = defaults.string(forKey: Keys.saveDirectory) {
                return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
        set { defaults.set(newValue.path, forKey: Keys.saveDirectory) }
    }

    var copyToClipboard: Bool {
        get { defaults.object(forKey: Keys.copyToClipboard) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.copyToClipboard) }
    }

    var saveToFile: Bool {
        get { defaults.object(forKey: Keys.saveToFile) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.saveToFile) }
    }

    /// Open the annotation editor after capture (vs. direct clipboard/file export).
    var showEditor: Bool {
        get { defaults.object(forKey: Keys.showEditor) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showEditor) }
    }

    var imageFormat: ImageFormat {
        get { ImageFormat(rawValue: defaults.string(forKey: Keys.imageFormat) ?? "png") ?? .png }
        set { defaults.set(newValue.rawValue, forKey: Keys.imageFormat) }
    }

    var jpegQuality: Double {
        get { defaults.object(forKey: Keys.jpegQuality) as? Double ?? 0.9 }
        set { defaults.set(newValue, forKey: Keys.jpegQuality) }
    }

    // MARK: - Hotkeys

    func hotkey(for action: HotkeyAction) -> HotkeyCombo {
        guard let data = defaults.data(forKey: Keys.hotkeys),
              let map = try? JSONDecoder().decode([String: HotkeyCombo].self, from: data),
              let combo = map[action.rawValue]
        else { return action.defaultCombo }
        return combo
    }

    func setHotkey(_ combo: HotkeyCombo, for action: HotkeyAction) {
        var map: [String: HotkeyCombo] = [:]
        if let data = defaults.data(forKey: Keys.hotkeys),
           let existing = try? JSONDecoder().decode([String: HotkeyCombo].self, from: data) {
            map = existing
        }
        map[action.rawValue] = combo
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: Keys.hotkeys)
        }
        NotificationCenter.default.post(name: .snapiHotkeysChanged, object: nil)
    }

    func screenshotFileURL(date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Snapi \(formatter.string(from: date)).\(imageFormat.rawValue)"
        return saveDirectory.appendingPathComponent(name)
    }
}
