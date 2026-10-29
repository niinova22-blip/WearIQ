import Foundation

/// A detected joint in normalised image coordinates (0–1, y grows downwards).
public struct DetectedJoint: Sendable, Hashable {
    public var point: Point2D
    public var confidence: Double
    public init(_ point: Point2D, confidence: Double) {
        self.point = point
        self.confidence = confidence
    }
}

public enum ScanPose: String, Sendable {
    case front, side
}

/// What the user must fix before a photo is usable, in priority order.
public enum PoseIssue: String, Sendable, Equatable {
    case noPerson
    case headNotVisible
    case feetNotVisible
    case tooClose
    case tooFar
    case notCentered
    case notFacingCamera
    case armsTooCloseToBody
    case notSideways
}

/// Live checks on the camera feed so that captured photos are measurable.
public struct PoseGuidance: Sendable {
    public var minConfidence = 0.3
    /// Fraction of image height the body (head to ankles) should cover.
    public var minBodySpan = 0.55
    public var maxBodySpan = 0.92
    /// Width / height of the camera frame (portrait 1080×1920).
    public var frameAspect = 9.0 / 16.0

    public init() {}

    /// Returns `nil` when the pose is good enough to capture.
    public func issue(for joints: [BodyJoint: DetectedJoint], pose: ScanPose) -> PoseIssue? {
        let j = joints.filter { $0.value.confidence >= minConfidence }.mapValues(\.point)
        guard !j.isEmpty else { return .noPerson }

        let headY = [j[.nose], j[.neck]].compactMap { $0?.y }.min()
        guard let headY else { return .headNotVisible }
        let ankles = [j[.leftAnkle], j[.rightAnkle]].compactMap { $0 }
        guard let ankleY = ankles.map(\.y).max() else { return .feetNotVisible }

        // The nose sits well below the top of the head; leave room above it.
        if headY < 0.06 { return .headNotVisible }
        if ankleY > 0.97 { return .feetNotVisible }
        let span = ankleY - headY
        if span > maxBodySpan { return .tooClose }
        if span < minBodySpan { return .tooFar }

        let xs = j.values.map(\.x)
        let centerX = (xs.min()! + xs.max()!) / 2
        if abs(centerX - 0.5) > 0.15 { return .notCentered }

        guard let ls = j[.leftShoulder], let rs = j[.rightShoulder] else {
            return pose == .front ? .notFacingCamera : nil
        }
        let shoulderSpan = abs(ls.x - rs.x)
        switch pose {
        case .front:
            // Shoulders of a front-facing adult span roughly 0.2× body height.
            if shoulderSpan < 0.12 * span { return .notFacingCamera }
            // Upper arms angled out (A-pose) so the chest rows don't run into the arms:
            // at least ~15° from vertical, in pixel units of a portrait frame.
            for (s, e) in [(j[.leftShoulder], j[.leftElbow]), (j[.rightShoulder], j[.rightElbow])] {
                guard let s, let e, e.y > s.y else { continue }
                if abs(e.x - s.x) * frameAspect / (e.y - s.y) < 0.27 { return .armsTooCloseToBody }
            }
            // Wrists must be clear of the hips so the waist/hip rows only contain torso.
            if let lh = j[.leftHip], let rh = j[.rightHip], let lw = j[.leftWrist], let rw = j[.rightWrist] {
                let hipHalf = abs(lh.x - rh.x) / 2
                let mid = (lh.x + rh.x) / 2
                let clearance = 0.6 * hipHalf
                if abs(lw.x - mid) < hipHalf + clearance || abs(rw.x - mid) < hipHalf + clearance {
                    return .armsTooCloseToBody
                }
            }
        case .side:
            if shoulderSpan > 0.08 * span { return .notSideways }
        }
        return nil
    }
}
