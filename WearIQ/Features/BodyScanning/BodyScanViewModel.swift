import AVFoundation
import BodyMeasurementEngine
import BodyScanVision
import Observation
import WearIQCore

/// Front photo → guided turn in eight stops → on-device analysis.
///
/// The user props the phone up and steps back, so capture is hands-free: once the
/// pose has been good for a moment a countdown starts, and spoken cues tell the user
/// what to fix. The front photo gives lengths and shoulder width. Girths come from a
/// clockwise turn in eight stops 45° apart (see `StationScan`), arms held straight out
/// to the sides. Each stop has one plain spoken instruction; the outstretched arms show
/// how far the user has turned (`StopGuide`), so a stop is only taken when the user
/// stands still in the right place, and they are told to turn further, turn back or
/// open their arms otherwise. Height/weight statistics are only used to catch failed
/// detections, never as values. Images and masks live only in memory.
@MainActor
@Observable
final class BodyScanViewModel {
    enum Stage: Equatable {
        case positioning(PoseIssue?)
        case countdown(Int)
        /// Recording the turn; 0–1.
        case turning(Double)
        case analyzing
        case failed(String)
        /// Measured; "scan complete" is shown and spoken before moving on.
        case completed
        case finished
    }

    /// What the turn overlay draws.
    struct TurnState: Equatable {
        /// The stop the user is asked to stand at, 0–7.
        var station = 0
        var captured: Set<Int> = []
        var measured: Set<BodyLevel> = []
        /// Latest outline of the person, normalised image coordinates.
        var reading: FrameReading?
        /// The user is holding still at a new stop; it is about to be captured.
        var holding = false
        /// How the user's current position matches the stop, while holding still.
        var fit: StopFit?
    }

    private(set) var pose: ScanPose = .front
    private(set) var stage: Stage = .positioning(.noPerson)
    private(set) var result: BodyProfile?
    /// Values measured before a failure, so the user can keep them and add the rest.
    private(set) var partialResult: BodyProfile?
    private(set) var turn = TurnState()
    /// Joints seen while positioning for the front photo, normalised (y down), for the overlay.
    private(set) var liveJoints: [BodyJoint: Point2D] = [:]
    var voiceGuidance = true {
        didSet { audio.isEnabled = voiceGuidance }
    }
    /// After the front photo the next capture is the turn.
    private(set) var turnNext = false

    let camera = CameraController()
    let basics: BodyBasics
    private let vision = VisionBodyAnalyzer()
    /// The turn is done with the arms straight out, spanning about the body height; the
    /// user stands far enough back for them to fit in the portrait frame.
    private let guidance: PoseGuidance = {
        var guidance = PoseGuidance()
        guidance.minBodySpan = 0.45
        guidance.maxBodySpan = 0.66
        return guidance
    }()
    private let audio = ScanAudio()

    private var goodSince: Date?
    private var countdownTask: Task<Void, Never>?
    private var front: Task<FrontAnalysis, Error>?
    private var scan = StationScan()
    private var stillness = StillnessDetector()
    private var turnStart = Date()
    private var stationStart = Date()
    /// Arm span and shoulder separation at the front stop; later stops are judged against them.
    private var spanReference = 1.0
    private var shoulderReference: Double?
    private var levelFractions: [BodyLevel: Double] = [:]
    /// A stop's still is being measured.
    private var capturing = false
    private var lastHintAt = Date.distantPast

    /// Pose problems are spoken once they have lasted this long, so flickering
    /// detections don't produce a stream of half-finished sentences.
    private var pendingIssue: PoseIssue?
    private var pendingSince = Date()
    private var lastSpokenIssue: PoseIssue?
    private var lastSpokenAt = Date.distantPast

    /// How long the pose must be held before the countdown starts.
    private let holdDuration: TimeInterval = 1.0
    private let maxTurnDuration: TimeInterval = 150
    private let defaultFractions: [BodyLevel: Double] = [.chest: 0.27, .waist: 0.39, .hip: 0.5]

    init(basics: BodyBasics) {
        self.basics = basics
    }

