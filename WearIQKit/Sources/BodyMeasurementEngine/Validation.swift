import Foundation
import WearIQCore

/// The measuring methods being compared.
public enum MeasurementEngineID: String, Codable, CaseIterable, Sendable {
    /// The eight-stop turn as the app measures it today: π × mean width per level, with
    /// the front photo's lengths, the population statistics and the clothing step.
    case current = "A"
    /// The SOMA-X body fitted to the same turn's silhouettes (`SilhouetteBodyFit`).
    case silhouetteFit = "B"
    /// The girth model trained on synthetic turns (`LearnedGirthModel`): chest, waist, hip.
    case learned = "C"
}

/// One engine's value for one measurement.
public struct EngineMeasurement: Codable, Sendable, Equatable {
    public var cm: Double
    public var sdCm: Double
    public var provenance: MeasurementProvenance

    public init(cm: Double, sdCm: Double, provenance: MeasurementProvenance) {
        self.cm = cm
        self.sdCm = sdCm
        self.provenance = provenance
    }
}

/// One scan of one person, measured by every engine, with what a tape said.
///
/// Anonymous: the participant is a code the person running the test chooses ("P07"),
/// and no picture is kept, only each stop's widths (so later engines can be run on the
/// same scan). Records made up for testing are marked synthetic and never counted with
/// real ones.
public struct ValidationRecord: Codable, Sendable, Identifiable, Equatable {
    public var id = UUID()
    public var participant: String
    public var createdAt = Date()
    /// Made up (a test or a simulation), not a person measured with a tape.
    public var isSynthetic = false
    public var device: String
    public var hasLiDAR: Bool
    /// What the person wore: `ScanAttire`'s raw value, or a free description.
    public var clothing: String
    public var sex: BodySex?
    public var heightCm: Double
    public var weightKg: Double?
    /// Tape measurements, cm, by `BodyDimension` raw value.
    public var tape: [String: Double] = [:]
    /// Each engine's measurements, by engine then `BodyDimension` raw value.
    public var engines: [String: [String: EngineMeasurement]] = [:]
    /// Engines that ran but gave no result.
    public var failedEngines: [String] = []
    /// From the start of the turn to its last stop, seconds.
    public var scanSeconds: Double?
    /// Each engine's computing time, milliseconds, and the app's memory footprint after it, MB.
    public var processingMs: [String: Double] = [:]
    public var memoryMB: [String: Double] = [:]
    /// The turn's stop profiles, to run future engines on this very scan.
    public var profiles: [StopProfile] = []
    /// The person's height measured from ARKit's floor and camera, when that was done.
    public var arScale: ARScaleReading?
    /// Engine C's feature vectors for this turn, by level: with the tape values they are
    /// real training examples for the next model (scripts/scan_training/train.py --real).
    public var turnFeatures: [String: [Double]]?
    public var notes: String?

    public init(participant: String, device: String, hasLiDAR: Bool, clothing: String, sex: BodySex?,
                heightCm: Double, weightKg: Double?) {
        self.participant = participant
        self.device = device
        self.hasLiDAR = hasLiDAR
        self.clothing = clothing
        self.sex = sex
        self.heightCm = heightCm
        self.weightKg = weightKg
    }

    public func tape(_ d: BodyDimension) -> Double? { tape[d.rawValue] }
    public func value(_ engine: MeasurementEngineID, _ d: BodyDimension) -> EngineMeasurement? {
        engines[engine.rawValue]?[d.rawValue]
    }

    public mutating func setTape(_ d: BodyDimension, _ cm: Double?) { tape[d.rawValue] = cm }

    public mutating func set(_ engine: MeasurementEngineID, _ values: [BodyDimension: EngineMeasurement]) {
        engines[engine.rawValue] = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }

    /// Absolute error of an engine against the tape, cm; nil without both.
    public func error(_ engine: MeasurementEngineID, _ d: BodyDimension) -> Double? {
        guard let t = tape(d), let v = value(engine, d) else { return nil }
        return v.cm - t
    }
}

