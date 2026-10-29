#if canImport(Vision)
import BodyMeasurementEngine
import CoreVideo
import Foundation
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

    /// One frame of the guided turn: person mask (balanced quality, fast enough for live
    /// frames), the joints, and the hip centre column when the pose is visible.
    public func turnFrame(_ buffer: CVPixelBuffer, time: Double) -> RotationFrame? {
        let pose = VNDetectHumanBodyPoseRequest()
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        guard (try? handler.perform([pose, segmentation])) != nil,
              let maskBuffer = segmentation.results?.first?.pixelBuffer,
              let mask = try? Self.binaryMask(from: maskBuffer) else { return nil }
        var center: Double?
        var joints: [BodyJoint: Point2D] = [:]
        if let observation = pose.results?.first, let points = try? observation.recognizedPoints(.all) {
            for (name, joint) in Self.jointMap {
                guard let p = points[name], p.confidence >= 0.3 else { continue }
                joints[joint] = Point2D(Double(p.location.x), 1 - Double(p.location.y))
            }
            center = joints[.root].map { $0.x * Double(mask.width) }
        }
        return RotationFrame(mask: mask, centerX: center, time: time, joints: joints)
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
