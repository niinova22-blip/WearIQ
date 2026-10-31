import Foundation
import WearIQCore

/// Scores scans against tape measurements, per clothing group and measurement: the
/// numbers docs/VALIDATION.md asks for before any accuracy is claimed for scans in
/// clothes (mean absolute error, error spread, repeat-scan consistency, how often a scan
/// fails, and how often the stated 90% range holds the tape value).
public enum ScanValidation {
    /// One scan of one person for one measurement.
    public struct Record: Equatable, Sendable {
        public var subject: String
        /// What the person wore, e.g. "skin", "fitted", "tshirt", "loose", "layered".
        public var group: String
        public var dimension: BodyDimension
        /// nil when the scan gave no value.
        public var scanned: Double?
        public var low: Double?
        public var high: Double?
        public var tape: Double
        /// Which measuring system gave `scanned`, e.g. "current" or "bodym".
        public var system: String

        public init(subject: String, group: String, dimension: BodyDimension, scanned: Double?,
                    low: Double? = nil, high: Double? = nil, tape: Double, system: String = "current") {
            self.subject = subject; self.group = group; self.dimension = dimension
            self.scanned = scanned; self.low = low; self.high = high; self.tape = tape; self.system = system
        }
    }

    public struct Score: Equatable, Sendable {
        public var count: Int
        public var meanAbsoluteError: Double
        public var medianAbsoluteError: Double
        /// Mean of |scan − tape| / tape, per cent.
        public var meanPercentError: Double
        /// Mean signed error (scan − tape).
        public var bias: Double
        public var errorSD: Double
        /// 95th percentile of the absolute error.
        public var p95: Double
        /// Mean absolute difference between repeat scans of the same person, or nil
        /// without repeats.
        public var repeatability: Double?
        /// Share of scans without a value.
        public var failureRate: Double
        /// Share of stated ranges holding the tape value, or nil without ranges.
        public var coverage: Double?
    }

    public struct Key: Hashable, Sendable {
        public var group: String
        public var dimension: BodyDimension
        public var system: String = "current"
    }

    public static func score(_ records: [Record]) -> [Key: Score] {
        Dictionary(grouping: records) { Key(group: $0.group, dimension: $0.dimension, system: $0.system) }.mapValues(score(group:))
    }

