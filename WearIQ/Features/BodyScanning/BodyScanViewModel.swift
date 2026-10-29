import AVFoundation
import BodyMeasurementEngine
import BodyScanVision
import Observation
import WearIQCore

/// Front photo → guided 360° turn → on-device analysis.
///
/// The user props the phone up and steps back, so capture is hands-free: once the
/// pose has been good for a moment a countdown starts, and spoken cues tell the user
/// what to fix. The front photo gives lengths and shoulder width; the turn gives real
/// girths (see `RotationScanAnalyzer`). During the turn, Vision's 3D body pose tells how
/// far the user has turned: the floor ring fills sector by sector and each body region
/// turns green once it has been seen from every direction, so the turn ends when the
/// data is complete rather than after a fixed time. Height/weight statistics are only
/// used to catch failed detections, never as values. Images and masks live only in memory.
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
        var sectors = 0
        var measured: Set<BodyLevel> = []
        /// Latest outline of the person, normalised image coordinates.
        var reading: FrameReading?
        var hint: String?
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
    private var lastJoints: [BodyJoint: DetectedJoint] = [:]
    private let turnFrames = FrameStore()
    private var tracker = TurnTracker()
    private var turnStart = Date()
    /// Frames in which the body's angle could be read; without them the turn is timed.
    private var angledFrames = 0
    private var lastHintAt = Date.distantPast

    /// Pose problems are spoken once they have lasted this long, so flickering
    /// detections don't produce a stream of half-finished sentences.
    private var pendingIssue: PoseIssue?
    private var pendingSince = Date()
    private var lastSpokenIssue: PoseIssue?
    private var lastSpokenAt = Date.distantPast

    /// How long the pose must be held before the countdown starts.
    private let holdDuration: TimeInterval = 1.0
    /// A turn without angle readings (very old devices) is simply timed.
    private let timedTurnDuration: TimeInterval = 18
    private let maxTurnDuration: TimeInterval = 40
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
        turnFrames.reset()
        tracker = TurnTracker()
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
        lastJoints = joints
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
            if self.turnNext { await self.recordTurn() } else { self.capture() }
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
        stage = .positioning(nil)
        // Analysed while the user gets ready to turn; the turn's overlay needs its body levels.
        front = Task.detached(priority: .userInitiated) { try FrontAnalysis(image) }
        audio.say(String(localized: "Great. Keep your arms slightly away from your body. After the countdown, turn slowly all the way around."),
                  priority: .high)
    }

    // MARK: Turn

    /// Records the turn: every frame becomes a person mask plus the body's angle, which
    /// drive the live overlay; widths are averaged per angle afterwards.
    private func recordTurn() async {
        let frontResult: FrontAnalysis
        do {
            guard let front else { return retry() }
            frontResult = try await front.value
        } catch {
            fail(Self.message(for: error))
            return
        }
        turnFrames.reset()
        tracker = TurnTracker()
        turn = TurnState()
        angledFrames = 0
        turnStart = Date()
        lastHintAt = Date()

        let vision = vision
        let store = turnFrames
        let start = turnStart
        let heightCm = basics.heightCm
        let fractions = frontResult.fractions.isEmpty ? defaultFractions : frontResult.fractions
        let shoulderReference = VisionBodyAnalyzer.shoulderRatio(lastJoints)
        let analyzer = RotationScanAnalyzer()
        // 3D pose, segmentation and the overlay take most of a frame's time on older phones.
        camera.frameRate = 6
        camera.onFrame = { [weak self] buffer in
            let time = Date().timeIntervalSince(start)
            guard let frame = vision.turnFrame(buffer, time: time, shoulderReference: shoulderReference) else { return }
            store.append(frame)
            let reading = analyzer.reading(frame, heightCm: heightCm, levelFractions: fractions)
            Task { @MainActor in self?.handleTurn(axisAngle: frame.axisAngle, reading: reading, time: time) }
        }
        stage = .turning(0)
        audio.say(String(localized: "Now turn slowly all the way around."), priority: .high)

        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, case .turning = self.stage else { return }
                self.checkTurn()
            }
        }
    }

    private func handleTurn(axisAngle: Double?, reading: FrameReading?, time: Double) {
        guard case .turning = stage else { return }
        if axisAngle != nil { angledFrames += 1 }
        let sectorsBefore = tracker.completedSectors
        let measuredBefore = turn.measured
        tracker.add(axisAngle: axisAngle, measured: Set(reading.map { Array($0.levels.keys) } ?? []), time: time)

        var state = turn
        state.reading = reading
        state.sectors = isTimed ? timedSectors : tracker.completedSectors
        state.measured = isTimed ? [] : Set(tracker.levels.filter { tracker.coverage($0) >= 1 })
        if state.sectors > sectorsBefore, !isTimed {
            for n in sectorsBefore..<state.sectors { audio.play(.sector(n)) }
        }
        for level in tracker.levels where state.measured.contains(level) && !measuredBefore.contains(level) {
            audio.play(.region)
            audio.say(level.doneAnnouncement)
        }
        turn = state
        stage = .turning(Double(state.sectors) / Double(TurnTracker.sectorCount))
    }

    private var elapsed: TimeInterval { Date().timeIntervalSince(turnStart) }

    /// After a few seconds without a single angle reading, the turn is timed instead.
    private var isTimed: Bool { elapsed > 5 && angledFrames < 3 }

    private var timedSectors: Int {
        min(TurnTracker.sectorCount, Int(elapsed / timedTurnDuration * Double(TurnTracker.sectorCount)))
    }

    /// Runs a few times a second: ends the turn when complete, and coaches when it stalls.
    private func checkTurn() {
        let now = elapsed
        if isTimed {
            let sectors = timedSectors
            if sectors > turn.sectors {
                audio.play(.sector(sectors - 1))
                turn.sectors = sectors
                stage = .turning(Double(sectors) / Double(TurnTracker.sectorCount))
            }
            if now >= timedTurnDuration { finishTurn() }
            return
        }
        if tracker.isComplete || now >= maxTurnDuration {
            finishTurn()
            return
        }
        guard Date().timeIntervalSince(lastHintAt) > 4.5, !audio.isSpeaking else { return }
        var hint: String?
        if tracker.speed > 80 {
            hint = String(localized: "A little slower, please.")
        } else if tracker.idle(at: now) > 3 {
            hint = tracker.quarters >= 4
                ? String(localized: "Almost there. Turn once more, slowly.")
                : String(localized: "Keep turning slowly.")
        }
        turn.hint = hint
        if let hint {
            lastHintAt = Date()
            audio.say(hint)
        }
    }

    private func finishTurn() {
        camera.onFrame = nil
        countdownTask?.cancel()
        audio.play(.success)
        audio.say(String(localized: "You can stop now."), priority: .high)
        analyze()
    }

    private func analyze() {
        guard let front else { return retry() }
        let frames = turnFrames.drain()
        let basics = basics
        stage = .analyzing
        camera.onFrame = nil

        Task {
            let outcome: Result<BodyProfile, Error>
            do {
                let frontResult = try await front.value
                outcome = await Task.detached(priority: .userInitiated) {
                    Result { try Self.measure(front: frontResult, frames: frames, basics: basics) }
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
                    fail(String(localized: "Your chest and waist couldn't be measured from the turn. Turn a little slower with your arms away from your body, in a bright room."),
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

    private nonisolated static func measure(front: FrontAnalysis, frames: [RotationFrame], basics: BodyBasics) throws -> BodyProfile {
        // Lengths and shoulder width from the front photo; its girths would rely on an
        // assumed body depth, so they are replaced by the turn's.
        var profile = try BodyMeasurementEngine().measure(heightCm: basics.heightCm, front: front.observation, side: nil)
        for d in [BodyDimension.chest, .waist, .hip] { profile[d] = nil }
        let girths = (try? RotationScanAnalyzer().girths(frames: frames, heightCm: basics.heightCm,
                                                          levelFractions: front.fractions)) ?? [:]
        for (level, value) in girths {
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
        observation = try SilhouetteAnalyzer().analyzeFront(mask: f.mask, joints: f.joints)
        let top = observation.floorY - observation.personHeightPx
        fractions = observation.levels.mapValues { ($0.y - top) / observation.personHeightPx }
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

    var doneAnnouncement: String {
        switch self {
        case .chest: String(localized: "Chest done.")
        case .waist: String(localized: "Waist done.")
        case .hip: String(localized: "Hips done.")
        case .thigh: String(localized: "Thigh done.")
        }
    }
}

/// Turn frames arrive on the camera queue and are read on the main actor.
private final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [RotationFrame] = []

    func append(_ frame: RotationFrame) { lock.withLock { frames.append(frame) } }
    func reset() { lock.withLock { frames.removeAll() } }
    func drain() -> [RotationFrame] { lock.withLock { defer { frames.removeAll() }; return frames } }
}
