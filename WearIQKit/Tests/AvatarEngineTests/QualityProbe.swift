import Foundation
import Testing
@testable import AvatarEngine

/// Prints zone reports and final positions of a few outfits, to compare engine versions.
@Suite struct QualityProbe {
    @Test func dump() throws {
        guard let dir = ProcessInfo.processInfo.environment["QUALITY_OUT"] else { return }
        let me = Avatar.Measurements(height: 173, chest: 90, waist: 83.5, hip: 89, thigh: 56.9,
                                     shoulderWidth: 37.6, armLength: 56.4, inseam: 83.4)
        var tee = Avatar.GarmentFit(kind: .top(longSleeves: false))
        tee.chestEase = 12; tee.waistEase = 14; tee.hipEase = 14; tee.fabric = .cottonJersey
        var tight = Avatar.GarmentFit(kind: .top(longSleeves: true))
        tight.chestEase = -4; tight.waistEase = -2; tight.hipEase = 0; tight.fabric = .stretchJersey
        var jeans = Avatar.GarmentFit(kind: .trousers); jeans.fabric = .denim
        var loose = Avatar.GarmentFit(kind: .trousers); loose.fabric = .woven
        loose.hipEase = 14; loose.thighEase = 16; loose.waistEase = 4
        var out = ""
        for (name, fits) in [("tee+jeans", [tee, jeans]), ("tight", [tight]), ("loose", [loose])] {
            let a = Avatar(me, garments: fits, detail: .animated)
            for (k, layer) in a.layers.enumerated() {
                for zone in layer.fitReport.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                    let r = layer.fitReport[zone]!
                    out += String(format: "%@ L%d %@ %@ stretch %.2f contact %.2f gap %.2f\n", name, k, zone.rawValue,
                                  String(describing: r.tension), r.stretchPercent, r.contactShare, r.gapCm)
                }
                out += "\(name) L\(k) frames \(layer.frames.count) verts \(layer.mesh.positions.count)\n"
                let ps = layer.mesh.positions.map { "\($0.x) \($0.y) \($0.z)" }.joined(separator: "\n")
                try ps.write(toFile: dir + "/\(name)-\(k).txt", atomically: true, encoding: .utf8)
            }
        }
        try out.write(toFile: dir + "/report.txt", atomically: true, encoding: .utf8)
    }
}
