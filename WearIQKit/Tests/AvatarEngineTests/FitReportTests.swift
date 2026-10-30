import Foundation
import Testing
@testable import AvatarEngine

@Suite struct FitReportTests {
    let me = Avatar.Measurements(height: 173, chest: 90, waist: 83.5, hip: 89, thigh: 56.9,
                                 shoulderWidth: 37.6, armLength: 56.4, inseam: 83.4)

    /// A plain T-shirt cut for chest girths of S, M and L on this body.
    func tee(chestEase: Double) -> Avatar.GarmentFit {
        var fit = Avatar.GarmentFit(kind: .top(longSleeves: false))
        fit.chestEase = chestEase
        fit.waistEase = chestEase + 2
        fit.hipEase = chestEase + 2
        fit.fabric = .cottonJersey
        return fit
    }

    @Test func zonesComeFromTheDrape() {
        let avatar = Avatar(me, garment: tee(chestEase: 10), detail: .preview)
        for zone in [FitZone.shoulder, .chest, .back, .waist, .sleeve] { #expect(avatar.fitReport[zone] != nil, "\(zone)") }
        #expect(avatar.fitReport[.thigh] == nil)
        let trousers = Avatar(me, garment: Avatar.GarmentFit(kind: .trousers), detail: .preview)
        for zone in [FitZone.waist, .hip, .thigh, .knee, .hem] { #expect(trousers.fitReport[zone] != nil, "\(zone)") }
    }

    @Test func smallMediumLargeDrapeDifferently() {
        let drapes = Avatar.compare(sizes: [("S", tee(chestEase: -6)), ("M", tee(chestEase: 6)), ("L", tee(chestEase: 18))], body: me)
        let chest = drapes.map { $0.zones[.chest]!.stretchUsed }
        #expect(chest[0] > chest[1] + 0.5)
        // Larger: stands further off the body.
        #expect(drapes[2].zones[.waist]!.gapCm > drapes[1].zones[.waist]!.gapCm)
        #expect(drapes[0].zones[.chest]!.tension >= .tight)
        #expect(drapes[1].zones[.chest]!.tension == .comfortable)
        #expect(drapes[2].zones[.waist]!.tension == .loose)
        #expect(Avatar.best(drapes)?.label == "M")
    }

    @Test func uncertainWaistGivesARange() {
        // A garment that's right on the edge at the waist: whether it pulls depends on the
        // waist, which the scan only knows to within a range.
        var fit = Avatar.GarmentFit(kind: .trousers)
        fit.waistEase = 0
        fit.fabric = .denim
        let drape = Avatar.compare(sizes: [("32", fit)], body: me, low: me.with(waist: 78), high: me.with(waist: 89))[0]
        let waist = drape.range[.waist]!
        #expect(waist.lowerBound < waist.upperBound)
        #expect(drape.uncertainZones.contains(.waist))
        // The body certain: one verdict.
        let sure = Avatar.compare(sizes: [("32", fit)], body: me)[0]
        #expect(sure.uncertainZones.isEmpty)
    }

    @Test func stretchFabricTakesTheSameCutMoreEasily() {
        var fit = tee(chestEase: -5)
        fit.fabric = .cottonShirting
        let woven = Avatar(me, garment: fit, detail: .preview).fitReport[.chest]!
        fit.fabric = .stretchJersey
        let stretchy = Avatar(me, garment: fit, detail: .preview).fitReport[.chest]!
        #expect(stretchy.tension < woven.tension)
    }

    @Test func fabricsDiffer() {
        #expect(Fabric.denim.density > 2 * Fabric.cottonShirting.density)
        #expect(Fabric.denim.drape > Fabric.cottonShirting.drape)
        #expect(Fabric.polyester.friction < Fabric.linen.friction)
        #expect(Fabric.wool.thickness > Fabric.polyester.thickness)
        #expect(Fabric.stretchJersey.stretchLimit > Fabric.cottonJersey.stretchLimit)
    }

    @Test func classification() {
        #expect(ZoneReport.classify(stretchUsed: 1.2, contactShare: 1, gapCm: 0) == .veryTight)
        #expect(ZoneReport.classify(stretchUsed: 0.7, contactShare: 1, gapCm: 0) == .tight)
        #expect(ZoneReport.classify(stretchUsed: 0.4, contactShare: 1, gapCm: 0) == .slightlyTight)
        #expect(ZoneReport.classify(stretchUsed: 0.1, contactShare: 0.8, gapCm: 0.3) == .comfortable)
        #expect(ZoneReport.classify(stretchUsed: 0, contactShare: 0.1, gapCm: 3) == .loose)
    }
}
