import AppKit

/// Detects a lone tap of the right Shift key without any permission prompt.
/// Carbon hotkeys can't bind a bare modifier and key-event monitors need
/// Accessibility / Input Monitoring, so this polls the session's modifier
/// state while active. Fires on release, and only when nothing else was
/// typed or held in between — Shift+letter while typing never triggers it.
@MainActor
final class RightShiftTap {
    private static let rightShiftMask: UInt64 = 0x04 // NX_DEVICERSHIFTKEYMASK
    private static let leftShiftMask: UInt64 = 0x02  // NX_DEVICELSHIFTKEYMASK
    private static let otherModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]

    private let maxTapDuration: TimeInterval = 0.5
    private let action: () -> Void
    private var timer: Timer?
    private var pressedAt: Date?
    private var keyDownsAtPress: UInt32 = 0
    private var spoiled = false

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.008, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pressedAt = nil
    }

    private func poll() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let rightDown = flags.rawValue & Self.rightShiftMask != 0
        let interfering = flags.rawValue & Self.leftShiftMask != 0 || !flags.intersection(Self.otherModifiers).isEmpty

        if rightDown {
            if pressedAt == nil {
                pressedAt = Date()
                keyDownsAtPress = keyDownCount()
                spoiled = false
            }
            if interfering { spoiled = true }
        } else if let pressedAt {
            self.pressedAt = nil
            let typed = keyDownCount() != keyDownsAtPress
            if !spoiled, !typed, Date().timeIntervalSince(pressedAt) <= maxTapDuration {
                action()
            }
        }
    }

    private func keyDownCount() -> UInt32 {
        CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
    }
}
