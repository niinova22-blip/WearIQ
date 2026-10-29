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
/// turn in eight stops 45° apart (see `StationScan`): each stop has one plain spoken
/// instruction, and as soon as the user holds still there its sector of the floor ring
/// turns green and the next instruction follows. Nothing depends on estimating the
/// body's angle, which proved unreliable with the front camera. Height/weight statistics
/// are only used to catch failed detections, never as values. Images and masks live
/// only in memory.
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
    }

    private(set) var pose: ScanPose = .front
    private(set) var stage: Stage = .positioning(.noPerson)
    private(set) var result: BodyProfile?
    /// Values measured before a failure, so the user can keep them and add the rest.
    private(set) var partialResult: BodyProfile?
    private(set) var turn = TurnState()
    var voiceGuidance = true {
        didSet { audio.isEnabled = voiceGuidance }
    }
    /// After the front photo the next capture is the turn.
    private(set) var turnNext = false

    let camera = CameraController()
    let basics: BodyBasics
    private let vision = VisionBodyAnalyzer()
    private let guidance = PoseGuidance()
    private let audio = ScanAudio()

    private var goodSince: Date?
    private var countdownTask: Task<Void, Never>?
    private var front: Task<FrontAnalysis, Error>?
    private var scan = StationScan()
    private var stillness = StillnessDetector()
    private var turnStart = Date()
    private var stationStart = Date()
    /// The user moved since the last stop was captured.
    private var movedSinceCapture = false
    /// The user is standing still, but in the same place as the last stop.
    private var stillButUnchanged = false
    private var lastHintAt = Date.distantPast

    /// Pose problems are spoken once they have lasted this long, so flickering
    /// detections don't produce a stream of half-finished sentences.
    private var pendingIssue: PoseIssue?
    private var pendingSince = Date()
    private var lastSpokenIssue: PoseIssue?
    private var lastSpokenAt = Date.distantPast

    /// How long the pose must be held before the countdown starts.
    private let holdDuration: TimeInterval = 1.0
    /// A still pose that looks like the last stop is accepted after this long, for
    /// bodies whose width barely changes between neighbouring stops.
    private let stationTimeout: TimeInterval = 9
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
        audio.say(String(localized: "Great. Now we'll measure you from eight sides. Keep your arms slightly away from your body."),
                  priority: .high)
        countdownTask = Task { [weak self] in
            do {
                let result = try await front.value
                // Let the sentence above finish before the first stop.
                try? await Task.sleep(for: .seconds(2.5))
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
        movedSinceCapture = true

        let vision = vision
        let start = turnStart
        let heightCm = basics.heightCm
        let fractions = front.fractions.isEmpty ? defaultFractions : front.fractions
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
        guard case .turning = stage, turn.station < StationScan.stationCount else { return }
        turn.reading = reading
        guard let reading else {
            stillness.reset()
            turn.holding = false
            return
        }
        stillness.add(reading, time: time)
        // Time to hear the instruction and start moving.
        guard Date().timeIntervalSince(stationStart) > 1.2 else { return }
        guard let widths = stillness.stillWidths(at: time) else {
            movedSinceCapture = true
            stillButUnchanged = false
            turn.holding = false
            return
        }
        let station = turn.station
        let changed = station == 0 || scan.differs(widths, from: station - 1)
        let waitedLongEnough = movedSinceCapture && Date().timeIntervalSince(stationStart) > stationTimeout
        stillButUnchanged = !changed
        turn.holding = changed
        if changed || waitedLongEnough { record(widths) }
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
        movedSinceCapture = false
        stillButUnchanged = false

        let next = station + 1
        turn.station = next
        stage = .turning(Double(next) / Double(StationScan.stationCount))
        guard next < StationScan.stationCount else { return finishTurn() }
        stationStart = Date()
        say(String(localized: "Good.") + " " + StationGuide.instruction(next))
    }

    /// Runs twice a second: nudges the user when a stop is taking long.
    private func coach() {
        if Date().timeIntervalSince(turnStart) > maxTurnDuration { return finishTurn() }
        guard Date().timeIntervalSince(lastHintAt) > 6, !audio.isSpeaking else { return }
        if turn.reading == nil {
            say(String(localized: "Step back into the frame."))
        } else if stillButUnchanged {
            say(String(localized: "Turn a little more.") + " " + StationGuide.instruction(turn.station))
        } else {
            say(String(localized: "Stop and hold still for a moment."))
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
                    let detail = String(localized: "Positions measured: chest \(scan.count(.chest)) of 8, waist \(scan.count(.waist)) of 8, hips \(scan.count(.hip)) of 8.")
                    fail(String(localized: "Your chest and waist couldn't be measured. Hold still at each position with your arms slightly away from your body, in a bright room.") + "\n\n" + detail,
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
        fractions = front.levels.mapValues { ($0.y - top) / front.personHeightPx }
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

/// The eight stops of the guided turn, 45° apart, turning to the user's right.
enum StationGuide {
    static func title(_ station: Int) -> String {
        switch station {
        case 0: String(localized: "Front")
        case 2: String(localized: "Right side")
        case 4: String(localized: "Back")
        case 6: String(localized: "Left side")
        default: String(localized: "Halfway")
        }
    }

    static func instruction(_ station: Int) -> String {
        switch station {
        case 0: String(localized: "Face the phone and hold still.")
        case 1: String(localized: "Turn a little to your right, halfway to your side, and hold still.")
        case 2: String(localized: "Keep turning until your right side faces the phone, and hold still.")
        case 3: String(localized: "Turn a little more, halfway to your back, and hold still.")
        case 4: String(localized: "Keep turning until your back faces the phone, and hold still.")
        case 5: String(localized: "Turn a little more, halfway to your other side, and hold still.")
        case 6: String(localized: "Keep turning until your left side faces the phone, and hold still.")
        default: String(localized: "Last one: turn a little more, halfway to the front, and hold still.")
        }
    }
}
