import AppKit

enum ScreenPermission {
    /// Checks Screen Recording permission; prompts once via system dialog,
    /// then directs the user to System Settings if still denied.
    static func ensure() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            DispatchQueue.main.async { showSettingsAlert() }
        }
    }

    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    private static func showSettingsAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Needed"
        alert.informativeText = "Snapi needs Screen Recording access to take screenshots.\n\nEnable it in System Settings → Privacy & Security → Screen Recording, then relaunch Snapi."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
        }
    }
}