    func start() async {
        audio.start()
        watchPose()
        do {
            try await camera.start(position: .front)
            audio.say(String(localized: "Stand facing the phone, arms slightly away from your body."), priority: .high)
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    func stop() {
        countdownTask?.cancel()
        camera.onFrame = nil
        camera.stop()
        audio.stop()
    }

    func retry() {
        countdownTask?.cancel()
        front?.cancel()
        front = nil
        scan = StationScan()
        stillness.reset()
        turn = TurnState()
        result = nil
        partialResult = nil
        turnNext = false
        pose = .front
        goodSince = nil
        stage = .positioning(.noPerson)
        watchPose()
    }

    private func watchPose() {
        let vision = vision
        camera.frameRate = 5
        camera.onFrame = { [weak self] buffer in
            let joints = vision.detectJoints(in: buffer)
            Task { @MainActor in self?.handle(joints) }
        }
    }

    private func handle(_ joints: [BodyJoint: DetectedJoint]) {
        switch stage {
        case .positioning, .countdown: break
        default: return
        }
        liveJoints = joints.filter { $0.value.confidence >= 0.3 }.mapValues(\.point)
        let issue = guidance.issue(for: joints, pose: pose)
        if let issue {
            goodSince = nil
            if case .countdown = stage { countdownTask?.cancel() }
            stage = .positioning(issue)
            announce(issue)
            return
        }
        pendingIssue = nil
        guard case .positioning = stage else { return }
        let now = Date()
        if goodSince == nil { goodSince = now }
        if let since = goodSince, now.timeIntervalSince(since) >= holdDuration {
            startCountdown()
        } else {
            stage = .positioning(nil)
        }
    }

    private func announce(_ issue: PoseIssue) {
        let now = Date()
        if issue != pendingIssue {
            pendingIssue = issue
            pendingSince = now
            return
        }
        guard now.timeIntervalSince(pendingSince) >= 0.6 else { return }
        if issue == lastSpokenIssue, now.timeIntervalSince(lastSpokenAt) < 5 { return }
        guard !audio.isSpeaking else { return }
        lastSpokenIssue = issue
        lastSpokenAt = now
        audio.say(issue.instruction)
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            for n in stride(from: 3, through: 1, by: -1) {
                guard let self, !Task.isCancelled else { return }
                self.stage = .countdown(n)
                self.audio.play(.tick)
                self.audio.say("\(n)", priority: .high)
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled else { return }
            self.capture()
        }
    }

    private func capture() {
        guard let image = camera.captureStill() else {
            stage = .positioning(.noPerson)
            return
        }
        audio.play(.go)
        goodSince = nil
        turnNext = true
        camera.onFrame = nil
        stage = .turning(0)
        let front = Task.detached(priority: .userInitiated) { try FrontAnalysis(image) }
        self.front = front
        audio.say(String(localized: "Great. Now we'll measure you from eight sides. Hold your arms straight out to the sides at shoulder height, in one straight line, and keep them there. You'll always turn clockwise, to your right, and stop when I tell you."),
                  priority: .high)
        countdownTask = Task { [weak self] in
            do {
                let result = try await front.value
                // Let the sentence above finish before the first stop.
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.startStations(result)
            } catch {
                self?.fail(Self.message(for: error))
            }
        }
    }

    // MARK: Turn

    private func startStations(_ front: FrontAnalysis) {
        scan = StationScan()
        stillness.reset()
        turn = TurnState()
        turnStart = Date()
        stationStart = Date()
        spanReference = 1
        shoulderReference = nil

        let vision = vision
        let start = turnStart
        let heightCm = basics.heightCm
        let fractions = front.fractions.merging(defaultFractions) { measured, _ in measured }
        levelFractions = fractions
        capturing = false
        let analyzer = RotationScanAnalyzer()
        camera.frameRate = 8
        camera.onFrame = { [weak self] buffer in
            let time = Date().timeIntervalSince(start)
            let reading = vision.turnFrame(buffer, time: time)
                .flatMap { analyzer.reading($0, heightCm: heightCm, levelFractions: fractions) }
            Task { @MainActor in self?.handleStation(reading, time: time) }
        }
        stage = .turning(0)
        say(StationGuide.instruction(0))

        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, case .turning = self.stage else { return }
                self.coach()
            }
        }
    }

