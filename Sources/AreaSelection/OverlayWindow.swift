import AppKit

/// Borderless full-screen window showing the frozen screenshot for selection.
final class OverlayWindow: NSWindow {
    @MainActor
    init(capture: DisplayCapture, session: AreaSelectionSession) {
        super.init(
            contentRect: capture.screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = SelectionView(capture: capture, session: session)
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
