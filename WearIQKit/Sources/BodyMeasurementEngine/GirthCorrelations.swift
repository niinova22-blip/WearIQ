import Foundation
import WearIQCore

/// Measured girths sharpen the estimate of unmeasured ones.
///
/// Height, weight and BMI explain most of each girth (`AnthropometricPrior`), but what
/// they leave over is partly shared: broad hips for one's height and weight go with
/// broad thighs (r ≈ 0.6 in ANSUR II), forearms with upper arms, calves with ankles.
/// Treating the leftovers as jointly normal with the correlations below
/// (scripts/fit_correlations.py) and each estimate's own SD as its spread, the
/// unmeasured girths are conditioned on the measured ones, measurement error included.
/// On ANSUR II (half fitted, half tested), the thigh error given hip and waist falls by
/// about a sixth (men 1.76 → 1.47 cm, women 1.81 → 1.51 cm mean absolute error); the
/// waist given chest and hip barely moves (3.5 → 3.4 cm), so it isn't relied on for
/// the waist.
extension AnthropometricPrior {
    static let order: [BodyDimension] = [.chest, .waist, .hip, .thigh, .neck, .upperArm, .forearm, .wrist, .knee, .calf, .ankle]
    static let correlations: [BodySex?: [[Double]]] = [
        .male: [
            [1.000, 0.209, -0.285, -0.409, 0.142, 0.023, -0.022, -0.079, -0.398, -0.296, -0.271],
            [0.209, 1.000, 0.139, -0.155, -0.042, -0.452, -0.442, -0.196, -0.217, -0.316, -0.303],
            [-0.285, 0.139, 1.000, 0.599, -0.248, -0.212, -0.279, -0.176, 0.227, 0.005, 0.011],
            [-0.409, -0.155, 0.599, 1.000, -0.284, 0.068, -0.086, -0.207, 0.353, 0.128, 0.071],
            [0.142, -0.042, -0.248, -0.284, 1.000, 0.101, 0.221, 0.155, -0.220, -0.142, -0.092],
            [0.023, -0.452, -0.212, 0.068, 0.101, 1.000, 0.646, 0.133, -0.005, 0.018, -0.021],
            [-0.022, -0.442, -0.279, -0.086, 0.221, 0.646, 1.000, 0.395, 0.035, 0.107, 0.079],
            [-0.079, -0.196, -0.176, -0.207, 0.155, 0.133, 0.395, 1.000, 0.127, 0.149, 0.325],
            [-0.398, -0.217, 0.227, 0.353, -0.220, -0.005, 0.035, 0.127, 1.000, 0.359, 0.358],
            [-0.296, -0.316, 0.005, 0.128, -0.142, 0.018, 0.107, 0.149, 0.359, 1.000, 0.588],
            [-0.271, -0.303, 0.011, 0.071, -0.092, -0.021, 0.079, 0.325, 0.358, 0.588, 1.000],
        ],
        .female: [
            [1.000, 0.373, -0.233, -0.445, 0.153, -0.088, -0.146, -0.073, -0.528, -0.422, -0.254],
            [0.373, 1.000, 0.017, -0.200, 0.031, -0.112, -0.211, -0.165, -0.422, -0.452, -0.272],
            [-0.233, 0.017, 1.000, 0.625, -0.236, -0.152, -0.229, -0.252, 0.155, -0.028, -0.064],
            [-0.445, -0.200, 0.625, 1.000, -0.285, 0.010, -0.073, -0.223, 0.339, 0.140, -0.003],
            [0.153, 0.031, -0.236, -0.285, 1.000, 0.024, 0.164, 0.183, -0.204, -0.150, -0.076],
            [-0.088, -0.112, -0.152, 0.010, 0.024, 1.000, 0.496, 0.124, 0.092, 0.031, -0.032],
            [-0.146, -0.211, -0.229, -0.073, 0.164, 0.496, 1.000, 0.455, 0.148, 0.167, 0.161],
            [-0.073, -0.165, -0.252, -0.223, 0.183, 0.124, 0.455, 1.000, 0.110, 0.158, 0.375],
            [-0.528, -0.422, 0.155, 0.339, -0.204, 0.092, 0.148, 0.110, 1.000, 0.558, 0.389],
            [-0.422, -0.452, -0.028, 0.140, -0.150, 0.031, 0.167, 0.158, 0.558, 1.000, 0.605],
            [-0.254, -0.272, -0.064, -0.003, -0.076, -0.032, 0.161, 0.375, 0.389, 0.605, 1.000],
        ],
        nil: [
            [1.000, 0.276, -0.262, -0.419, 0.142, -0.013, -0.063, -0.075, -0.457, -0.345, -0.263],
            [0.276, 1.000, 0.093, -0.171, -0.020, -0.350, -0.368, -0.185, -0.300, -0.365, -0.291],
            [-0.262, 0.093, 1.000, 0.608, -0.241, -0.192, -0.261, -0.200, 0.197, -0.007, -0.018],
            [-0.419, -0.171, 0.608, 1.000, -0.283, 0.052, -0.082, -0.212, 0.345, 0.132, 0.044],
            [0.142, -0.020, -0.241, -0.283, 1.000, 0.083, 0.207, 0.162, -0.210, -0.143, -0.086],
            [-0.013, -0.350, -0.192, 0.052, 0.083, 1.000, 0.611, 0.131, 0.025, 0.021, -0.024],
            [-0.063, -0.368, -0.261, -0.082, 0.207, 0.611, 1.000, 0.410, 0.072, 0.124, 0.104],
            [-0.075, -0.185, -0.200, -0.212, 0.162, 0.131, 0.410, 1.000, 0.119, 0.151, 0.338],
            [-0.457, -0.300, 0.197, 0.345, -0.210, 0.025, 0.072, 0.119, 1.000, 0.436, 0.371],
            [-0.345, -0.365, -0.007, 0.132, -0.143, 0.021, 0.124, 0.151, 0.436, 1.000, 0.593],
            [-0.263, -0.291, -0.018, 0.044, -0.086, -0.024, 0.104, 0.338, 0.371, 0.593, 1.000],
        ],
    ]

