import AppKit
import UniformTypeIdentifiers

/// Rolling on-disk history of recent captures (newest first, capped).
final class HistoryStore {
    static let shared = HistoryStore()
    static let changedNotification = Notification.Name("SnapiHistoryChanged")

    private let capacity = 15
    private let directory: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = appSupport.appendingPathComponent("Snapi/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @discardableResult
    func add(_ image: CGImage) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = directory.appendingPathComponent("\(formatter.string(from: Date())).png")
        guard write(image, to: url) else { return nil }
        prune()
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
        return url
    }

    /// Overwrites an existing entry (e.g. with the annotated version).
    func update(_ url: URL, with image: CGImage) {
        guard url.path.hasPrefix(directory.path) else { return }
        guard write(image, to: url) else { return }
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    private func write(_ image: CGImage, to url: URL) -> Bool {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return false }
        do {
            try (data as Data).write(to: url)
            return true
        } catch {
            return false
        }
    }

    /// Newest first.
    func entries() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func image(at url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func thumbnail(at url: URL, maxPixel: CGFloat = 320) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    private func prune() {
        let all = entries()
        guard all.count > capacity else { return }
        for url in all.dropFirst(capacity) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
