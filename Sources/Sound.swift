import AppKit

/// Centralized audio feedback. Prefers the real macOS shutter sound for
/// captures, with graceful fallbacks.
enum Sound {
    private static let shutter: NSSound? = {
        let candidates = [
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif",
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let sound = NSSound(contentsOfFile: path, byReference: true) {
                return sound
            }
        }
        return NSSound(named: "Tink")
    }()

    /// Camera-shutter feedback for a completed capture.
    static func capture() {
        shutter?.stop()
        shutter?.play()
    }

    static func success() { NSSound(named: "Glass")?.play() }
    static func failure() { NSSound(named: "Basso")?.play() }
}
