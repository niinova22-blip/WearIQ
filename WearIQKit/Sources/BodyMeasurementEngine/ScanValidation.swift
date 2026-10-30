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

        public init(subject: String, group: String, dimension: BodyDimension, scanned: Double?,
                    low: Double? = nil, high: Double? = nil, tape: Double) {
            self.subject = subject; self.group = group; self.dimension = dimension
            self.scanned = scanned; self.low = low; self.high = high; self.tape = tape
        }
    }

    public struct Score: Equatable, Sendable {
        public var count: Int
        public var meanAbsoluteError: Double
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
    }

    public static func score(_ records: [Record]) -> [Key: Score] {
        Dictionary(grouping: records) { Key(group: $0.group, dimension: $0.dimension) }.mapValues(score(group:))
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
        var diffs: [Double] = []
        for (_, scans) in Dictionary(grouping: measured, by: { $0.0.subject }) where scans.count > 1 {
            let values = scans.compactMap(\.0.scanned)
            for i in values.indices { for j in values.indices where j > i { diffs.append(abs(values[i] - values[j])) } }
        }
        let ranged = measured.filter { $0.0.low != nil && $0.0.high != nil }
        let covered = ranged.filter { $0.0.low! <= $0.0.tape && $0.0.tape <= $0.0.high! }.count
        return Score(count: records.count, meanAbsoluteError: mae, bias: bias, errorSD: sd, p95: p95,
                     repeatability: diffs.isEmpty ? nil : diffs.reduce(0, +) / Double(diffs.count),
                     failureRate: Double(records.count - measured.count) / Double(max(records.count, 1)),
                     coverage: ranged.isEmpty ? nil : Double(covered) / Double(ranged.count))
    }

    /// Records from CSV with the header
    /// `subject,group,dimension,scanned,low,high,tape` (empty `scanned`, `low`, `high`
    /// allowed; `dimension` as in `BodyDimension`).
    public static func records(csv: String) -> [Record] {
        csv.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 7, let d = BodyDimension(rawValue: f[2]), let tape = Double(f[6]) else { return nil }
            return Record(subject: f[0], group: f[1], dimension: d, scanned: Double(f[3]),
                          low: Double(f[4]), high: Double(f[5]), tape: tape)
        }
    }
}