    private func handleStation(_ reading: FrameReading?, time: Double) {
        guard case .turning = stage, turn.station < StationScan.stationCount, !capturing else { return }
        turn.reading = reading
        guard let reading else {
            stillness.reset()
            turn.holding = false
            return
        }
        stillness.add(reading, time: time)
        // Time to hear the instruction and start moving.
        guard Date().timeIntervalSince(stationStart) > 1.5 else { return }
        guard let widths = stillness.stillWidths(at: time), let span = reading.armSpan else {
            turn.holding = false
            turn.fit = nil
            return
        }
        let station = turn.station
        let shoulders = Self.shoulderSeparation(reading)
        let fit: StopFit
        if !StopGuide.fullyVisible(reading) {
            fit = .stepBack
        } else if station == 0 {
            fit = span >= StopGuide.openArmSpan ? .ok : .openArms
        } else {
            fit = StopGuide.fit(station: station, spanRatio: span / spanReference,
                                shoulderRatio: shoulders.flatMap { s in shoulderReference.map { s / $0 } })
        }
        turn.fit = fit
        turn.holding = fit == .ok
        guard fit == .ok else { return nudge(fit) }
        if station == 0 {
            spanReference = span
            shoulderReference = shoulders
        }
        capturePrecise(fallback: widths)
    }

    /// Re-measures the stop on a still at the best segmentation quality; the live frames'
    /// faster masks have softer edges. Falls back to the live widths if that fails.
    private func capturePrecise(fallback: [BodyLevel: Double]) {
        guard !capturing else { return }
        capturing = true
        let station = turn.station
        let image = camera.captureStill()
        let heightCm = basics.heightCm
        let fractions = levelFractions
        Task {
            let precise = await Task.detached(priority: .userInitiated) { () -> [BodyLevel: Double]? in
                guard let image, let frame = VisionBodyAnalyzer().turnFrame(image, time: 0),
                      let reading = RotationScanAnalyzer().reading(frame, heightCm: heightCm, levelFractions: fractions),
                      StopGuide.fullyVisible(reading) else { return nil }
                let widths = reading.levels.mapValues(\.widthCm)
                return widths[.waist] != nil || widths[.hip] != nil ? widths : nil
            }.value
            capturing = false
            guard case .turning = stage, turn.station == station else { return }
            record(precise ?? fallback)
        }
    }

    /// Shoulder joints' separation over body height, in the same units both ways.
    private static func shoulderSeparation(_ reading: FrameReading) -> Double? {
        guard let l = reading.joints[.leftShoulder], let r = reading.joints[.rightShoulder],
              reading.floor > reading.top else { return nil }
        return abs(l.x - r.x) * 9 / 16 / (reading.floor - reading.top)
    }

    private func nudge(_ fit: StopFit) {
        guard Date().timeIntervalSince(lastHintAt) > 4, !audio.isSpeaking else { return }
        switch fit {
        case .ok: return
        case .turnFurther: say(String(localized: "Turn a little further clockwise."))
        case .turnBack: say(String(localized: "A little too far. Turn back slightly."))
        case .openArms: say(String(localized: "Open your arms fully, straight out at shoulder height."))
        case .stepBack: say(String(localized: "Step back until you're fully visible, head to feet."))
        }
    }

    private func record(_ widths: [BodyLevel: Double]) {
        let station = turn.station
        scan.record(widths, at: station)
        turn.captured.insert(station)
        let measured = Set(scan.levels.filter { scan.isMeasured($0) })
        if !measured.subtracting(turn.measured).isEmpty { audio.play(.region) }
        turn.measured = measured
        turn.holding = false
        audio.play(.sector(station))
        stillness.reset()
        turn.fit = nil

        let next = station + 1
        turn.station = next
        stage = .turning(Double(next) / Double(StationScan.stationCount))
        guard next < StationScan.stationCount else { return finishTurn() }
        stationStart = Date()
        say(String(localized: "Good.") + " " + StationGuide.instruction(next))
    }

