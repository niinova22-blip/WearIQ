import Foundation
import Testing
@testable import AvatarEngine

/// A garment's mesh is open only where it is cut open: trousers at the waist and the
/// hems, a top at the neckline, the hem and the cuffs. An open edge anywhere else is a
/// hole, the body showing through (as loose trousers had at the back, where the seat
/// stood out past the box the cut was meshed in). Tried from tight to very loose.
@Suite struct GarmentIntegrityTests {
    let user = Avatar.Measurements(height: 173, chest: 92, waist: 82, hip: 92, thigh: 56,
                                   shoulderWidth: 37, armLength: 56, inseam: 81)

    /// Vertices on edges only one triangle uses.
    static func openVertices(_ mesh: Mesh) -> [Vec3] {
        var count: [Int: Int] = [:]
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            for e in 0..<3 {
                let a = Int(mesh.indices[t + e]), b = Int(mesh.indices[t + (e + 1) % 3])
                count[min(a, b) << 32 | max(a, b), default: 0] += 1
            }
        }
        return count.filter { $0.value == 1 }.flatMap { [mesh.positions[$0.key >> 32], mesh.positions[$0.key & 0xFFFF_FFFF]] }
    }

    @Test(arguments: [(-6.0, 4.0, 6.0), (2, 7, 9), (14, 14, 18), (3, 14, 20), (20, 24, 28)])
    func trousersOpenOnlyAtWaistAndHems(waist: Double, hip: Double, thigh: Double) {
        var f = Avatar.GarmentFit(kind: .trousers)
        f.waistEase = waist; f.hipEase = hip; f.thighEase = thigh; f.lengthDelta = 2
        let model = BodyModel.make(user)
        let waistband = (model.waistY + model.hipY) / 2
        let mesh = Avatar(user, garment: f, detail: .preview).layers[0].mesh
        let lowest = mesh.positions.map(\.y).min() ?? 0
        let stray = Self.openVertices(mesh).filter { p in abs(p.y - waistband) > 0.03 && p.y > lowest + 0.06 }
        #expect(stray.isEmpty, "open edge away from the waist and hems at \(stray.prefix(3).map { "(\($0.x), \($0.y), \($0.z))" })")
    }

    @Test(arguments: [(-4.0, 0.0), (6, 0), (12, 4), (30, 10), (40, 14)])
    func topsOpenOnlyAtNeckHemAndCuffs(chest: Double, shoulder: Double) {
        var f = Avatar.GarmentFit(kind: .top(longSleeves: false))
        f.chestEase = chest; f.waistEase = chest + 3; f.hipEase = chest + 3; f.shoulderDelta = shoulder; f.lengthDelta = 3
        let model = BodyModel.make(user)
        let mesh = Avatar(user, garment: f, detail: .preview).layers[0].mesh
        let lowest = mesh.positions.map(\.y).min() ?? 0
        let stray = Self.openVertices(mesh).filter { p in
            // Not the hem, not the neckline (its cutting plane, lower at the front), not a sleeve.
            p.y > lowest + 0.06 && model.neckline.normal.dot(p) < model.neckline.offset - 0.03 && abs(p.x) < model.chest.0 + 0.04
        }
        #expect(stray.isEmpty, "open edge away from the neck, hem and cuffs at \(stray.prefix(3).map { "(\($0.x), \($0.y), \($0.z))" })")
    }

    /// The box-clipping hole, put back: with the old box (the body's bounds only) very
    /// loose trousers did open at the back. Kept as a check that the test can see it.
    @Test func looseSeatStaysClosedAtTheBack() {
        var f = Avatar.GarmentFit(kind: .trousers)
        f.waistEase = 14; f.hipEase = 14; f.thighEase = 18
        let mesh = Avatar(user, garment: f, detail: .standard).layers[0].mesh
        let model = BodyModel.make(user)
        let waistband = (model.waistY + model.hipY) / 2
        let back = Self.openVertices(mesh).filter { $0.z < -0.05 && $0.y < waistband - 0.03 && $0.y > model.crotchY }
        #expect(back.isEmpty)
    }
}
