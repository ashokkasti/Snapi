import AppKit
import Vision

/// On-device text + QR/barcode recognition via Vision.
enum OCRService {
    static func recognizeText(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let textRequest = VNRecognizeTextRequest()
                    textRequest.recognitionLevel = .accurate
                    textRequest.usesLanguageCorrection = true

                    let barcodeRequest = VNDetectBarcodesRequest()

                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([textRequest, barcodeRequest])

                    var parts: [String] = []
                    if let observations = textRequest.results {
                        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                        parts.append(contentsOf: lines)
                    }
                    if let barcodes = barcodeRequest.results {
                        let payloads = barcodes.compactMap(\.payloadStringValue)
                        parts.append(contentsOf: payloads)
                    }
                    continuation.resume(returning: parts.joined(separator: "\n"))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
