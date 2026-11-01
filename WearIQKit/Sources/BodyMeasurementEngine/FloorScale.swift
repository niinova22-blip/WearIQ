import Foundation

/// A camera as ARKit describes it: intrinsics in the captured image's pixels (the
/// sensor's landscape image, y down) and its pose in the world (metres, y up, gravity
/// aligned). Camera space: x along the sensor's width, y up the sensor, looking down −z.
public struct ARCameraModel: Sendable, Equatable {
    public var fx, fy, cx, cy: Double
    /// The captured image's size, pixels (landscape: width > height).
    public var sensorWidth, sensorHeight: Double
    /// Camera to world, column-major (as `simd_float4x4`'s columns, flattened).
    public var transform: [Double]

    public init(fx: Double, fy: Double, cx: Double, cy: Double, sensorWidth: Double, sensorHeight: Double, transform: [Double]) {
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.sensorWidth = sensorWidth; self.sensorHeight = sensorHeight
        self.transform = transform
    }

    /// Size of the upright picture (the back camera's image turned 90° clockwise, as a
    /// phone held upright shows it).
    public var portraitWidth: Double { sensorHeight }
    public var portraitHeight: Double { sensorWidth }

    /// A pixel of the upright picture (u right, v down) in the captured image.
    public func sensorPixel(u: Double, v: Double) -> (x: Double, y: Double) { (v, sensorHeight - u) }

    public var position: SIMD3<Double> { SIMD3(transform[12], transform[13], transform[14]) }

    /// The ray from the camera through a pixel of the upright picture, in the world.
    public func ray(u: Double, v: Double) -> (origin: SIMD3<Double>, direction: SIMD3<Double>) {
        let (x, y) = sensorPixel(u: u, v: v)
        let local = SIMD3((x - cx) / fx, -(y - cy) / fy, -1)
        let t = transform
        let world = SIMD3(t[0] * local.x + t[4] * local.y + t[8] * local.z,
                          t[1] * local.x + t[5] * local.y + t[9] * local.z,
                          t[2] * local.x + t[6] * local.y + t[10] * local.z)
        return (position, world / (world * world).sum().squareRoot())
    }

    /// Where a world point shows in the upright picture, nil behind the camera.
    public func project(_ p: SIMD3<Double>) -> (u: Double, v: Double)? {
        let t = transform
        let d = p - position
        // World to camera: the rotation's transpose.
        let local = SIMD3(t[0] * d.x + t[1] * d.y + t[2] * d.z,
                          t[4] * d.x + t[5] * d.y + t[6] * d.z,
                          t[8] * d.x + t[9] * d.y + t[10] * d.z)
        guard local.z < 0 else { return nil }
        let x = cx + fx * local.x / -local.z, y = cy - fy * local.y / -local.z
        return (sensorHeight - y, x)
    }
}

/// Real-world scale from the floor, as a tape would have it: the person's height and
/// the size of a pixel where they stand, from ARKit's floor plane and camera, without
/// the typed height.
///
/// The lowest point of the silhouette is where the front of the feet meets the floor:
/// its ray hits the floor plane there. The body's vertical line stands a little behind
/// that (the toes reach about 0.11 of stature in front of the ankles), and the top of
/// the head lies over that line, so the head's ray is cut by the vertical plane
/// through it, facing the camera. Errors: the setback (±3 cm moves the result about
/// 1%), the floor plane (ARKit: about 1 cm), the mask's top and bottom rows (hair, the
/// sole), and how upright the person stands.
public enum FloorScale {
    public struct Reading: Sendable, Equatable {
        /// Floor to the top of the head, cm.
        public var statureCm: Double
        /// From the camera to the body's vertical line, along the floor, m.
        public var distanceM: Double
        /// The body's vertical line on the floor, world.
        public var base: SIMD3<Double>
        /// Facing the camera, horizontal: the vertical plane through the body is base + span{up, this × up}.
        public var towardCamera: SIMD3<Double>
    }

    /// How far the body's vertical line stands behind the front of the feet, m.
    public static func footSetback(statureCm: Double) -> Double { 0.11 * statureCm / 100 }

