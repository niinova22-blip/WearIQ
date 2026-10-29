import Foundation
import WearIQCore

/// Learns how this user's scans differ from their own tape measurements: whenever a
/// scanned value is replaced with a tape value on the review screen, the ratio is kept
/// (last five per measurement), and later scans are corrected by it. Optional: without
/// tape values nothing changes.
///
/// The correction is the median ratio, shrunk towards 1 while there are few of them
/// (one tape value moves the scan half-way) and limited to ±15%, so a typo can't wreck
/// later scans.
enum TapeCalibration {
    private static let key = "tapeCalibration"
    private static let kept = 5
    static let calibrated: Set<BodyDimension> = [
        .chest, .waist, .hip, .thigh, .shoulderWidth, .armLength, .torsoLength, .inseam, .outseam,
    ]

    private static var ratios: [String: [Double]] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let stored = try? JSONDecoder().decode([String: [Double]].self, from: data) else { return [:] }
            return stored
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    /// `scanned` is the value shown, which may already include the correction.
    static func record(_ d: BodyDimension, scanned: Double, tape: Double) {
        guard calibrated.contains(d), scanned > 0, tape > 0 else { return }
        let raw = scanned / factor(d)
        let ratio = tape / raw
        guard (0.7...1.3).contains(ratio) else { return }  // a different measurement, not a correction
        var all = ratios
        all[d.rawValue, default: []].append(ratio)
        all[d.rawValue] = Array(all[d.rawValue]!.suffix(kept))
        ratios = all
    }

    static func factor(_ d: BodyDimension) -> Double {
        guard let values = ratios[d.rawValue], !values.isEmpty else { return 1 }
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        let n = Double(values.count)
        let shrunk = 1 + (median - 1) * n / (n + 1)
        return min(1.15, max(0.85, shrunk))
    }

    /// Corrects the scanned values of a new profile.
    static func apply(to profile: inout BodyProfile) {
        for d in calibrated {
            guard let v = profile[d], v.source == .scan else { continue }
            let f = factor(d)
            guard f != 1 else { continue }
            profile[d] = MeasuredValue(cm: v.cm * f, uncertaintyCm: v.uncertaintyCm, source: .scan)
        }
    }

    /// Measurements currently corrected, for the review screen.
    static var active: [BodyDimension] {
        calibrated.filter { factor($0) != 1 }.sorted { $0.rawValue < $1.rawValue }
    }
}
