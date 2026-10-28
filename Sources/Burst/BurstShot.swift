import AppKit

/// One frame of a burst session. The PNG is written to a temp file in the
/// background so copy / drag-out can hand other apps (Figma, Finder) real
/// files instantly.
@MainActor
final class BurstShot {
    let index: Int
    let image: CGImage
    let fileURL: URL

    init(index: Int, image: CGImage, directory: URL) {
        self.index = index
        self.image = image
        self.fileURL = directory.appendingPathComponent(String(format: "Snapi Shot %02d.png", index))
        writeInBackground()
    }

    private(set) lazy var thumbnail: NSImage = {
        let maxPixel: CGFloat = 640
        let scale = min(1, maxPixel / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard scale < 1,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return NSImage(cgImage: image, size: .zero) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return NSImage(cgImage: image, size: .zero) }
        return NSImage(cgImage: scaled, size: .zero)
    }()

    /// Returns the PNG on disk, writing it synchronously if the background
    /// write hasn't landed yet (writes are atomic, so existence means complete).
    func ensureFile() -> URL {
        if !FileManager.default.fileExists(atPath: fileURL.path),
           let data = ExportService.shared.pngData(from: image) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return fileURL
    }

    func deleteFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func writeInBackground() {
        let image = image
        let url = fileURL
        Task.detached(priority: .utility) {
            guard let data = ExportService.shared.pngData(from: image) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Fresh per-session temp folder. Previous sessions' files are cleared
    /// here (not on gallery close) so pasted file references stay valid.
    static func makeSessionDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Snapi-Burst", isDirectory: true)
        if !BurstGalleryController.hasOpenGalleries {
            try? FileManager.default.removeItem(at: root)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = root.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