/// Height measured with ARKit (`FloorScale`): a real-world scale that doesn't come from
/// the typed height.
public struct ARScaleReading: Codable, Sendable, Equatable {
    public var statureCm: Double
    public var sdCm: Double
    /// Camera to the body's vertical line, m.
    public var distanceM: Double
    /// Frames combined.
    public var samples: Int
    /// The LiDAR's median distance to the front of the body, m, where there is LiDAR.
    public var lidarDistanceM: Double?
    /// Share of frames ARKit tracked normally while measuring.
    public var trackingNormalShare: Double
    /// ARKit recognised the plane as a floor (not just a horizontal surface).
    public var floorClassified: Bool

    public init(statureCm: Double, sdCm: Double, distanceM: Double, samples: Int, lidarDistanceM: Double?,
                trackingNormalShare: Double, floorClassified: Bool) {
        self.statureCm = statureCm
        self.sdCm = sdCm
        self.distanceM = distanceM
        self.samples = samples
        self.lidarDistanceM = lidarDistanceM
        self.trackingNormalShare = trackingNormalShare
        self.floorClassified = floorClassified
    }
}

/// How the engines did against the tape, over the real records that have tape values.
public struct ValidationReport: Sendable {
    /// The measurements compared, in the order a tailor takes them.
    public static let dimensions: [BodyDimension] = [
        .chest, .waist, .hip, .shoulderWidth, .neck, .upperArm, .forearm, .wrist,
        .thigh, .calf, .inseam, .armLength, .height,
    ]

    public struct Stats: Sendable, Equatable {
        /// Records with both a tape value and this engine's value.
        public var n: Int
        public var meanAbsoluteError: Double
        public var medianAbsoluteError: Double
        /// Mean absolute error as a share of the tape value, per cent.
        public var meanPercentError: Double
        /// Mean signed error: + the engine reads large.
        public var bias: Double
        public var maxAbsoluteError: Double
    }

    /// Per engine and measurement.
    public var stats: [MeasurementEngineID: [BodyDimension: Stats]]
    /// Per engine and measurement: the pooled spread of repeated scans of the same
    /// participant (standard deviation, cm); only participants scanned twice or more count.
    public var repeatability: [MeasurementEngineID: [BodyDimension: Double]]
    /// Per engine: share of scans it gave no result for.
    public var failureRate: [MeasurementEngineID: Double]
    public var meanProcessingMs: [MeasurementEngineID: Double]
    public var meanMemoryMB: [MeasurementEngineID: Double]
    public var meanScanSeconds: Double?
    /// Scale: the ARKit height and the typed height against the tape height.
    public var arHeight: Stats?
    public var typedHeight: Stats?
    /// Real records counted, and distinct participants among them.
    public var records: Int
    public var participants: Int
    /// Synthetic records present but left out.
    public var syntheticLeftOut: Int

