import Foundation
import WearIQCore

/// A second way to measure the eight-stop turn: instead of turning each level's widths
/// into a girth on its own (π × mean width), the SOMA-X body model is shaped until its
/// silhouettes, seen from the eight stops, have the widths the camera saw, row by row
/// from below the arms to the thighs. The measurements are then taken on that body,
/// round its cross-sections as a tape would.
///
/// What this adds over the per-level formula:
/// - Every row of every stop counts, not three levels, so one bad row matters less.
/// - The body stays a human body: its shape comes from 9,326 scanned people, so a waist
///   can't come out wider than anything plausible for the hips around it.
/// - Concave places (the small of the back) that no silhouette shows are filled in by
///   the model, not by an ellipse.
/// - Each stop may be turned a few degrees off; those angles are estimated with the shape.
/// - Clothing is a thickness on every edge, estimated too, within what the user said
///   they wear; loose clothes widen the uncertainty instead of the body.
/// - Girths the camera never sees on its own (neck, upper arm, calf) come from the
///   fitted body and are marked as the model's.
///
/// Distances are as the turn measures them: scaled by the typed height. Perspective is
/// ignored, as in the turn: the camera is about 2.5 m away and a silhouette's edges lie
/// near the body's middle plane.
public enum SilhouetteBodyFit {
    public struct Input: Sendable {
        public var profiles: [StopProfile]
        public var heightCm: Double
        /// What the clothes add on each edge of the silhouette, cm: the expected amount
        /// and how unsure that is (see `clothing(for:)`).
        public var clothingCm: (mean: Double, sd: Double) = (0.3, 0.3)
        /// Lengths measured another way (the front photo's skeleton), as further evidence:
        /// shoulder width, arm length and inseam are used.
        public var lengths: [BodyDimension: MeasuredValue] = [:]
        /// Where to start: the other method's measurements, if any.
        public var start: Avatar.Measurements?

        public init(profiles: [StopProfile], heightCm: Double) {
            self.profiles = profiles
            self.heightCm = heightCm
        }
    }

    public struct Value: Sendable, Equatable {
        public var cm: Double
        public var sdCm: Double
        public var provenance: MeasurementProvenance
    }

    public struct Result: Sendable {
        public var values: [BodyDimension: Value]
        /// The fitted shape, standard deviations per SOMA-X component.
        public var coefficients: [Double]
        /// How far each stop turned out to be from its 45° step, degrees.
        public var stopAngleErrors: [Int: Double]
        /// What the clothes added on each edge, cm, on the torso and the legs.
        public var clothingCm: (torso: Double, legs: Double)
        /// Root-mean-square gap between the fitted and the seen widths, cm.
        public var rmsResidualCm: Double
        /// Rows used, over all stops.
        public var rows: Int
        public var iterations: Int

        /// As a body profile, for the fit engine.
        public var profile: BodyProfile {
            var p = BodyProfile()
            for (d, v) in values {
                p[d] = MeasuredValue(cm: v.cm, uncertaintyCm: v.sdCm, source: v.provenance == .prior ? .estimated : .scan)
            }
            return p
        }
    }

    /// What clothes add to each edge of a silhouette, cm, for what the user wears.
    public static func clothing(fitted: Bool, underwear: Bool) -> (mean: Double, sd: Double) {
        if underwear { return (0.2, 0.2) }
        if fitted { return (0.5, 0.4) }
        return (1.5, 1.5)
    }

    // MARK: Fitting

    /// The fitted body and its measurements, or nil when the model isn't bundled or the
    /// profiles hold too little to fit (fewer than four stops, or under 40 rows).
    public static func fit(_ input: Input) -> Result? {
        guard let model = SomaModel.shared else { return nil }
        return fit(input, model: model)
    }

