import Foundation
import Testing
@testable import AvatarEngine
import WearIQCore

/// Garments sit as their cut says: skinny legs close to the ankle, straight legs as wide
/// at the hem as at the knee, wide legs widest; an oversized top in its right size is
/// oversized, not loose.
@Suite struct CutTests {
    let me = Avatar.Measurements(height: 173, chest: 90, waist: 83.5, hip: 89, thigh: 56.9,
                                 shoulderWidth: 37.6, armLength: 56.4, inseam: 83.4)

    func trousers(_ cut: LegCut?, thigh: Double) -> Avatar.GarmentFit {
        var f = Avatar.GarmentFit(kind: .trousers)
        f.waistEase = 1.5; f.hipEase = 7; f.thighEase = thigh; f.legCut = cut
        return f
    }

    /// Width of the right trouser leg (x > 0) at a height, metres.
    func width(_ mesh: Mesh, at y: Float) -> Float {
        let band = mesh.positions.filter { abs($0.y - y) < 0.012 && $0.x > 0.01 }
        guard let lo = band.map(\.x).min(), let hi = band.map(\.x).max() else { return 0 }
        return hi - lo
    }

    @Test func legCutsOrderTheirHems() {
        let model = BodyModel.make(me)
        let calf = model.ankleY + 0.1
        let knee = model.kneeY
        var hem: [String: Float] = [:], atKnee: [String: Float] = [:]
        for (name, cut, thigh) in [("skinny", LegCut.skinny, 2.0), ("regular", nil, 9), ("straight", .straight, 9),
                                   ("wide", .wide, 18), ("flare", .flare, 5)] as [(String, LegCut?, Double)] {
            let mesh = Avatar(me, garment: trousers(cut, thigh: thigh), detail: .preview).layers[0].mesh
            hem[name] = width(mesh, at: calf)
            atKnee[name] = width(mesh, at: knee)
        }
        #expect(hem["skinny"]! < hem["regular"]!)
        #expect(hem["regular"]! < hem["straight"]!)
        #expect(hem["straight"]! < hem["wide"]!)
        // A flare is close at the knee and opens below it.
        #expect(atKnee["flare"]! < atKnee["straight"]!)
        #expect(hem["flare"]! > atKnee["flare"]! * 0.95)
    }

    @Test func oversizedTopIsNotLoose() {
        var over = Avatar.GarmentFit(kind: .top(longSleeves: false))
        over.chestEase = 30; over.waistEase = 34; over.hipEase = 34; over.shoulderDelta = 8
        over.fabric = .cottonJersey
        let asRegular = over
        over.cut = .oversized
        let oversized = Avatar(me, garment: over, detail: .preview)
        let regular = Avatar(me, garment: asRegular, detail: .preview)
        func looseShare(_ a: Avatar) -> Double {
            let tones = a.layers[0].mesh.tones
            return Double(tones.filter { $0 == .loose }.count) / Double(tones.count)
        }
        #expect(looseShare(oversized) < 0.05)
        #expect(looseShare(regular) > 0.3)
        #expect(oversized.fitReport[.chest]?.tension != .loose)
        #expect(oversized.fitReport[.shoulder]?.tension != .loose)
    }
}