    /// The estimates for `targets`, conditioned on `observed` values (each with its own
    /// uncertainty). Dimensions outside the table, or without an estimate, are left out.
    public static func conditioned(_ targets: [BodyDimension], estimates: [BodyDimension: MeasuredValue],
                                   observed: [BodyDimension: MeasuredValue], sex: BodySex?) -> [BodyDimension: MeasuredValue] {
        guard let r = correlations[sex] else { return [:] }
        let obs = observed.keys.filter { order.contains($0) && estimates[$0] != nil }.sorted { $0.rawValue < $1.rawValue }
        guard !obs.isEmpty else { return [:] }
        func index(_ d: BodyDimension) -> Int { order.firstIndex(of: d)! }
        func sd(_ d: BodyDimension) -> Double { estimates[d]!.uncertaintyCm }
        // Covariance of the observations: the statistics' spread plus measurement error.
        let n = obs.count
        var soo = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n { soo[i][j] = r[index(obs[i])][index(obs[j])] * sd(obs[i]) * sd(obs[j]) }
            let e = observed[obs[i]]!.uncertaintyCm
            soo[i][i] += e * e
        }
        let residual = obs.map { observed[$0]!.cm - estimates[$0]!.cm }
        var out: [BodyDimension: MeasuredValue] = [:]
        for t in targets where order.contains(t) && observed[t] == nil {
            guard let e = estimates[t] else { continue }
            let sto = obs.map { r[index(t)][index($0)] * sd(t) * sd($0) }
            guard let w = solve(soo, sto) else { continue }
            var shift = 0.0, explained = 0.0
            for k in 0..<n {
                shift += w[k] * residual[k]
                explained += w[k] * sto[k]
            }
            let variance = max(sd(t) * sd(t) - explained, 0.04 * sd(t) * sd(t))
            out[t] = MeasuredValue(cm: e.cm + shift, uncertaintyCm: variance.squareRoot(), source: e.source)
        }
        return out
    }

    /// Solves a·x = b for a small symmetric positive-definite a (Gaussian elimination).
    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = a, v = b
        for c in 0..<n {
            guard let p = (c..<n).max(by: { abs(m[$0][c]) < abs(m[$1][c]) }), abs(m[p][c]) > 1e-12 else { return nil }
            m.swapAt(c, p)
            v.swapAt(c, p)
            for r in (c + 1)..<n {
                let f = m[r][c] / m[c][c]
                for k in c..<n { m[r][k] -= f * m[c][k] }
                v[r] -= f * v[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = v[r]
            for k in (r + 1)..<n { s -= m[r][k] * x[k] }
            x[r] = s / m[r][r]
        }
        return x
    }
}
