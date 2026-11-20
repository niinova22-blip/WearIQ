import BodyMeasurementEngine
import CoreGraphics
import simd
import Vision

/// Vision's 3D body pose on the front photo, for validation records in test builds only.
/// The measurement never uses it: first the tape has to show it's better than what is there.
enum Pose3DReader {
    nonisolated static func read(_ image: CGImage) -> Pose3DReading? {
        let request = VNDetectHumanBodyPose3DRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first,
              let points = try? observation.recognizedPoints(.all) else { return nil }
        let height = Double(observation.bodyHeight)
        guard height > 0 else { return nil }

        func position(_ joint: VNHumanBodyPose3DObservation.JointName) -> SIMD3<Float>? {
            guard let p = points[joint] else { return nil }
            let t = p.position.columns.3
            return SIMD3(t.x, t.y, t.z)
        }
        func distance(_ a: VNHumanBodyPose3DObservation.JointName, _ b: VNHumanBodyPose3DObservation.JointName) -> Double? {
            guard let p = position(a), let q = position(b) else { return nil }
            return Double(simd_distance(p, q))
        }
        func leg(_ hip: VNHumanBodyPose3DObservation.JointName, _ knee: VNHumanBodyPose3DObservation.JointName,
                 _ ankle: VNHumanBodyPose3DObservation.JointName) -> Double? {
            guard let upper = distance(hip, knee), let lower = distance(knee, ankle) else { return nil }
            return upper + lower
        }
        let legs = [leg(.leftHip, .leftKnee, .leftAnkle), leg(.rightHip, .rightKnee, .rightAnkle)].compactMap { $0 }
        let legFraction = legs.isEmpty ? nil : legs.reduce(0, +) / Double(legs.count) / height
        let shoulderFraction = distance(.leftShoulder, .rightShoulder).map { $0 / height }
        return Pose3DReading(heightCm: height * 100, measured: observation.heightEstimation == .measured,
                             legFraction: legFraction, shoulderFraction: shoulderFraction, joints: points.count)
    }
}
