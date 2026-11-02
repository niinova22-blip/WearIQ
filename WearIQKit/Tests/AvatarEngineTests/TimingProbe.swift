import Foundation
import Testing
@testable import AvatarEngine

/// How long building and dressing an avatar takes, phase by phase (run with -O).
@Suite struct TimingProbe {
    let me = Avatar.Measurements(height: 173, chest: 90, waist: 83.5, hip: 89, thigh: 56.9,
                                 shoulderWidth: 37.6, armLength: 56.4, inseam: 83.4)

    func time<T>(_ label: String, _ f: () -> T) -> T {
        let start = Date()
        let v = f()
        print(String(format: "TIMING %@: %.3f s", label, Date().timeIntervalSince(start)))
        return v
    }

    @Test func phases() {
        guard ProcessInfo.processInfo.environment["TIMING"] != nil else { return }
        var tee = Avatar.GarmentFit(kind: .top(longSleeves: false))
        tee.chestEase = 12; tee.waistEase = 14; tee.hipEase = 14
        tee.fabric = .cottonJersey
        var jeans = Avatar.GarmentFit(kind: .trousers)
        jeans.fabric = .denim
        let model = time("BodyModel.make") { BodyModel.make(me) }
        _ = time("body mesh") { model.mesh(cell: 0.011) }
        _ = time("bare Avatar") { Avatar(me) }
        _ = time("tee settle") { model.dress(tee, cell: 0.014) }
        _ = time("tee animated") { model.dress(tee, cell: 0.014, animated: true) }
        _ = time("jeans animated") { model.dress(jeans, cell: 0.014, animated: true) }
        _ = time("outfit animated") { Avatar(me, garments: [tee, jeans], detail: .animated) }
    }
}
