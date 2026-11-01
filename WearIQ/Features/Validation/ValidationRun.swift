import AvatarEngine
import BodyMeasurementEngine
import Foundation
import WearIQCore

/// Builds a validation record from a finished turn: the current engine's result as the
/// app computed it, and the silhouette-fit engine run on the same stop profiles. Only
/// in validation mode; the profile the app saves is always the current engine's.
enum ValidationRun {
    struct EngineA: Sendable {
        var profile: BodyProfile?
        var milliseconds: Double
        var memoryMB: Double?
    }

    /// Runs engine B (seconds of work; call off the main thread) and assembles the record.
    nonisolated static func record(participant: String, device: String, hasLiDAR: Bool, basics: BodyBasics,
                                   engineA: EngineA, profiles: [StopProfile], scanSeconds: Double?) -> ValidationRecord {
        var record = ValidationRecord(participant: participant, device: device, hasLiDAR: hasLiDAR,
                                      clothing: basics.attire?.rawValue ?? "unspecified", sex: basics.sex,
                                      heightCm: basics.heightCm, weightKg: basics.weightKg)
        record.scanSeconds = scanSeconds
        record.profiles = profiles.sorted { $0.station < $1.station }
        let a = MeasurementEngineID.current.rawValue, b = MeasurementEngineID.silhouetteFit.rawValue
        record.processingMs[a] = engineA.milliseconds
        record.memoryMB[a] = engineA.memoryMB
        if let profile = engineA.profile {
            var values: [BodyDimension: EngineMeasurement] = [:]
            for (d, v) in profile.values {
                let provenance: MeasurementProvenance = switch v.source {
                case .scan, .userProvided: .observed
                case .estimated: .prior
                case .manual: .tape
                }
                values[d] = EngineMeasurement(cm: v.cm, sdCm: v.uncertaintyCm, provenance: provenance)
            }
            record.set(.current, values)
        } else {
            record.failedEngines.append(a)
        }

        var input = SilhouetteBodyFit.Input(profiles: profiles, heightCm: basics.heightCm)
        input.clothingCm = SilhouetteBodyFit.clothing(fitted: basics.attire != .everyday, underwear: false)
        if let profile = engineA.profile {
            // The front photo's skeleton lengths are evidence for B too; its girths are not
            // (they're A's answer), but its body is a good place to start from.
            for d in [BodyDimension.shoulderWidth, .armLength, .inseam] where profile[d]?.source == .scan {
                input.lengths[d] = profile[d]
            }
            input.start = Avatar.Measurements(profile)
        }
        let clock = ContinuousClock()
        let started = clock.now
        let fitted = SilhouetteBodyFit.fit(input)
        let elapsed = clock.now - started
        record.processingMs[b] = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        record.memoryMB[b] = DeviceInfo.memoryFootprintMB
        if let fitted {
            record.set(.silhouetteFit, fitted.values.mapValues { EngineMeasurement(cm: $0.cm, sdCm: $0.sdCm, provenance: $0.provenance) })
            let angles = fitted.stopAngleErrors.sorted { $0.key < $1.key }.map { String(format: "%d:%+.0f°", $0.key, $0.value) }
            record.notes = String(format: "B: rms %.1f cm over %d rows, clothing %.1f/%.1f cm per edge, %d iterations; stop angles ",
                                  fitted.rmsResidualCm, fitted.rows, fitted.clothingCm.torso, fitted.clothingCm.legs, fitted.iterations)
                + angles.joined(separator: " ")
        } else {
            record.failedEngines.append(b)
        }
        return record
    }
}
