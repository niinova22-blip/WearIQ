import ProductMeasurementParser
import WearIQCore
import UIKit
import Vision

protocol SizeChartReading {
    func readSizeChart(from image: UIImage) async throws -> ParsedSizeChart
}

/// What was read from a size chart image. Images with several tables (one per fit)
/// give several sections; `chosen` is the one matching the product's fit, if any.
struct SizeChartScan {
    var sections: [SizeChartSection]
    var chosen: SizeChartSection?
}

enum OCRError: LocalizedError {
    case unreadableImage
    case noTextFound
    case noSizeChartFound

    var errorDescription: String? {
        switch self {
        case .unreadableImage: String(localized: "The image couldn't be opened.")
        case .noTextFound: String(localized: "No text was found in the image.")
        case .noSizeChartFound: String(localized: "No size chart was recognised. Crop the image to the table or enter the values manually.")
        }
    }
}

/// On-device text recognition (Vision) → table rows → size chart.
struct OCRService: SizeChartReading {
    func readSizeChart(from image: UIImage) async throws -> ParsedSizeChart {
        let result = try await readSections(from: image, fit: nil)
        guard let chart = (result.chosen ?? result.sections.first)?.chart else { throw OCRError.noSizeChartFound }
        return chart
    }

    /// Reads every table in the image. Tables with sizes in rows are read by cell position;
    /// otherwise the classic layout (sizes across the top) is parsed from text lines.
    func readSections(from image: UIImage, fit: FitStyle?) async throws -> SizeChartScan {
        let boxes = try await recognize(image)
        var sections = SizeTableReader.sections(from: boxes)
        if sections.isEmpty {
            let chart = SizeChartParser().parse(OCRLineAssembler.assemble(boxes))
            if !chart.sizes.isEmpty { sections = [SizeChartSection(title: nil, fitStyle: nil, chart: chart)] }
        }
        guard !sections.isEmpty else { throw OCRError.noSizeChartFound }
        return SizeChartScan(sections: sections, chosen: SizeTableReader.best(sections, fit: fit))
    }

    private func recognize(_ image: UIImage) async throws -> [TextBox] {
        guard let cgImage = image.cgImage else { throw OCRError.unreadableImage }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)

        let boxes: [TextBox] = try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["tr-TR", "en-US"]
            request.usesLanguageCorrection = false // numbers and size labels, not prose
            try VNImageRequestHandler(cgImage: cgImage, orientation: orientation).perform([request])
            return (request.results ?? []).compactMap { obs -> TextBox? in
                guard let text = obs.topCandidates(1).first?.string else { return nil }
                let b = obs.boundingBox
                return TextBox(text: text, minX: b.minX, midY: 1 - b.midY, height: b.height, width: b.width)
            }
        }.value

        guard !boxes.isEmpty else { throw OCRError.noTextFound }
        return boxes
    }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
