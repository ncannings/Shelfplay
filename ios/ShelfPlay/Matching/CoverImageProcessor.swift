import CoreImage
import OSLog
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

/// A line of text read off a cover, with its size relative to the cover height.
struct OCRLine: Hashable, Sendable {
    let text: String
    let relativeHeight: Double
    let confidence: Float
}

/// On-device image work for cover recognition (Vision framework).
enum CoverImageProcessor {
    private static let ciContext = CIContext()

    /// Upright, size-bounded CGImage from a camera or library photo.
    static func normalized(_ image: UIImage, maxDimension: CGFloat = 1600) -> CGImage? {
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
    }

    /// Finds the sleeve in the photo and returns it perspective-corrected.
    /// Falls back to a centre square crop (the viewfinder guide) when no rectangle is found.
    static func extractCover(from image: CGImage) async -> (image: CGImage, detected: Bool) {
        var request = DetectRectanglesRequest()
        request.minimumAspectRatio = 0.7
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.35
        request.minimumConfidence = 0.6
        request.quadratureToleranceDegrees = 25
        request.maximumObservations = 4
        let size = CGSize(width: image.width, height: image.height)
        if let rects = try? await request.perform(on: image),
           let best = rects.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
            let filter = CIFilter.perspectiveCorrection()
            filter.inputImage = CIImage(cgImage: image)
            filter.topLeft = best.topLeft.toImageCoordinates(size)
            filter.topRight = best.topRight.toImageCoordinates(size)
            filter.bottomLeft = best.bottomLeft.toImageCoordinates(size)
            filter.bottomRight = best.bottomRight.toImageCoordinates(size)
            if let out = filter.outputImage, let cg = ciContext.createCGImage(out, from: out.extent) {
                return (cg, true)
            }
        }
        // Fall back to document segmentation, which copes better with sleeves on busy backgrounds.
        if let doc = try? await DetectDocumentSegmentationRequest().perform(on: image), doc.confidence > 0.5,
           doc.boundingBox.width * doc.boundingBox.height > 0.2 {
            let filter = CIFilter.perspectiveCorrection()
            filter.inputImage = CIImage(cgImage: image)
            filter.topLeft = doc.topLeft.toImageCoordinates(size)
            filter.topRight = doc.topRight.toImageCoordinates(size)
            filter.bottomLeft = doc.bottomLeft.toImageCoordinates(size)
            filter.bottomRight = doc.bottomRight.toImageCoordinates(size)
            if let out = filter.outputImage, let cg = ciContext.createCGImage(out, from: out.extent) {
                return (cg, true)
            }
        }
        let side = Int(Double(min(image.width, image.height)) * 0.9)
        let rect = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        return (image.cropping(to: rect) ?? image, false)
    }

    static func recognizeText(in image: CGImage) async -> [OCRLine] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false   // band names aren't dictionary words; the language model fixes typos
        request.automaticallyDetectsLanguage = true
        guard let observations = try? await request.perform(on: image) else { return [] }
        return observations.compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2, top.confidence >= 0.3, text.contains(where: \.isLetter) else { return nil }
            return OCRLine(text: text, relativeHeight: Double(obs.boundingBox.height), confidence: top.confidence)
        }
        .sorted { $0.relativeHeight > $1.relativeHeight }
    }

    static func featurePrint(of image: CGImage) async -> FeaturePrintObservation? {
        do {
            return try await GenerateImageFeaturePrintRequest().perform(on: image)
        } catch {
            MatchTrace.write("Feature print failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func downloadImage(_ url: URL) async -> CGImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else {
            MatchTrace.write("Artwork download failed: \(url.absoluteString)")
            return nil
        }
        return image.cgImage
    }

    static func archive(_ print: FeaturePrintObservation) -> Data? { try? JSONEncoder().encode(print) }
    static func unarchive(_ data: Data) -> FeaturePrintObservation? { try? JSONDecoder().decode(FeaturePrintObservation.self, from: data) }
}
