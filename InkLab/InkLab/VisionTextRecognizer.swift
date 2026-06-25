import Foundation
import Vision
import UIKit
import InkLabKit

/// On-device handwriting/text recognition via Apple Vision. Lives in the app target (not the
/// Foundation-only InkLabRecognition package) because it depends on Vision/UIKit — this is the
/// "iOS adapter" the package's docs describe. It conforms to `InkRecognizer`, so swapping in
/// MyScript or the Claude-via-proxy provider later is a one-line change.
///
/// Vision reads flat text, so the result is `.plainText`; the deterministic engines parse that
/// string (an equation chain, a chemical equation, a DNA sequence, …). The user confirms/edits the
/// transcription in the review sheet before any engine runs — "read vs compute", kept honest.
///
/// `nonisolated` so it matches the nonisolated `InkRecognizer.recognize` requirement and is not
/// pinned to the main actor by the target's MainActor-default isolation: all OCR work (decode,
/// composite, perform) happens on a background queue; only delivery hops back to the caller's actor.
struct VisionTextRecognizer: InkRecognizer {
    let id: ProviderID = .appleVision
    let isOnDevice = true
    let supportedFamilies: Set<DomainFamily> = [.text, .math, .chemistry, .diagram]

    nonisolated func recognize(_ input: RecognitionInput) async throws -> RecognitionResult {
        let raster = input.raster
        return try await withCheckedThrowingContinuation { continuation in
            // One resume site per path: the completion handler is NOT used (perform runs the request
            // synchronously and populates request.results), so there is no double-resume window.
            DispatchQueue.global(qos: .userInitiated).async {
                guard let cgImage = Self.whiteBackedImage(from: raster) else {
                    continuation.resume(returning: .unread(reason: "no image"))
                    return
                }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false   // math symbols / formulae, not prose
                request.recognitionLanguages = ["en-US"]
                do {
                    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
                    let candidates = (request.results as? [VNRecognizedTextObservation] ?? [])
                        .compactMap { $0.topCandidates(1).first }
                    let text = candidates.map(\.string).joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty || candidates.isEmpty {
                        continuation.resume(returning: .unread(reason: "no text found"))
                    } else {
                        let confidence = Double(candidates.map(\.confidence).reduce(0, +)) / Double(candidates.count)
                        continuation.resume(returning: .init(formal: .plainText(text),
                                                             confidence: confidence, readAs: text,
                                                             provider: .appleVision, isOnDevice: true))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Vision OCR works best on dark ink over an opaque light background; the rasterized PKDrawing is
    /// ink over transparency, so composite it onto white first. Runs off the main thread.
    nonisolated static func whiteBackedImage(from raster: RasterImage) -> CGImage? {
        guard let image = UIImage(data: raster.pngData), image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        let composited = UIGraphicsImageRenderer(size: image.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: image.size))
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return composited.cgImage
    }
}

private extension RecognitionResult {
    /// An explicit on-device "couldn't read this" result (never a guess — correct-or-silent).
    static func unread(reason: String) -> RecognitionResult {
        .init(formal: .unrecognized(reason: reason), confidence: 0, readAs: "",
              provider: .appleVision, isOnDevice: true)
    }
}

/// Builds the recognizer the app uses. Apple Vision only, on-device — no backend required to run
/// and test the full write → recognize → compute loop.
enum AppRecognizer {
    static func make() -> any InkRecognizer { VisionTextRecognizer() }
}
