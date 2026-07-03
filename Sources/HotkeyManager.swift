import AppKit
import Carbon.HIToolbox

enum KeyCodes {
    static let one: UInt32 = UInt32(kVK_ANSI_1)
    static let two: UInt32 = UInt32(kVK_ANSI_2)
}

struct HotkeyModifiers: OptionSet {
    let rawValue: UInt32
    static let command = HotkeyModifiers(rawValue: UInt32(cmdKey))
    static let shift = HotkeyModifiers(rawValue: UInt32(shiftKey))
    static let option = HotkeyModifiers(rawValue: UInt32(optionKey))
    static let control = HotkeyModifiers(rawValue: UInt32(controlKey))
}

/// Global hotkey registration via Carbon. Still the only public API that
/// works without Accessibility permission.
final class HotkeyManager {
    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandlerRef: EventHandlerRef?

    private static let signature: OSType = 0x534E5049 // 'SNPI'

    init() {
        installHandler()
    }

    func register(id: UInt32, keyCode: UInt32, modifiers: HotkeyModifiers, action: @escaping () -> Void) {
        register(id: id, keyCode: keyCode, carbonModifiers: modifiers.rawValue, action: action)
    }

    func register(id: UInt32, keyCode: UInt32, carbonModifiers: UInt32, action: @escaping () -> Void) {
        handlers[id] = action
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRefs.append(ref)
        } else {
            NSLog("Snapi: failed to register hotkey id=\(id) status=\(status)")
        }
    }

    func unregisterAll() {
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeyRefs.removeAll()
        handlers.removeAll()
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            if hotKeyID.signature == HotkeyManager.signature {
                manager.handlers[hotKeyID.id]?()
            }
            return noErr
        }, 1, &eventType, selfPtr, &eventHandlerRef)
    }

    deinit {
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }
}
