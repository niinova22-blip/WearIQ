import FitEngine
import Foundation
import ProductMeasurementParser
import Testing
import UIKit
import WearIQCore
@testable import WearIQ

/// The 1.1 reading improvements as the app shows them: the one-line reasons for a size,
/// the new trouser measurements' names, and a size chart photo read on the device.
@MainActor
@Suite struct ReadingImprovementsTests {
    @Test func reasonsReadAsWords() {
        let fits = DecisionSummary.Part.region(.waist, .ideal).text(capitalised: true)
        #expect(fits.hasPrefix(FitRegion.waist.title))
        #expect(fits.count > FitRegion.waist.title.count)
        let longer = DecisionSummary.Part.versusFavourite(.inseam, 4).text(capitalised: false)
        #expect(longer.contains("4"))
        #expect(longer.contains(GarmentDimension.inseam.title.lowercased(with: Locale.current)))
        let narrower = DecisionSummary.Part.versusFavourite(.legOpening, -3).text(capitalised: false)
        #expect(narrower.contains("3"))
        #expect(!narrower.contains("-"))
    }

    @Test func newTrouserMeasurementsHaveNames() {
        #expect(!GarmentDimension.legOpening.title.isEmpty)
        #expect(!GarmentDimension.frontRise.title.isEmpty)
        #expect(GarmentDraft.dimensions(for: .pants).contains(.legOpening))
        #expect(GarmentDraft.dimensions(for: .pants).contains(.frontRise))
    }

    @Test func suspendedMeasurementIsExplained() {
        let message = ParsedSizeChart.Warning.conflictingValuesSuspended(.waist).message
        #expect(message?.isEmpty == false)
    }

    /// A trouser chart drawn as a ruled table, read with on-device Vision: iOS 26's
    /// document reader or the text boxes, whichever reads more.
    @Test func ruledChartPhotoIsRead() async throws {
        let rows = [["Beden", "S", "M", "L"], ["Bel", "76", "80", "84"], ["İç boy", "78", "79", "80"],
                    ["Paça", "34", "36", "38"]]
        let cellW: CGFloat = 220, cellH: CGFloat = 90
        let size = CGSize(width: cellW * 4 + 40, height: cellH * CGFloat(rows.count) + 120)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let title: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 40), .foregroundColor: UIColor.black]
            ("Ürün ölçüleri (cm)" as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: title)
            let font: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 40), .foregroundColor: UIColor.black]
            UIColor.black.setStroke()
            for (r, row) in rows.enumerated() {
                for (c, text) in row.enumerated() {
                    let rect = CGRect(x: 20 + CGFloat(c) * cellW, y: 100 + CGFloat(r) * cellH, width: cellW, height: cellH)
                    UIBezierPath(rect: rect).stroke()
                    (text as NSString).draw(at: CGPoint(x: rect.minX + 20, y: rect.minY + 20), withAttributes: font)
                }
            }
        }
        let scan = try await OCRService().readSections(from: image, fit: nil)
        let chart = try #require(scan.chosen ?? scan.sections.first).chart
        let m = try #require(chart.sizes.first { $0.label == "M" })
        #expect(m.values[.waist]?.cm == 80)
        #expect(m.values[.inseam]?.cm == 79)
        #expect(m.values[.legOpening]?.cm == 36)
    }
}