    /// Runs twice a second: helps when a stop is taking long.
    private func coach() {
        if Date().timeIntervalSince(turnStart) > maxTurnDuration { return finishTurn() }
        guard Date().timeIntervalSince(lastHintAt) > 8, !audio.isSpeaking else { return }
        if turn.reading == nil {
            say(String(localized: "Step back into the frame."))
        } else if turn.fit == nil {
            say(String(localized: "Stop and hold still for a moment."))
        } else {
            say(StationGuide.instruction(turn.station))
        }
    }

    private func say(_ text: String) {
        lastHintAt = Date()
        audio.say(text, priority: .high)
    }

    private func finishTurn() {
        camera.onFrame = nil
        countdownTask?.cancel()
        audio.play(.success)
        audio.say(String(localized: "Done. You can turn back to the phone."), priority: .high)
        analyze()
    }

    private func analyze() {
        guard let front else { return retry() }
        let scan = scan
        let basics = basics
        stage = .analyzing
        camera.onFrame = nil

        Task {
            let outcome: Result<BodyProfile, Error>
            do {
                let frontResult = try await front.value
                outcome = await Task.detached(priority: .userInitiated) {
                    Result { try Self.measure(front: frontResult, scan: scan, basics: basics) }
                }.value
            } catch {
                outcome = .failure(error)
            }

            // Photos are no longer needed once measured.
            self.front = nil
            camera.stop()

            switch outcome {
            case let .success(profile):
                let missing = [BodyDimension.chest, .waist].filter { profile[$0] == nil }
                guard missing.isEmpty else {
                    partialResult = profile
                    let names = missing.map { $0 == .chest ? BodyLevel.chest.title : BodyLevel.waist.title }
                        .joined(separator: ", ")
                    let girths = scan.girths()
                    let calculated = [BodyLevel.chest, .waist, .hip].map { level in
                        "\(level.title) " + (girths[level].map { "\(Int($0.cm.rounded())) cm" } ?? "–")
                    }.joined(separator: ", ")
                    let detail = String(localized: "Positions measured: chest \(scan.count(.chest)) of 8, waist \(scan.count(.waist)) of 8, hips \(scan.count(.hip)) of 8.")
                        + "\n" + String(localized: "Calculated: \(calculated)")
                    fail(String(localized: "Couldn't measure: \(names). Keep your arms straight out and stop at each position, in a bright room.") + "\n\n" + detail,
                         spoken: String(localized: "Let's try the turn again."))
                    return
                }
                result = profile
                stage = .completed
                audio.say(String(localized: "Scan complete. Your measurements are ready."), priority: .high)
                try? await Task.sleep(for: .seconds(2.5))
                stage = .finished
            case let .failure(error):
                fail(Self.message(for: error))
            }
        }
    }

    private nonisolated static func measure(front: FrontAnalysis, scan: StationScan, basics: BodyBasics) throws -> BodyProfile {
        // Lengths and shoulder width from the front photo; its girths would rely on an
        // assumed body depth, so they are replaced by the turn's.
        var profile = try BodyMeasurementEngine().measure(heightCm: basics.heightCm, front: front.observation, side: nil)
        for d in [BodyDimension.chest, .waist, .hip] { profile[d] = nil }
        for (level, value) in scan.girths() {
            switch level {
            case .chest: profile[.chest] = value
            case .waist: profile[.waist] = value
            case .hip: profile[.hip] = value
            case .thigh: profile[.thigh] = value
            }
        }
        profile.weightKg = basics.weightKg
        profile.sex = basics.sex
        // Height/weight statistics only flag impossible readings; they never become values.
        let rejected = MeasurementFusion.fuse(scan: profile, prior: basics.prior()).rejected
        for d in rejected { profile[d] = nil }
        return profile
    }

    private func fail(_ message: String, spoken: String? = nil) {
        camera.onFrame = nil
        stage = .failed(message)
        audio.play(.problem)
        audio.say(spoken ?? message, priority: .high)
    }

