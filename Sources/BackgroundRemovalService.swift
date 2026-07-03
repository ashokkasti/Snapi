import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

enum BackgroundRemovalError: Error {
    case noSubject
    case renderFailed
}

/// Isolates the foreground subject via Vision, producing a transparent PNG-ready image.
enum BackgroundRemovalService {
    static func removeBackground(from image: CGImage) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNGenerateForegroundInstanceMaskRequest()
                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([request])
                    guard let result = request.results?.first else {
                        continuation.resume(throwing: BackgroundRemovalError.noSubject)
                        return
                    }
                    let maskBuffer = try result.generateScaledMaskForImage(
                        forInstances: result.allInstances,
                        from: handler
                    )

                    let source = CIImage(cgImage: image)
                    let mask = CIImage(cvPixelBuffer: maskBuffer)
                    let filter = CIFilter.blendWithMask()
                    filter.inputImage = source
                    filter.backgroundImage = CIImage.empty()
                    filter.maskImage = mask

                    let context = CIContext()
                    guard let output = filter.outputImage,
                          let cgImage = context.createCGImage(output, from: source.extent)
                    else {
                        continuation.resume(throwing: BackgroundRemovalError.renderFailed)
                        return
                    }
                    continuation.resume(returning: cgImage)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
