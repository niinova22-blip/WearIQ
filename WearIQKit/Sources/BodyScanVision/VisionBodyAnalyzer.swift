#if canImport(Vision)
import BodyMeasurementEngine
import CoreVideo
import Foundation
import simd
import Vision

public enum VisionAnalysisError: LocalizedError {
    case noPersonFound
    case maskUnavailable

    public var errorDescription: String? {
        switch self {
        case .noPersonFound: String(localized: "No person was found in the photo.")
        case .maskUnavailable: String(localized: "The body outline could not be detected.")
        }
    }
}

/// Thin wrapper around Apple Vision. Converts Vision's normalised, bottom-left-origin
/// coordinates into the y-down coordinate systems the measurement engine uses.
public struct VisionBodyAnalyzer: Sendable {
    nonisolated(unsafe) private static let jointMap: [VNHumanBodyPoseObservation.JointName: BodyJoint] = [
        .nose: .nose, .neck: .neck,
        .leftShoulder: .leftShoulder, .rightShoulder: .rightShoulder,
        .leftElbow: .leftElbow, .rightElbow: .rightElbow,
        .leftWrist: .leftWrist, .rightWrist: .rightWrist,
        .root: .root, .leftHip: .leftHip, .rightHip: .rightHip,
        .leftKnee: .leftKnee, .rightKnee: .rightKnee,
        .leftAnkle: .leftAnkle, .rightAnkle: .rightAnkle,
    ]

    public init() {}

    /// Fast pose-only detection for live guidance. Normalised coordinates, y down.
    public func detectJoints(in buffer: CVPixelBuffer) -> [BodyJoint: DetectedJoint] {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              let points = try? observation.recognizedPoints(.all) else { return [:] }
        var result: [BodyJoint: DetectedJoint] = [:]
        for (name, joint) in Self.jointMap {
            guard let p = points[name] else { continue }
            result[joint] = DetectedJoint(Point2D(Double(p.location.x), 1 - Double(p.location.y)),
                                          confidence: Double(p.confidence))
        }
        return result
    }

    /// One frame of the 360° turn: person mask (balanced quality, fast enough for live
    /// frames), the hip centre column, and the body's axis angle.
    ///
    /// The angle comes from Vision's 3D body pose (camera-relative joint positions in
    /// metres): the hip and shoulder lines' angle against the image plane. Where 3D pose
    /// isn't available it falls back to the 2D shoulder span against the span measured
    /// facing the camera (`shoulderReference`, shoulder span / body span).
    public func turnFrame(_ buffer: CVPixelBuffer, time: Double, shoulderReference: Double?) -> RotationFrame? {
        let pose3D = VNDetectHumanBodyPose3DRequest()
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        try? handler.perform([pose3D])
        guard (try? handler.perform([segmentation])) != nil,
              let maskBuffer = segmentation.results?.first?.pixelBuffer,
              let mask = try? Self.binaryMask(from: maskBuffer) else { return nil }

        var center: Double?
        var angle: Double?
        if let body = pose3D.results?.first {
            angle = Self.axisAngle(body)
            if let root = try? body.pointInImage(.root) { center = Double(root.x) * Double(mask.width) }
        }
        if angle == nil || center == nil {
            let pose = VNDetectHumanBodyPoseRequest()
            if (try? handler.perform([pose])) != nil, let body = pose.results?.first {
                if center == nil, let root = try? body.recognizedPoint(.root), root.confidence >= 0.3 {
                    center = Double(root.location.x) * Double(mask.width)
                }
                if angle == nil, let shoulderReference { angle = Self.axisAngle(body, shoulderReference: shoulderReference) }
            }
        }
        return RotationFrame(mask: mask, centerX: center, time: time, axisAngle: angle)
    }

    /// Shoulder span over head-to-ankle span, facing the camera; the 2D fallback's reference.
    public static func shoulderRatio(_ joints: [BodyJoint: DetectedJoint]) -> Double? {
        let j = joints.filter { $0.value.confidence >= 0.3 }.mapValues(\.point)
        guard let ls = j[.leftShoulder], let rs = j[.rightShoulder], let head = j[.nose] ?? j[.neck],
              let ankle = [j[.leftAnkle], j[.rightAnkle]].compactMap({ $0?.y }).max(), ankle > head.y else { return nil }
        // Normalised x and y differ in scale (portrait 9:16 frame); convert x to y units.
        let span = abs(rs.x - ls.x) * 9 / 16
        return span / (ankle - head.y)
    }

    private static func axisAngle(_ body: VNHumanBodyPose3DObservation) -> Double? {
        func position(_ joint: VNHumanBodyPose3DObservation.JointName) -> SIMD3<Float>? {
            guard let m = try? body.cameraRelativePosition(joint) else { return nil }
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        var axis = SIMD3<Float>(repeating: 0)
        if let l = position(.leftHip), let r = position(.rightHip) { axis += r - l }
        if let l = position(.leftShoulder), let r = position(.rightShoulder) { axis += r - l }
        // x is across the image and z along the view direction; y (vertical) doesn't matter.
        let across = Double(abs(axis.x)), depth = Double(abs(axis.z))
        guard (across * across + depth * depth).squareRoot() > 0.1 else { return nil }
        return atan2(depth, across) * 180 / .pi
    }

    private static func axisAngle(_ body: VNHumanBodyPoseObservation, shoulderReference: Double) -> Double? {
        guard shoulderReference > 0, let points = try? body.recognizedPoints(.all) else { return nil }
        var joints: [BodyJoint: DetectedJoint] = [:]
        for (name, joint) in jointMap {
            guard let p = points[name] else { continue }
            joints[joint] = DetectedJoint(Point2D(Double(p.location.x), 1 - Double(p.location.y)), confidence: Double(p.confidence))
        }
        guard let ratio = shoulderRatio(joints) else { return nil }
        return acos(min(1, max(0, ratio / shoulderReference))) * 180 / .pi
    }

    /// Full analysis of a captured still: segmentation mask plus joints in mask pixels.
    public func analyze(_ image: CGImage) throws -> (mask: BinaryMask, joints: [BodyJoint: Point2D]) {
        let pose = VNDetectHumanBodyPoseRequest()
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .accurate
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([pose, segmentation])

        guard let observation = pose.results?.first else { throw VisionAnalysisError.noPersonFound }
        guard let maskBuffer = segmentation.results?.first?.pixelBuffer else { throw VisionAnalysisError.maskUnavailable }

        let mask = try Self.binaryMask(from: maskBuffer)
        let points = try observation.recognizedPoints(.all)
        var joints: [BodyJoint: Point2D] = [:]
        for (name, joint) in Self.jointMap {
            guard let p = points[name], p.confidence >= 0.3 else { continue }
            joints[joint] = Point2D(Double(p.location.x) * Double(mask.width),
                                    (1 - Double(p.location.y)) * Double(mask.height))
        }
        return (mask, joints)
    }

    private static func binaryMask(from buffer: CVPixelBuffer) throws -> BinaryMask {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw VisionAnalysisError.maskUnavailable }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let raw = UnsafeRawBufferPointer(start: base, count: bytesPerRow * height)
        return BinaryMask(width: width, height: height, bytesPerRow: bytesPerRow, bytes: raw)
    }
}
#endif