    static func fit(_ input: Input, model: SomaModel) -> Result? {
        let stops = input.profiles.filter { (0..<8).contains($0.station) }
        guard Set(stops.map(\.station)).count >= 4 else { return nil }
        let problem = Problem(model: model, input: input, stops: stops)
        guard problem.rowCount >= 40 else { return nil }

        // Start from the other method's body when there is one: closer, so fewer steps.
        var x = [Double](repeating: 0, count: problem.parameterCount)
        if let start = input.start {
            let c = model.coefficients(for: start.somaTarget)
            for k in 0..<model.components { x[k] = c[k] }
        }
        x[problem.clothingTorso] = input.clothingCm.mean
        x[problem.clothingLegs] = input.clothingCm.mean

        var lambda = 1e-2
        var current = problem.residuals(x)
        var cost = current.cost
        var iterations = 0
        var converged = false
        for iteration in 0..<25 where !converged {
            iterations = iteration + 1
            let jacobian = problem.jacobian(x, at: current)
            // Normal equations with robust weights: (JᵀWJ + λ·diag) Δ = −JᵀWr.
            let n = problem.parameterCount
            var a = [Double](repeating: 0, count: n * n), g = [Double](repeating: 0, count: n)
            for (row, r) in current.values.enumerated() {
                let w = current.weights[row]
                let jr = jacobian[row]
                for i in 0..<n where jr[i] != 0 {
                    g[i] += w * jr[i] * r
                    for j in i..<n where jr[j] != 0 { a[i * n + j] += w * jr[i] * jr[j] }
                }
            }
            for i in 0..<n { for j in 0..<i { a[i * n + j] = a[j * n + i] } }
            var improved = false
            for _ in 0..<6 {
                var damped = a
                for i in 0..<n { damped[i * n + i] += lambda * max(1e-6, a[i * n + i]) + 1e-9 }
                let step = SomaModel.choleskySolve(damped, g.map { -$0 }, n)
                var candidate = x
                for i in 0..<n { candidate[i] += step[i] }
                problem.clamp(&candidate)
                let trial = problem.residuals(candidate)
                if trial.cost < cost {
                    let gain = cost - trial.cost
                    x = candidate; current = trial; cost = trial.cost
                    lambda = max(1e-6, lambda * 0.3)
                    improved = true
                    converged = gain < 1e-4 * max(1, cost)
                    break
                }
                lambda *= 8
            }
            if !improved || lambda > 1e6 { break }
        }

        // How sure: the posterior covariance from the final normal equations.
        let jacobian = problem.jacobian(x, at: current)
        let n = problem.parameterCount
        var a = [Double](repeating: 0, count: n * n)
        for (row, jr) in jacobian.enumerated() {
            let w = current.weights[row]
            for i in 0..<n where jr[i] != 0 { for j in 0..<n where jr[j] != 0 { a[i * n + j] += w * jr[i] * jr[j] } }
        }
        for i in 0..<n { a[i * n + i] += 1e-9 }
        let covariance = (0..<n).map { k -> [Double] in
            var e = [Double](repeating: 0, count: n)
            e[k] = 1
            return SomaModel.choleskySolve(a, e, n)
        }

        let c = Array(x[0..<model.components])
        let v = model.vertices(c)
        let measured = model.measure(v)
        let dims: [BodyDimension] = [.height, .chest, .waist, .hip, .thigh, .shoulderWidth, .armLength, .inseam]
        var values: [BodyDimension: Value] = [:]
        let k = model.components
        for (r, d) in dims.enumerated() {
            // Spread through the model's linear measurement map, plus how well that map
            // predicts the measurement, plus the typed height's own ±1 cm scaling it.
            var variance = 0.0
            for i in 0..<k { for j in 0..<k { variance += model.b[r * k + i] * covariance[i][j] * model.b[r * k + j] } }
            variance += model.residualSD[r] * model.residualSD[r] * 0.25
            variance += (measured[r] / input.heightCm) * (measured[r] / input.heightCm)
            let observed: Bool = switch d {
            case .chest, .waist, .hip: true
            case .thigh: problem.thighRows > 0
            case .height: true
            default: input.lengths[d] != nil
            }
            values[d] = Value(cm: measured[r], sdCm: variance.squareRoot(), provenance: observed ? .observed : .model)
        }
        // The outseam (waist to floor) from the fitted body's navel.
        let floor = v.map(\.y).min() ?? 0
        values[.outseam] = Value(cm: Double(v[model.points.navel].y - floor) * 100, sdCm: 2, provenance: .model)
        for (d, value) in model.limbGirths(v) { values[d] = Value(cm: value.cm, sdCm: value.sd, provenance: .model) }

        var angles: [Int: Double] = [:]
        for (index, stop) in problem.stops.enumerated() { angles[stop.station] = x[problem.angleBase + index] * 180 / .pi }
        return Result(values: values, coefficients: c, stopAngleErrors: angles,
                      clothingCm: (x[problem.clothingTorso], x[problem.clothingLegs]),
                      rmsResidualCm: current.rmsWidth, rows: problem.rowCount, iterations: iterations)
    }

    // MARK: The least-squares problem

