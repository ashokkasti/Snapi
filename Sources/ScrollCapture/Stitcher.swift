import AppKit

/// Vertically stitches sequential frames of a scrolling region.
/// Overlap between the composite tail and each new frame is found by
/// comparing per-row grayscale signatures; only the new rows are appended.
final class Stitcher {
    private var slices: [CGImage] = []
    private var signature: [Float] = []
    private let signatureWidth = 32

    var isEmpty: Bool { slices.isEmpty }

    func add(_ frame: CGImage) {
        guard let rows = rowSignature(of: frame) else { return }
        guard !slices.isEmpty else {
            slices.append(frame)
            signature = rows
            return
        }

        let m = rows.count
        let tailLength = min(signature.count, m)
        let tail = Array(signature.suffix(tailLength))

        var bestOverlap = 0
        var bestError = Float.greatestFiniteMagnitude
        let minOverlap = 16
        if tailLength >= minOverlap {
            for overlap in stride(from: minOverlap, through: tailLength, by: 2) {
                var error: Float = 0
                var samples = 0
                var i = 0
                while i < overlap {
                    error += abs(tail[tailLength - overlap + i] - rows[i])
                    samples += 1
                    i += 4
                }
                let mean = error / Float(max(samples, 1))
                if mean < bestError {
                    bestError = mean
                    bestOverlap = overlap
                }
            }
        }

        let matched = bestError < 4.0
        if matched && bestOverlap >= m {
            return // duplicate frame, nothing new
        }
        let newRowStart = matched ? bestOverlap : 0
        let newHeight = m - newRowStart
        guard newHeight > 0,
              let slice = frame.cropping(to: CGRect(x: 0, y: newRowStart, width: frame.width, height: newHeight))
        else { return }
        slices.append(slice)
        signature.append(contentsOf: rows[newRowStart...])
    }

    func assemble() -> CGImage? {
        guard let first = slices.first else { return nil }
        let width = first.width
        let totalHeight = slices.reduce(0) { $0 + $1.height }
        guard totalHeight > 0, let context = CGContext(
            data: nil, width: width, height: totalHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // CGContext origin is bottom-left; stack slices top-down.
        var y = totalHeight
        for slice in slices {
            y -= slice.height
            context.draw(slice, in: CGRect(x: 0, y: y, width: slice.width, height: slice.height))
        }
        return context.makeImage()
    }

    /// Mean grayscale value per row, computed on a narrow downscale.
    private func rowSignature(of image: CGImage) -> [Float]? {
        let height = image.height
        guard height > 0, let context = CGContext(
            data: nil, width: signatureWidth, height: height,
            bitsPerComponent: 8, bytesPerRow: signatureWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: signatureWidth, height: height))
        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: signatureWidth * height)

        var rows = [Float](repeating: 0, count: height)
        for row in 0..<height {
            var sum = 0
            // Context rows are bottom-up; flip so index 0 = top row of the frame.
            let contextRow = height - 1 - row
            for col in 0..<signatureWidth {
                sum += Int(buffer[contextRow * signatureWidth + col])
            }
            rows[row] = Float(sum) / Float(signatureWidth)
        }
        return rows
    }
}