    private static func message(for error: Error) -> String {
        switch error {
        case SilhouetteError.noPerson, VisionAnalysisError.noPersonFound:
            String(localized: "We couldn't find you in the photo. Make sure your whole body is visible and the room is well lit.")
        case SilhouetteError.missingJoints, BodyMeasurementError.personNotFullyVisible:
            String(localized: "Some body points weren't visible. Wear fitted clothes and keep your whole body in frame.")
        default:
            error.localizedDescription
        }
    }
}

/// The front photo's measurements and where each body level sits.
private struct FrontAnalysis: Sendable {
    let observation: ScanObservation
    /// Height of each level below the top of the head, as a fraction of body height.
    let fractions: [BodyLevel: Double]

    init(_ image: CGImage) throws {
        let f = try VisionBodyAnalyzer().analyze(image)
        let front = try SilhouetteAnalyzer().analyzeFront(mask: f.mask, joints: f.joints)
        let top = front.floorY - front.personHeightPx
        observation = front
        var fractions = front.levels.mapValues { ($0.y - top) / front.personHeightPx }
        // Arms against the chest make its front width unusable, and the level is dropped;
        // the turn still needs to know where the chest is.
        if fractions[.chest] == nil, let ls = front.joints[.leftShoulder], let rs = front.joints[.rightShoulder],
           let root = front.joints[.root] {
            let shoulderY = (ls.y + rs.y) / 2
            let chestY = shoulderY + SilhouetteAnalyzer.chestTorsoFraction * (root.y - shoulderY)
            fractions[.chest] = (chestY - top) / front.personHeightPx
        }
        self.fractions = fractions
    }
}

extension PoseIssue {
    var instruction: String {
        switch self {
        case .noPerson: String(localized: "Step into the frame.")
        case .headNotVisible: String(localized: "Your head is cut off. Step back or tilt the phone.")
        case .feetNotVisible: String(localized: "Your feet aren't visible. Step back.")
        case .tooClose: String(localized: "Step back a little.")
        case .tooFar: String(localized: "Come a little closer.")
        case .notCentered: String(localized: "Move to the centre of the frame.")
        case .notFacingCamera: String(localized: "Face the phone directly.")
        case .armsTooCloseToBody: String(localized: "Hold your arms slightly away from your body.")
        case .notSideways: String(localized: "Turn fully to your side.")
        }
    }
}

extension BodyLevel {
    var title: String {
        switch self {
        case .chest: String(localized: "Chest")
        case .waist: String(localized: "Waist")
        case .hip: String(localized: "Hips")
        case .thigh: String(localized: "Thigh")
        }
    }
}

/// The eight stops of the guided turn, 45° apart, always turning clockwise (to the
/// user's right) as seen from above. Turning right first brings the left side to the
/// phone, then the back, then the right side.
enum StationGuide {
    static func title(_ station: Int) -> String {
        switch station {
        case 0: String(localized: "Front")
        case 2: String(localized: "Left side")
        case 4: String(localized: "Back")
        case 6: String(localized: "Right side")
        case 3, 5: String(localized: "Back diagonal")
        default: String(localized: "Front diagonal")
        }
    }

    static func instruction(_ station: Int) -> String {
        switch station {
        case 0: String(localized: "Face the phone with your arms straight out, and hold still.")
        case 1: String(localized: "Turn a little clockwise, so you stand diagonally to the phone, and stop.")
        case 2: String(localized: "Keep turning clockwise until your left side faces the phone, and stop.")
        case 3: String(localized: "Keep turning clockwise until your back is diagonal to the phone, and stop.")
        case 4: String(localized: "Keep turning clockwise until your back faces the phone, and stop.")
        case 5: String(localized: "Keep turning clockwise a little more, back diagonal again, and stop.")
        case 6: String(localized: "Keep turning clockwise until your right side faces the phone, and stop.")
        default: String(localized: "Last one: turn clockwise a little more, front diagonal to the phone, and stop.")
        }
    }
}