    /// Parameters: the shape components, one angle error per stop (radians), and the
    /// clothing thickness on the torso and on the legs (cm per edge). Residuals: each
    /// seen width against the fitted one, the typed height, the other lengths, and the
    /// priors (components ~ N(0, 1), angles ~ N(0, 8°), clothing ~ what the user wears).
    struct Problem {
        let model: SomaModel
        let input: Input
        let stops: [StopProfile]
        let angleBase: Int, clothingTorso: Int, clothingLegs: Int, parameterCount: Int
        /// Mesh edges between vertices of the torso and legs, and of each leg.
        let bodyEdges: [(Int, Int)], legEdges: [[(Int, Int)]]
        /// Seen widths are this sure, cm: segmentation edges, and neighbouring rows that
        /// share their errors.
        let widthSD = 1.5
        let angleSD = 8 * Double.pi / 180
        let rowCount: Int, thighRows: Int

        init(model: SomaModel, input: Input, stops: [StopProfile]) {
            self.model = model
            self.input = input
            self.stops = stops
            angleBase = model.components
            clothingTorso = angleBase + stops.count
            clothingLegs = clothingTorso + 1
            parameterCount = clothingLegs + 1
            func edges(_ keep: Set<SomaModel.Part>) -> [(Int, Int)] {
                var seen = Set<Int>(), out: [(Int, Int)] = []
                let t = model.triangles, v = model.mean.count
                for k in stride(from: 0, to: t.count - 2, by: 3) {
                    for (a, b) in [(t[k], t[k + 1]), (t[k + 1], t[k + 2]), (t[k + 2], t[k])] {
                        let i = Int(min(a, b)), j = Int(max(a, b))
                        guard keep.contains(model.parts[i]), keep.contains(model.parts[j]), seen.insert(i * v + j).inserted else { continue }
                        out.append((i, j))
                    }
                }
                return out
            }
            bodyEdges = edges(SomaModel.girthParts)
            legEdges = [edges([.leftLeg]), edges([.rightLeg])]
            rowCount = stops.reduce(0) { $0 + $1.torso.compactMap { $0 }.count }
                + stops.reduce(0) { sum, s in sum + Self.thighObservations(s).count }
            thighRows = stops.reduce(0) { sum, s in sum + Self.thighObservations(s).count }
        }

        /// Which thigh readings a stop gives: both legs apart from the front or back, the
        /// legs' outer width side-on. Diagonals mix the two and are left out.
        static func thighObservations(_ stop: StopProfile) -> [(row: Int, perLeg: Bool, cm: Double)] {
            var out: [(Int, Bool, Double)] = []
            for (row, f) in SilhouetteRows.thigh.enumerated() where row < stop.legs.count {
                _ = f
                switch stop.station % 4 {
                case 0 where stop.legs[row].count == 2:
                    out.append((row, true, (stop.legs[row][0] + stop.legs[row][1]) / 2))
                case 2:
                    if row < stop.legsOuter.count, let w = stop.legsOuter[row] { out.append((row, false, w)) }
                default: break
                }
            }
            return out
        }

        func clamp(_ x: inout [Double]) {
            for k in 0..<model.components { x[k] = max(-3.5, min(3.5, x[k])) }
            for i in angleBase..<clothingTorso { x[i] = max(-0.5, min(0.5, x[i])) }
            for i in [clothingTorso, clothingLegs] { x[i] = max(0, min(8, x[i])) }
        }

        struct Residuals {
            var values: [Double]
            var weights: [Double]
            /// Whether the slot had both a seen and a fitted width (slots are fixed, so
            /// the residuals of two shapes line up one to one).
            var valid: [Bool]
            /// Which residuals are widths (the rest are priors and lengths).
            var widthCount: Int
            var cost: Double {
                var s = 0.0
                for i in values.indices { s += weights[i] * values[i] * values[i] }
                return s
            }
            var rmsWidth: Double = 0
        }

        /// Cross-section points of the body at each row, for one shape.
        struct Sections {
            var torso: [[(Float, Float)]?]
            var legs: [[[(Float, Float)]]?]
            var height: Double
        }

