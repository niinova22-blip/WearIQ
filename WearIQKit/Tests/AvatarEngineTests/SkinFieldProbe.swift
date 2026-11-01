import Foundation
import Testing
@testable import AvatarEngine

/// Diagnostic: where the distance field garments collide with lies inside the skin that
/// is shown (positive distance at a skin vertex), the skin shows through the cloth.
@Suite struct SkinFieldProbe {
    @Test func fieldVersusSkin() {
        guard ProcessInfo.processInfo.environment["RENDER_DIR"] != nil else { return }
        let user = Avatar.Measurements(height: 173, chest: 92, waist: 82, hip: 92, thigh: 56,
                                       shoulderWidth: 37, armLength: 56, inseam: 81)
        let model = BodyModel.make(user)
        let skin = model.mesh(cell: 0.011)
        var worst: [(Float, Vec3)] = []
        var buckets: [String: [Float]] = [:]
        for p in skin.positions {
            let d = model.distance(p)
            let band = p.y > model.waistY ? "chest" : p.y > model.crotchY ? "pelvis" : p.y > model.kneeY ? "thigh" : "shin"
            let side = p.z < 0 ? "back" : "front"
            buckets["\(band)-\(side)", default: []].append(d)
            worst.append((d, p))
        }
        for (k, v) in buckets.sorted(by: { $0.key < $1.key }) {
            let s = v.sorted()
            print("FIELD \(k): n \(s.count) p50 \(String(format: "%.1f", s[s.count / 2] * 1000))mm p95 \(String(format: "%.1f", s[s.count * 95 / 100] * 1000))mm max \(String(format: "%.1f", s.last! * 1000))mm")
        }
        for (d, p) in worst.sorted(by: { $0.0 > $1.0 }).prefix(12) {
            print("WORST \(String(format: "%.1f", d * 1000))mm at y \(String(format: "%.3f", p.y)) (waist \(String(format: "%.3f", model.waistY)), hip \(String(format: "%.3f", model.hipY)), crotch \(String(format: "%.3f", model.crotchY))) x \(String(format: "%.3f", p.x)) z \(String(format: "%.3f", p.z))")
        }
    }
}
