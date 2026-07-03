import AppKit
import UniformTypeIdentifiers

final class ExportService {
    static let shared = ExportService()
    private let settings = SettingsStore.shared

    /// Copies to clipboard and/or saves to file per settings, with audio feedback.
    func export(_ image: CGImage) {
        if settings.copyToClipboard {
            copyToClipboard(image)
        }
        if settings.saveToFile {
            saveToFile(image)
        }
    }

    func copyToClipboard(_ image: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let data = pngData(from: image) {
            pasteboard.setData(data, forType: .png)
        }
    }

    @discardableResult
    func saveToFile(_ image: CGImage) -> URL? {
        let data: Data?
        switch settings.imageFormat {
        case .png: data = pngData(from: image)
        case .jpg: data = jpegData(from: image, quality: settings.jpegQuality)
        }
        guard let data else { return nil }
        let url = settings.screenshotFileURL()
        do {
            try FileManager.default.createDirectory(at: settings.saveDirectory, withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        } catch {
            NSLog("Snapi: failed to save screenshot: \(error)")
            return nil
        }
    }

    private func pngData(from image: CGImage) -> Data? {
        encode(image, type: UTType.png, options: nil)
    }

    private func jpegData(from image: CGImage, quality: Double) -> Data? {
        encode(image, type: UTType.jpeg, options: [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    }

    private func encode(_ image: CGImage, type: UTType, options: CFDictionary?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, options)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