        func sections(_ c: [Double]) -> Sections {
            let v = model.vertices(c)
            let floor = v.map(\.y).min() ?? 0
            let top = v[model.points.top].y
            let h = top - floor
            let crotch = v[model.points.crotch].y
            func cut(_ y: Float, _ edges: [(Int, Int)]) -> [(Float, Float)] {
                var out: [(Float, Float)] = []
                for (i, j) in edges {
                    let a = v[i], b = v[j]
                    guard (a.y - y) * (b.y - y) < 0 else { continue }
                    let f = (y - a.y) / (b.y - a.y)
                    out.append((a.x + (b.x - a.x) * f, a.z + (b.z - a.z) * f))
                }
                return out
            }
            // Torso rows only above the crotch (below it the run through the middle is
            // the gap between the legs), thigh rows only below it.
            let torso = SilhouetteRows.torso.map { f -> [(Float, Float)]? in
                let y = top - Float(f) * h
                return y > crotch + 0.01 * h ? cut(y, bodyEdges) : nil
            }
            let legs = SilhouetteRows.thigh.map { f -> [[(Float, Float)]]? in
                let y = top - Float(f) * h
                return y < crotch - 0.01 * h ? legEdges.map { cut(y, $0) } : nil
            }
            return Sections(torso: torso, legs: legs, height: Double(h) * 100 * model.calibration[0])
        }

        static func width(_ points: [(Float, Float)], angle: Double) -> Double? {
            guard points.count >= 3 else { return nil }
            let c = Float(cos(angle)), s = Float(sin(angle))
            var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
            for p in points {
                let x = p.0 * c + p.1 * s
                lo = min(lo, x); hi = max(hi, x)
            }
            return Double(hi - lo) * 100
        }

        func residuals(_ x: [Double], sections given: Sections? = nil) -> Residuals {
            let s = given ?? sections(Array(x[0..<model.components]))
            var values: [Double] = [], weights: [Double] = [], valid: [Bool] = []
            var squares = 0.0, widths = 0
            func add(_ r: Double, robust: Bool) {
                values.append(r)
                valid.append(true)
                // Huber: rows far off (an arm in the way, a segmentation slip) count less.
                weights.append(robust ? min(1, 2.5 / max(abs(r), 1e-9)) : 1)
            }
            func skip() {
                values.append(0); weights.append(0); valid.append(false)
            }
            for (index, stop) in stops.enumerated() {
                let angle = Double(stop.station) * .pi / 4 + x[angleBase + index]
                for (row, seen) in stop.torso.enumerated() {
                    guard let seen else { continue }
                    guard row < s.torso.count, let points = s.torso[row],
                          let w = Self.width(points, angle: angle) else { skip(); continue }
                    let gap = w + 2 * x[clothingTorso] - seen
                    squares += gap * gap; widths += 1
                    add(gap / widthSD, robust: true)
                }
                for (row, perLeg, seen) in Self.thighObservations(stop) {
                    guard row < s.legs.count, let legs = s.legs[row] else { skip(); continue }
                    let w: Double?
                    if perLeg {
                        let both = legs.compactMap { Self.width($0, angle: angle) }
                        w = both.count == 2 ? (both[0] + both[1]) / 2 : nil
                    } else {
                        w = Self.width(legs[0] + legs[1], angle: angle)
                    }
                    guard let w else { skip(); continue }
                    let gap = w + 2 * x[clothingLegs] - seen
                    squares += gap * gap; widths += 1
                    add(gap / widthSD, robust: true)
                }
            }
            let widthCount = values.count
            // The typed height is the ruler of every width: the body must have it.
            add((s.height - input.heightCm) / 0.7, robust: false)
            // Lengths from the skeleton, through the model's linear map.
            let k = model.components
            for (r, d) in [(5, BodyDimension.shoulderWidth), (6, .armLength), (7, .inseam)] {
                guard let m = input.lengths[d] else { continue }
                var predicted = model.m0[r]
                for i in 0..<k { predicted += model.b[r * k + i] * x[i] }
                add((predicted - m.cm) / max(1, m.uncertaintyCm), robust: true)
            }
            for i in 0..<k { add(x[i], robust: false) }
            for i in angleBase..<clothingTorso { add(x[i] / angleSD, robust: false) }
            let cloth = input.clothingCm
            for i in [clothingTorso, clothingLegs] { add((x[i] - cloth.mean) / max(0.1, cloth.sd), robust: false) }
            var result = Residuals(values: values, weights: weights, valid: valid, widthCount: widthCount)
            result.rmsWidth = widths > 0 ? (squares / Double(widths)).squareRoot() : 0
            return result
        }

