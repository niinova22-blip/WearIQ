import Foundation
import WearIQCore

public struct Point2D: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    func distance(to o: Point2D) -> Double { ((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y)).squareRoot() }
}

public enum BodyJoint: String, Codable, CaseIterable, Sendable {
    case nose, neck, leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case root, leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
}

/// Horizontal body levels measured on the person segmentation mask.
public enum BodyLevel: String, Codable, CaseIterable, Sendable {
    case chest, waist, hip, thigh
}

public struct LevelSample: Codable, Hashable, Sendable {
    /// Image row (pixels, y grows downwards).
    public var y: Double
    /// Mask width at that row in pixels (front: width, side: depth).
    /// For the thigh this is a single leg.
    public var extentPx: Double
    public init(y: Double, extentPx: Double) { self.y = y; self.extentPx = extentPx }
}

/// Everything the Vision layer extracts from one photo. Pixel units of that photo.
public struct ScanObservation: Codable, Hashable, Sendable {
    /// Top of head to floor contact on the segmentation mask.
    public var personHeightPx: Double
    /// Floor contact row.
    public var floorY: Double
    public var joints: [BodyJoint: Point2D]
    public var levels: [BodyLevel: LevelSample]
    /// Highest row of the gap between the legs, if the mask shows it.
    public var crotchY: Double?

    public init(personHeightPx: Double, floorY: Double, joints: [BodyJoint: Point2D],
                levels: [BodyLevel: LevelSample], crotchY: Double? = nil) {
        self.personHeightPx = personHeightPx
        self.floorY = floorY
        self.joints = joints
        self.levels = levels
        self.crotchY = crotchY
    }
}

public enum BodyMeasurementError: Error, Equatable {
    case invalidHeight
    case personNotFullyVisible
}

/// Turns front/side scan observations into body measurements with uncertainty.
///
/// The user's typed height is the only scale reference, so its error propagates to
/// every value. Girths cannot be seen in a photo; they are estimated as an ellipse from
/// front width and side depth, which is why they carry the largest uncertainty.
/// Default coefficients are literature-based starting points and must be calibrated
/// with the tape-measure validation set before release.
public struct BodyMeasurementEngine: Sendable {
    public struct Calibration: Sendable {
        /// Vision shoulder joints sit inside the acromion; bi-acromial width is wider.
        public var shoulderJointToBiacromial = 1.10
        /// Torso cross sections are closer to rounded rectangles than ellipses, so a pure
        /// ellipse underestimates the perimeter.
        public var girthShapeFactor: [BodyLevel: Double] = [.chest: 1.06, .waist: 1.02, .hip: 1.03, .thigh: 1.0]
        /// Typical depth/width ratio used when no side photo exists.
        public var fallbackDepthRatio: [BodyLevel: Double] = [.chest: 0.72, .waist: 0.78, .hip: 0.80, .thigh: 1.0]
        /// Relative model error (1σ) per measurement kind.
        public var lengthRelError = 0.025
        public var widthRelError = 0.05
        public var girthRelErrorWithSide = 0.05
        public var girthRelErrorFrontOnly = 0.09
        public init() {}
    }

    public var calibration: Calibration

    public init(calibration: Calibration = Calibration()) {
        self.calibration = calibration
    }

    public func measure(heightCm: Double, heightUncertaintyCm: Double = 1.0,
                        front: ScanObservation, side: ScanObservation?) throws -> BodyProfile {
        guard (100...250).contains(heightCm) else { throw BodyMeasurementError.invalidHeight }
        guard front.personHeightPx > 0, front.joints[.leftAnkle] != nil || front.joints[.rightAnkle] != nil else {
            throw BodyMeasurementError.personNotFullyVisible
        }
        let scale = heightCm / front.personHeightPx
        let heightRel = heightUncertaintyCm / heightCm
        var p = BodyProfile()
        p[.height] = MeasuredValue(cm: heightCm, uncertaintyCm: heightUncertaintyCm, source: .userProvided)

        func value(_ cm: Double, _ rel: Double) -> MeasuredValue {
            // Model error and scale error are independent → add in quadrature.
            let r = (rel * rel + heightRel * heightRel).squareRoot()
            return MeasuredValue(cm: cm, uncertaintyCm: cm * r, source: .scan)
        }

        let j = front.joints
        if let l = j[.leftShoulder], let r = j[.rightShoulder] {
            p[.shoulderWidth] = value(l.distance(to: r) * scale * calibration.shoulderJointToBiacromial, calibration.widthRelError)
        }

        let arms = [(BodyJoint.leftShoulder, BodyJoint.leftElbow, BodyJoint.leftWrist), (.rightShoulder, .rightElbow, .rightWrist)]
            .compactMap { s, e, w -> Double? in
                guard let s = j[s], let e = j[e], let w = j[w] else { return nil }
                return s.distance(to: e) + e.distance(to: w)
            }
        if !arms.isEmpty {
            // Left/right disagreement is extra evidence of error.
            let mean = arms.reduce(0, +) / Double(arms.count)
            let spread = arms.count == 2 ? abs(arms[0] - arms[1]) / mean / 2 : calibration.lengthRelError
            p[.armLength] = value(mean * scale, max(calibration.lengthRelError, spread))
        }

        if let waist = front.levels[.waist] {
            if let neck = j[.neck] {
                p[.torsoLength] = value((waist.y - neck.y) * scale, calibration.lengthRelError * 1.5)
            }
            p[.outseam] = value((front.floorY - waist.y) * scale, calibration.lengthRelError)
        }

        if let crotch = front.crotchY {
            p[.inseam] = value((front.floorY - crotch) * scale, calibration.lengthRelError)
        } else if let root = j[.root] {
            // The hip joint centre sits at about 53% of stature and the crotch at about
            // 47% (ANSUR II crotch height), so crotch height ≈ 0.9 × hip joint height.
            p[.inseam] = value((front.floorY - root.y) * scale * 0.9, calibration.lengthRelError * 3)
        }

        let sideScale = side.map { heightCm / $0.personHeightPx }
        for level in BodyLevel.allCases {
            guard let f = front.levels[level] else { continue }
            let width = f.extentPx * scale
            let depth: Double
            let rel: Double
            if let side, let s = side.levels[level], let sideScale {
                depth = s.extentPx * sideScale
                rel = calibration.girthRelErrorWithSide
            } else {
                depth = width * (calibration.fallbackDepthRatio[level] ?? 0.8)
                rel = calibration.girthRelErrorFrontOnly
            }
            let girth = Self.ellipsePerimeter(a: width / 2, b: depth / 2) * (calibration.girthShapeFactor[level] ?? 1)
            let dim: BodyDimension = switch level {
            case .chest: .chest
            case .waist: .waist
            case .hip: .hip
            case .thigh: .thigh
            }
            p[dim] = value(girth, rel)
        }
        return p
    }

    /// Ramanujan's second approximation; error < 0.01% for body-like ellipses.
    static func ellipsePerimeter(a: Double, b: Double) -> Double {
        let h = ((a - b) * (a - b)) / ((a + b) * (a + b))
        return Double.pi * (a + b) * (1 + 3 * h / (10 + (4 - 3 * h).squareRoot()))
    }
}
