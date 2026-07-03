import AppKit
import UniformTypeIdentifiers

/// Hidden `--demo-gif <path>` mode: opens the editor with a sample capture,
/// applies annotation stages, snapshots the window and writes an animated GIF.
/// Used to generate the README demo without screen-recording permissions.
@MainActor
enum DemoScene {
    static func exportGif(to path: String) {
        let base = sampleImage()
        EditorWindowController.present(image: base)
        guard let controller = EditorWindowController.demoController() else {
            NSApp.terminate(nil)
            return
        }

        controller.window?.setFrame(NSRect(x: 80, y: 80, width: 1100, height: 760), display: true)
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            var frames: [CGImage] = []
            for stage in stages() {
                controller.injectDemo(annotations: stage)
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                controller.window?.displayIfNeeded()
                try? await Task.sleep(nanoseconds: 400_000_000)
                if let frame = controller.snapshotWindow() {
                    frames.append(frame)
                }
            }
            writeGif(frames, to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }

    // MARK: - Stages

    private static func stages() -> [[Annotation]] {
        let arrow = Annotation(
            shape: .arrow(from: CGPoint(x: 330, y: 640), to: CGPoint(x: 560, y: 445)),
            color: .systemRed, lineWidth: 6
        )
        let highlight = Annotation(
            shape: .highlight(CGRect(x: 615, y: 280, width: 430, height: 64)),
            color: .systemYellow, lineWidth: 4
        )
        let rect = Annotation(
            shape: .rect(CGRect(x: 590, y: 250, width: 520, height: 200)),
            color: .systemRed, lineWidth: 6
        )
        var text = Annotation(
            shape: .text(string: "Annotate with style!", origin: CGPoint(x: 620, y: 540), fontSize: 96),
            color: .systemYellow, lineWidth: 4
        )
        text.textBackground = false
        var counter = Annotation(
            shape: .counter(center: CGPoint(x: 300, y: 720), number: 1, label: "Handwritten labels"),
            color: .systemGreen, lineWidth: 5
        )
        counter.counterLabelSize = 64
        let blur = Annotation(
            shape: .blur(CGRect(x: 1080, y: 620, width: 260, height: 120)),
            color: .black, lineWidth: 4
        )
        return [
            [arrow],
            [arrow, highlight, rect],
            [arrow, highlight, rect, text],
            [arrow, highlight, rect, text, counter, blur],
        ]
    }

    // MARK: - Sample capture

    private static func sampleImage() -> CGImage {
        let width = 1440
        let height = 900
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // Desktop-ish gradient backdrop.
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor(red: 0.94, green: 0.55, blue: 0.36, alpha: 1).cgColor,
                NSColor(red: 0.83, green: 0.26, blue: 0.48, alpha: 1).cgColor,
            ] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: height),
            end: CGPoint(x: CGFloat(width), y: 0),
            options: []
        )

        // Fake app window.
        let windowRect = CGRect(x: 140, y: 120, width: 1160, height: 660)
        let windowPath = CGPath(roundedRect: windowRect, cornerWidth: 14, cornerHeight: 14, transform: nil)
        context.setFillColor(NSColor.white.cgColor)
        context.addPath(windowPath)
        context.fillPath()

        // Title bar dots.
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: 165 + i * 26, y: Int(windowRect.maxY) - 36, width: 14, height: 14))
        }

        // Sidebar.
        context.setFillColor(NSColor(white: 0.95, alpha: 1).cgColor)
        context.fill(CGRect(x: windowRect.minX, y: windowRect.minY, width: 220, height: windowRect.height - 50))

        // Content bars.
        context.setFillColor(NSColor(white: 0.88, alpha: 1).cgColor)
        for row in 0..<7 {
            let y = windowRect.maxY - 120 - CGFloat(row) * 74
            context.fill(CGRect(x: windowRect.minX + 260, y: y, width: row % 2 == 0 ? 780 : 560, height: 34))
        }
        // Accent block (the "target" the demo annotates).
        context.setFillColor(NSColor(red: 0.30, green: 0.65, blue: 0.55, alpha: 1).cgColor)
        let accent = CGRect(x: 620, y: 470, width: 400, height: 120)
        let accentPath = CGPath(roundedRect: accent, cornerWidth: 10, cornerHeight: 10, transform: nil)
        context.addPath(accentPath)
        context.fillPath()

        return context.makeImage()!
    }

    // MARK: - GIF

    private static func writeGif(_ frames: [CGImage], to url: URL) {
        guard !frames.isEmpty,
              let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.gif.identifier as CFString, frames.count, nil
              )
        else { return }
        let fileProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary
        CGImageDestinationSetProperties(dest, fileProperties)
        for frame in frames {
            let frameProperties = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.4]
            ] as CFDictionary
            CGImageDestinationAddImage(dest, frame, frameProperties)
        }
        CGImageDestinationFinalize(dest)
    }
}