        /// Numerical derivatives; the angle and clothing ones reuse the body's sections.
        func jacobian(_ x: [Double], at base: Residuals) -> [[Double]] {
            let n = parameterCount
            var columns = [[Double]](repeating: [], count: n)
            let shape = Array(x[0..<model.components])
            let baseSections = sections(shape)
            for p in 0..<n {
                let h = p < model.components ? 0.02 : (p < clothingTorso ? 0.005 : 0.05)
                var moved = x
                moved[p] += h
                let r = p < model.components ? residuals(moved) : residuals(moved, sections: baseSections)
                // Rows can come and go at the crotch; derivatives only where both have them.
                columns[p] = base.values.indices.map { i in
                    i < r.values.count && r.valid[i] && base.valid[i] ? (r.values[i] - base.values[i]) / h : 0
                }
            }
            return (0..<base.values.count).map { row in (0..<n).map { columns[$0][row] } }
        }
    }
}

// MARK: - Limb girths on the fitted body

extension SomaModel {
    /// Girths the camera doesn't see on their own, on the fitted body, round a cut
    /// across the limb as a tape goes: neck at its base, upper arm halfway from shoulder
    /// to elbow, forearm a quarter of the way down from the elbow, wrist, knee, and calf
    /// at its widest. Both sides averaged. Model estimates, with a spread for each.
    func limbGirths(_ v: [Vec3]) -> [BodyDimension: (cm: Double, sd: Double)] {
        func cross(_ center: Vec3, _ normal: Vec3, _ keep: Set<Part>, radius: Float) -> Double {
            let n = normal.normalized
            let helper = abs(n.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
            let u = n.cross(helper).normalized, w = n.cross(u)
            var points: [(Float, Float)] = []
            for t in stride(from: 0, to: triangles.count - 2, by: 3) {
                let ids = [Int(triangles[t]), Int(triangles[t + 1]), Int(triangles[t + 2])]
                guard ids.contains(where: { keep.contains(parts[$0]) }) else { continue }
                for (i, j) in [(ids[0], ids[1]), (ids[1], ids[2]), (ids[2], ids[0])] {
                    let da = (v[i] - center).dot(n), db = (v[j] - center).dot(n)
                    guard da * db < 0 else { continue }
                    let p = v[i] + (v[j] - v[i]) * (da / (da - db))
                    let d = p - center
                    guard d.length < radius else { continue }
                    points.append((d.dot(u), d.dot(w)))
                }
            }
            return Double(Self.hullPerimeter(points)) * 100
        }
        var out: [BodyDimension: (Double, Double)] = [:]
        // The neck: round the seam between the head part and the torso, its base.
        let neckCentre = centroid(rings.neck, v)
        let tilt = Vec3(0, 1, 0.25).normalized
        let nu = tilt.cross(Vec3(1, 0, 0)).normalized, nw = tilt.cross(nu)
        let ring = rings.neck.map { i -> (Float, Float) in let d = v[i] - neckCentre; return (d.dot(nu), d.dot(nw)) }
        out[.neck] = (Double(Self.hullPerimeter(ring)) * 100, 1.5)
        var upper = 0.0, fore = 0.0, wrist = 0.0
        for (s, arm) in [(0, Part.leftArm), (1, .rightArm)] {
            let shoulder = centroid(rings.shoulder[s], v), elbow = centroid(rings.elbow[s], v), w = centroid(rings.wrist[s], v)
            upper += cross(shoulder + (elbow - shoulder) * 0.5, elbow - shoulder, [arm], radius: 0.1) / 2
            fore += cross(elbow + (w - elbow) * 0.25, w - elbow, [arm], radius: 0.08) / 2
            wrist += cross(w + (elbow - w) * 0.05, elbow - w, [arm], radius: 0.06) / 2
        }
        out[.upperArm] = (upper, 1.5)
        out[.forearm] = (fore, 1.2)
        out[.wrist] = (wrist, 0.8)
        var knee = 0.0, calf = 0.0
        for (s, leg) in [(0, Part.leftLeg), (1, .rightLeg)] {
            let k = centroid(rings.knee[s], v), a = centroid(rings.ankle[s], v)
            knee += cross(k + Vec3(0, 0.03, 0), k - a, [leg], radius: 0.1) / 2
            var widest = 0.0
            for f in stride(from: Float(0.15), through: 0.5, by: 0.05) {
                widest = max(widest, cross(k + (a - k) * f, k - a, [leg], radius: 0.1))
            }
            calf += widest / 2
        }
        out[.knee] = (knee, 1.5)
        out[.calf] = (calf, 1.5)
        return out
    }
}