    public init(_ all: [ValidationRecord]) {
        let real = all.filter { !$0.isSynthetic }
        syntheticLeftOut = all.count - real.count
        records = real.count
        participants = Set(real.map(\.participant)).count
        var stats: [MeasurementEngineID: [BodyDimension: Stats]] = [:]
        var repeatability: [MeasurementEngineID: [BodyDimension: Double]] = [:]
        var failure: [MeasurementEngineID: Double] = [:], processing: [MeasurementEngineID: Double] = [:]
        var memory: [MeasurementEngineID: Double] = [:]
        for engine in MeasurementEngineID.allCases {
            for d in Self.dimensions {
                let errors = real.compactMap { r -> (Double, Double)? in
                    guard let e = r.error(engine, d), let t = r.tape(d), t > 0 else { return nil }
                    return (e, t)
                }
                guard !errors.isEmpty else { continue }
                let abs = errors.map { Swift.abs($0.0) }.sorted()
                stats[engine, default: [:]][d] = Stats(
                    n: errors.count,
                    meanAbsoluteError: abs.reduce(0, +) / Double(abs.count),
                    medianAbsoluteError: abs.count % 2 == 1 ? abs[abs.count / 2] : (abs[abs.count / 2 - 1] + abs[abs.count / 2]) / 2,
                    meanPercentError: errors.map { Swift.abs($0.0) / $0.1 * 100 }.reduce(0, +) / Double(errors.count),
                    bias: errors.map(\.0).reduce(0, +) / Double(errors.count),
                    maxAbsoluteError: abs.last ?? 0)
                // Within-participant spread, pooled: sqrt of the mean within-person variance.
                let byPerson = Dictionary(grouping: real.compactMap { r in r.value(engine, d).map { (r.participant, $0.cm) } }, by: \.0)
                let variances = byPerson.values.filter { $0.count >= 2 }.map { group -> Double in
                    let v = group.map(\.1), m = v.reduce(0, +) / Double(v.count)
                    return v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count - 1)
                }
                if !variances.isEmpty {
                    repeatability[engine, default: [:]][d] = (variances.reduce(0, +) / Double(variances.count)).squareRoot()
                }
            }
            let ran = real.filter { $0.engines[engine.rawValue] != nil || $0.failedEngines.contains(engine.rawValue) }
            if !ran.isEmpty {
                failure[engine] = Double(ran.filter { $0.failedEngines.contains(engine.rawValue) }.count) / Double(ran.count)
            }
            let times = real.compactMap { $0.processingMs[engine.rawValue] }
            if !times.isEmpty { processing[engine] = times.reduce(0, +) / Double(times.count) }
            let mem = real.compactMap { $0.memoryMB[engine.rawValue] }
            if !mem.isEmpty { memory[engine] = mem.reduce(0, +) / Double(mem.count) }
        }
        self.stats = stats
        self.repeatability = repeatability
        failureRate = failure
        meanProcessingMs = processing
        meanMemoryMB = memory
        arHeight = Self.stats(real.compactMap { r in r.tape(.height).flatMap { t in r.arScale.map { ($0.statureCm - t, t) } } })
        typedHeight = Self.stats(real.compactMap { r in r.tape(.height).map { (r.heightCm - $0, $0) } })
        let scans = real.compactMap(\.scanSeconds)
        meanScanSeconds = scans.isEmpty ? nil : scans.reduce(0, +) / Double(scans.count)
    }

    /// Statistics of (signed error, tape value) pairs.
    static func stats(_ errors: [(Double, Double)]) -> Stats? {
        guard !errors.isEmpty else { return nil }
        let abs = errors.map { Swift.abs($0.0) }.sorted()
        return Stats(n: errors.count,
                     meanAbsoluteError: abs.reduce(0, +) / Double(abs.count),
                     medianAbsoluteError: abs.count % 2 == 1 ? abs[abs.count / 2] : (abs[abs.count / 2 - 1] + abs[abs.count / 2]) / 2,
                     meanPercentError: errors.map { Swift.abs($0.0) / $0.1 * 100 }.reduce(0, +) / Double(errors.count),
                     bias: errors.map(\.0).reduce(0, +) / Double(errors.count),
                     maxAbsoluteError: abs.last ?? 0)
    }

    /// Mean absolute error over every measurement both engines have, cm.
    public func overallMAE(_ engine: MeasurementEngineID) -> Double? {
        let all = stats[engine]?.values.map(\.meanAbsoluteError) ?? []
        return all.isEmpty ? nil : all.reduce(0, +) / Double(all.count)
    }
}

/// Which engine a measurement should come from, decided only by real tape comparisons.
public enum EngineDecision: Equatable, Sendable {
    /// Not enough real participants yet, or no clear difference: the current engine stays.
    case undecided(participants: Int, needed: Int)
    case keepCurrent(advantageCm: Double)
    case useSilhouetteFit(advantageCm: Double)
    case useLearned(advantageCm: Double)

    /// The engine production should use: the current one unless another is shown better.
    public var engine: MeasurementEngineID {
        switch self {
        case .useSilhouetteFit: .silhouetteFit
        case .useLearned: .learned
        default: .current
        }
    }
}

public enum EngineSelection {
    /// Participants needed before any decision.
    public static let minimumParticipants = 20