    static func score(group records: [Record]) -> Score {
        let measured = records.compactMap { r in r.scanned.map { (r, $0 - r.tape) } }
        let errors = measured.map(\.1)
        let n = Double(max(errors.count, 1))
        let bias = errors.reduce(0, +) / n
        let mae = errors.reduce(0) { $0 + abs($1) } / n
        let sd = errors.count > 1
            ? (errors.reduce(0) { $0 + ($1 - bias) * ($1 - bias) } / Double(errors.count - 1)).squareRoot() : 0
        let sorted = errors.map(abs).sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.down)))]
        let median = sorted.isEmpty ? 0 : sorted.count % 2 == 1 ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        let percent = measured.reduce(0) { $0 + abs($1.1) / max($1.0.tape, 1) } / n * 100
        var diffs: [Double] = []
        for (_, scans) in Dictionary(grouping: measured, by: { $0.0.subject }) where scans.count > 1 {
            let values = scans.compactMap(\.0.scanned)
            for i in values.indices { for j in values.indices where j > i { diffs.append(abs(values[i] - values[j])) } }
        }
        let ranged = measured.filter { $0.0.low != nil && $0.0.high != nil }
        let covered = ranged.filter { $0.0.low! <= $0.0.tape && $0.0.tape <= $0.0.high! }.count
        return Score(count: records.count, meanAbsoluteError: mae, medianAbsoluteError: median, meanPercentError: percent,
                     bias: bias, errorSD: sd, p95: p95,
                     repeatability: diffs.isEmpty ? nil : diffs.reduce(0, +) / Double(diffs.count),
                     failureRate: Double(records.count - measured.count) / Double(max(records.count, 1)),
                     coverage: ranged.isEmpty ? nil : Double(covered) / Double(ranged.count))
    }

    /// Records from CSV with the header
    /// `subject,group,dimension,scanned,low,high,tape[,system]` (empty `scanned`, `low`,
    /// `high` allowed; `dimension` as in `BodyDimension`; `system` defaults to "current").
    public static func records(csv: String) -> [Record] {
        csv.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 7, let d = BodyDimension(rawValue: f[2]), let tape = Double(f[6]) else { return nil }
            return Record(subject: f[0], group: f[1], dimension: d, scanned: Double(f[3]),
                          low: Double(f[4]), high: Double(f[5]), tape: tape,
                          system: f.count > 7 && !f[7].isEmpty ? f[7] : "current")
        }
    }

    // MARK: Two systems on the same people

    public enum Verdict: Equatable, Sendable {
        /// Fewer people than asked for: no winner is named.
        case notEnoughPeople(have: Int, need: Int)
        case firstBetter, secondBetter, noClearDifference
    }

    /// Two systems compared on the people both measured, for one clothing group and
    /// measurement: each person's absolute error averaged over their repeat scans, then
    /// the paired difference. A winner is named only when its 95% interval excludes zero
    /// and at least `minimumPeople` took part.
    public struct Comparison: Equatable, Sendable {
        public var people: Int
        public var firstMAE: Double
        public var secondMAE: Double
        /// Mean of (first − second) absolute error per person, cm, and its 95% interval.
        public var difference: Double
        public var interval: ClosedRange<Double>
        public var verdict: Verdict
        /// Weight on the first system for a blend of the two (each with its own bias
        /// taken out) that errs least on these people; nil without enough people.
        public var blendWeight: Double?
    }

    /// Keys have `system` empty: the comparison is of `first` against `second`.
    public static func compare(_ records: [Record], first: String, second: String,
                               minimumPeople: Int = 30) -> [Key: Comparison] {
        var out: [Key: Comparison] = [:]
        let groups = Dictionary(grouping: records) { Key(group: $0.group, dimension: $0.dimension, system: "") }
        for (key, rows) in groups {
            func perPerson(_ system: String) -> [String: (abs: Double, signed: Double)] {
                let mine = rows.filter { $0.system == system }
                return Dictionary(grouping: mine, by: \.subject).compactMapValues { scans -> (abs: Double, signed: Double)? in
                    let errors = scans.compactMap { r in r.scanned.map { $0 - r.tape } }
                    guard !errors.isEmpty else { return nil }
                    let n = Double(errors.count)
                    return (errors.reduce(0) { $0 + abs($1) } / n, errors.reduce(0, +) / n)
                }
            }
            let a = perPerson(first), b = perPerson(second)
            let people = Set(a.keys).intersection(b.keys).sorted()
            guard !people.isEmpty else { continue }
            let n = Double(people.count)
            let diffs: [Double] = people.map { a[$0]!.abs - b[$0]!.abs }
            let mean = diffs.reduce(0, +) / n
            let sd = people.count > 1 ? (diffs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1)).squareRoot() : 0
            let half = 1.96 * sd / n.squareRoot()
            let interval = (mean - half)...(mean + half)
            let verdict: Verdict
            if people.count < minimumPeople {
                verdict = .notEnoughPeople(have: people.count, need: minimumPeople)
            } else if interval.upperBound < 0 {
                verdict = .firstBetter
            } else if interval.lowerBound > 0 {
                verdict = .secondBetter
            } else {
                verdict = .noClearDifference
            }
            var weight: Double?
            if people.count >= minimumPeople {
                let ea: [Double] = people.map { a[$0]!.signed }, eb: [Double] = people.map { b[$0]!.signed }
                let ma = ea.reduce(0, +) / n, mb = eb.reduce(0, +) / n
                var vaa = 0.0, vbb = 0.0, vab = 0.0
                for (x, y) in zip(ea, eb) {
                    vaa += (x - ma) * (x - ma); vbb += (y - mb) * (y - mb); vab += (x - ma) * (y - mb)
                }
                let den = vaa + vbb - 2 * vab
                weight = den > 1e-9 ? min(1, max(0, (vbb - vab) / den)) : 0.5
            }
            let firstMAE = people.reduce(0.0) { $0 + a[$1]!.abs } / n
            let secondMAE = people.reduce(0.0) { $0 + b[$1]!.abs } / n
            out[key] = Comparison(people: people.count, firstMAE: firstMAE, secondMAE: secondMAE,
                                  difference: mean, interval: interval, verdict: verdict, blendWeight: weight)
        }
        return out
    }
}