    /// Height and distance from the lowest and highest silhouette points (upright
    /// picture pixels). Nil when the geometry can't be right: the feet ray doesn't
    /// reach the floor in front of the camera, or the result isn't a person's height.
    public static func measure(camera: ARCameraModel, floorY: Double, feet: (u: Double, v: Double),
                               head: (u: Double, v: Double), setbackM: Double) -> Reading? {
        let f = camera.ray(u: feet.u, v: feet.v)
        guard f.direction.y < -1e-4 else { return nil }
        let t = (floorY - f.origin.y) / f.direction.y
        guard t > 0.3, t < 12 else { return nil }
        let toe = f.origin + f.direction * t
        var flat = toe - f.origin
        flat.y = 0
        let length = (flat * flat).sum().squareRoot()
        guard length > 0.3 else { return nil }
        let away = flat / length
        let base = toe + away * setbackM
        guard let top = cut(camera.ray(u: head.u, v: head.v), base: base, normal: away) else { return nil }
        let stature = (top.y - floorY) * 100
        guard (80...250).contains(stature) else { return nil }
        return Reading(statureCm: stature, distanceM: length + setbackM, base: base, towardCamera: -away)
    }

    /// The world distance between two pixels of the upright picture, both taken on the
    /// vertical plane through the body (a silhouette's left and right edge on a row), m.
    public static func width(camera: ARCameraModel, reading: Reading, left: (u: Double, v: Double),
                             right: (u: Double, v: Double)) -> Double? {
        let normal = -reading.towardCamera
        guard let a = cut(camera.ray(u: left.u, v: left.v), base: reading.base, normal: normal),
              let b = cut(camera.ray(u: right.u, v: right.v), base: reading.base, normal: normal) else { return nil }
        let d = a - b
        return (d * d).sum().squareRoot()
    }

    private static func cut(_ ray: (origin: SIMD3<Double>, direction: SIMD3<Double>), base: SIMD3<Double>,
                            normal: SIMD3<Double>) -> SIMD3<Double>? {
        let denominator = (ray.direction * normal).sum()
        guard abs(denominator) > 1e-6 else { return nil }
        let t = ((base - ray.origin) * normal).sum() / denominator
        return t > 0 ? ray.origin + ray.direction * t : nil
    }

    /// Several frames' heights: the median, and a spread from the median absolute
    /// deviation (robust to a frame with a raised arm or a bad mask).
    public static func combine(_ statures: [Double]) -> (cm: Double, sdCm: Double)? {
        guard statures.count >= 3 else { return nil }
        let s = statures.sorted()
        let median = s[s.count / 2]
        let deviations = s.map { abs($0 - median) }.sorted()
        let mad = deviations[deviations.count / 2]
        return (median, max(0.3, 1.4826 * mad / Double(s.count).squareRoot() + 0.5))
    }
}

/// Where a standing person's silhouette reaches the floor and the top of the head, in
/// mask pixels (y down).
public struct SilhouetteKeyPoints: Sendable, Equatable {
    public var headU: Double, headV: Double
    /// The middle of the feet on the lowest rows, and the bottom edge of the lowest row.
    public var feetU: Double, feetV: Double
    /// The silhouette runs into the picture's top or bottom edge: head or feet cut off.
    public var cutOff: Bool

    /// Finds them; nil without a person-sized silhouette.
    public static func find(_ mask: BinaryMask, centerX: Double? = nil, minimumPixels: Int = 3) -> SilhouetteKeyPoints? {
        let rows = (0..<mask.height).filter { y in mask.runs(inRow: y).reduce(0) { $0 + $1.count } >= minimumPixels }
        guard let top = rows.first, let bottom = rows.last, bottom - top > mask.height / 4 else { return nil }
        let body = bottom - top
        let middle = mask.runs(inRow: top + body / 2).max { $0.count < $1.count }
        let center = centerX ?? middle.map { Double($0.lowerBound + $0.upperBound) / 2 } ?? Double(mask.width) / 2
        func near(_ run: Range<Int>) -> Double { abs(Double(run.lowerBound + run.upperBound) / 2 - center) }
        guard let head = mask.runs(inRow: top).min(by: { near($0) < near($1) }) else { return nil }
        // The feet: runs near the middle on the lowest rows (hands held out are far off).
        let feet = (max(top, bottom - 2)...bottom).flatMap { mask.runs(inRow: $0) }.filter { near($0) < 0.25 * Double(body) }
        guard let left = feet.map(\.lowerBound).min(), let right = feet.map(\.upperBound).max() else { return nil }
        return SilhouetteKeyPoints(headU: Double(head.lowerBound + head.upperBound) / 2, headV: Double(top),
                                   feetU: Double(left + right) / 2, feetV: Double(bottom + 1),
                                   cutOff: top <= 1 || bottom >= mask.height - 2)
    }
}