    /// Per measurement: paired over participants (each person's errors averaged over
    /// their scans), the mean of |B − tape| − |A − tape|. B is chosen only when it is
    /// smaller by at least `margin` cm and its 95% interval stays below zero; A is kept
    /// when it is as clearly better; otherwise undecided, and A stays.
    public static func decide(_ d: BodyDimension, records: [ValidationRecord], margin: Double = 0.3,
                              challenger: MeasurementEngineID = .silhouetteFit) -> EngineDecision {
        let real = records.filter { !$0.isSynthetic }
        var perPerson: [String: [Double]] = [:]
        for r in real {
            guard let a = r.error(.current, d), let b = r.error(challenger, d) else { continue }
            perPerson[r.participant, default: []].append(abs(b) - abs(a))
        }
        let diffs = perPerson.values.map { $0.reduce(0, +) / Double($0.count) }
        guard diffs.count >= minimumParticipants else {
            return .undecided(participants: diffs.count, needed: minimumParticipants)
        }
        let mean = diffs.reduce(0, +) / Double(diffs.count)
        let sd = (diffs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(diffs.count - 1)).squareRoot()
        let half = 2.09 * sd / Double(diffs.count).squareRoot() // t(0.975, ~19 df)
        if mean <= -margin, mean + half < 0 {
            return challenger == .learned ? .useLearned(advantageCm: -mean) : .useSilhouetteFit(advantageCm: -mean)
        }
        if mean >= margin, mean - half > 0 { return .keepCurrent(advantageCm: mean) }
        return .undecided(participants: diffs.count, needed: minimumParticipants)
    }

    /// Every compared measurement's decision; the hybrid falls out of this when the
    /// engines win different measurements.
    public static func decisions(_ records: [ValidationRecord]) -> [BodyDimension: EngineDecision] {
        Dictionary(uniqueKeysWithValues: ValidationReport.dimensions.map { d in
            // Each challenger against the current engine; a proven one wins (C, the more
            // accurate in simulation, first when both are).
            let c = decide(d, records: records, challenger: .learned)
            if case .useLearned = c { return (d, c) }
            return (d, decide(d, records: records, challenger: .silhouetteFit))
        })
    }
}

extension ValidationRecord {
    /// The records as CSV, one row per record and measurement, for a spreadsheet.
    public static func csv(_ records: [ValidationRecord]) -> String {
        var lines = ["participant,date,synthetic,device,lidar,clothing,sex,height_cm,weight_kg,measurement,tape_cm,"
            + "A_cm,A_sd,A_source,B_cm,B_sd,B_source,A_error_cm,B_error_cm,scan_s,A_ms,B_ms,ar_height_cm,ar_distance_m,"
            + "C_cm,C_sd,C_error_cm"]
        let date = ISO8601DateFormatter()
        func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        for r in records {
            for d in ValidationReport.dimensions {
                let a = r.value(.current, d), b = r.value(.silhouetteFit, d), c = r.value(.learned, d)
                guard r.tape(d) != nil || a != nil || b != nil || c != nil else { continue }
                lines.append([q(r.participant), date.string(from: r.createdAt), r.isSynthetic ? "1" : "0", q(r.device),
                              r.hasLiDAR ? "1" : "0", q(r.clothing), r.sex?.rawValue ?? "", f(r.heightCm), f(r.weightKg),
                              d.rawValue, f(r.tape(d)), f(a?.cm), f(a?.sdCm), a?.provenance.rawValue ?? "",
                              f(b?.cm), f(b?.sdCm), b?.provenance.rawValue ?? "",
                              f(r.error(.current, d)), f(r.error(.silhouetteFit, d)), f(r.scanSeconds),
                              f(r.processingMs[MeasurementEngineID.current.rawValue]),
                              f(r.processingMs[MeasurementEngineID.silhouetteFit.rawValue]),
                              f(r.arScale?.statureCm), r.arScale.map { String(format: "%.2f", $0.distanceM) } ?? "",
                              f(c?.cm), f(c?.sdCm), f(r.error(.learned, d))].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
