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
        /// Measured, but chest, waist and hips came out far above what height, weight and
        /// age allow: most likely clothes, not body. The user can rescan or keep them.
        case clothesSuspected
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
        /// Loose clothing seen at the front stop; the turn waits while this is non-empty.
        var clothing: [ClothingCheck.Finding] = []
        /// Going round again for stops that disagreed with the ones opposite them.
        var retaking = false
        /// The stop's stills are being measured.
        var capturing = false
        /// Edges of the picture the user runs off.
        var cutEdges: StopGuide.Edges = []
        /// Arm span ratio at the last stop taken or passed: the next one needs a real turn
        /// from there.
        var lastRatio: Double?
    }

    private(set) var pose: ScanPose = .front
    private(set) var stage: Stage = .positioning(.noPerson)
    private(set) var result: BodyProfile?
    /// Values measured before a failure, so the user can keep them and add the rest.
    private(set) var partialResult: BodyProfile?
    private(set) var turn = TurnState()
    /// The outline seen while positioning for the front photo, for the overlay.
    private(set) var liveReading: FrameReading?
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
    /// Nose to ankle is about 0.89 of the body's height, so 0.34–0.45 of the picture
    /// puts the body at 38–50% of it: far enough back for the outstretched arms of the
    /// turn to fit across the portrait picture (see `StopGuide.minimumBodySpan`).
    private let guidance: PoseGuidance = {
        var guidance = PoseGuidance()
        guidance.minBodySpan = 0.34
        guidance.maxBodySpan = 0.45
        return guidance
    }()
    private let audio = ScanAudio()

    private var goodSince: Date?
    private var countdownTask: Task<Void, Never>?
    private var front: Task<FrontAnalysis, Error>?
    private var scan = StationScan()
    private var stillness: StillnessDetector = {
        var detector = StillnessDetector()
        // Standing still with the arms out, people sway a little; a stop shouldn't keep
        // them waiting for perfect stillness.
        detector.window = 0.8
        detector.tolerance = 0.045
        return detector
    }()
    /// What the screen shows: changes only once a new verdict has held for a moment, so
    /// a detection flickering between frames doesn't make the screen flicker with it.
    private var shownIssue = Steady<PoseIssue?>(.noPerson)
    private var shownFit = Steady<StopFit?>(nil)
    /// When the outline was last seen; a frame or two without it keeps the last one.
    private var lastReadingAt = Date.distantPast
    private var turnStart = Date()
    /// When the first stop of the turn was asked for (retakes don't restart it).
    private var scanBegan = Date()
    private var stationStart = Date()
    /// Arm span and shoulder separation at the front stop; later stops are judged against them.
    private var spanReference = 1.0
    private var shoulderReference: Double?
    private var levelFractions: [BodyLevel: Double] = [:]
    /// The user chose to scan in their clothes after the loose-clothing warning.
    private var clothingWarningDismissed = false
    /// What the loose-clothing check saw at the front stop; the measurement uses it.
    private var clothingFindings: [ClothingCheck.Finding] = []
    /// Stops still to take again after the turn, and whether that was offered already.
    private var retakeQueue: [Int] = []
    private var retakesOffered = false
    /// A stop's still is being measured.
    private var capturing = false
    private var lastHintAt = Date.distantPast
    /// Stopped while the app is in the background.
    private var suspended = false
    /// Since when the arms have looked lowered.
    private var armsDownSince: Date?
    /// The filmed turn, and when filming began (nil during the countdown).
    private var recording = TurnRecording()
    private var recordingStarted: Date?
    /// Arm spans seen during the countdown, for the front view's.
    private var spans: [Double] = []
    private var clothingChecked = false
    private var turnProgress = 0.0
    private var lastProgressAt = Date()
    private var frontResult: FrontAnalysis?

    /// Pose problems are spoken once they have lasted this long, so flickering
    /// detections don't produce a stream of half-finished sentences.
    private var pendingIssue: PoseIssue?
    private var pendingSince = Date()
    private var lastSpokenIssue: PoseIssue?
    private var lastSpokenAt = Date.distantPast

    /// How long the pose must be held before the countdown starts.
    private let holdDuration: TimeInterval = 1.0
    private let maxTurnDuration: TimeInterval = 45
    private let defaultFractions: [BodyLevel: Double] = [.chest: 0.27, .waist: 0.39, .hip: 0.5]

    init(basics: BodyBasics) {
        self.basics = basics
    }

    func start() async {
        audio.start()
        watchPose()
        do {
            try await camera.start(position: .front)
            audio.say(String(localized: "Photos are processed on this phone and deleted right away. Nothing is sent anywhere.") + " "
                      + String(localized: "Stand about three steps back from the phone, facing it, arms slightly away from your body."), priority: .high)
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    /// Keeps measurements that look inflated by clothes.
    func keepDespiteClothes() {
        stage = .finished
    }

    func stop() {
        countdownTask?.cancel()
        camera.onFrame = nil
        camera.stop()
        audio.stop()
    }

    /// The app went to the background: the camera and the voice can't run there (a sound
    /// started then ended the app), so the scan stops where it is.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        countdownTask?.cancel()
        camera.onFrame = nil
        camera.stop()
        audio.stop()
    }

    /// Back in the foreground: a scan that was under way starts again from the front
    /// photo, since the user has moved since; a finished or analysing one is left be.
    func resume() async {
        guard suspended else { return }
        suspended = false
        switch stage {
        case .analyzing, .completed, .clothesSuspected, .finished, .failed:
            return
        default:
            break
        }
        retry()
        await start()
    }

    func retry() {
        countdownTask?.cancel()
        front?.cancel()
        front = nil
        scan = StationScan()
        stillness.reset()
        turn = TurnState()
        retakeQueue = []
        retakesOffered = false
        frontResult = nil
        recordingStarted = nil
        clothingFindings = []
        result = nil
        partialResult = nil
        turnNext = false
        pose = .front
        goodSince = nil
        stage = .positioning(.noPerson)
        watchPose()
    }

    /// Positioning for the front photo: joints for the pose checks and the outline for
    /// the live overlay, from the same frame.
    private func watchPose() {
        let vision = vision
        let analyzer = RotationScanAnalyzer()
        let heightCm = basics.heightCm
        let fractions = defaultFractions
        camera.frameRate = 5
        camera.onFrame = { [weak self] buffer in
            let frame = vision.turnFrame(buffer, time: 0)
            let joints = frame?.joints.mapValues { DetectedJoint($0, confidence: 1) } ?? [:]
            let reading = frame.flatMap { analyzer.reading($0, heightCm: heightCm, levelFractions: fractions) }
            Task { @MainActor in
                self?.showLive(reading)
                self?.handle(joints)
            }
        }
    }

    private func showLive(_ reading: FrameReading?) {
        let now = Date()
        if let reading {
            liveReading = reading
            lastReadingAt = now
        } else if now.timeIntervalSince(lastReadingAt) > 0.6 {
            liveReading = nil
        }
    }

    func dismissClothingWarning() {
        clothingWarningDismissed = true
        turn.clothing = []
        if let front = frontResult { startStations(front) }
    }

    func retryAfterChangingClothes() {
        turn.clothing = []
        clothingChecked = false
        if let front = frontResult { startStations(front) }
    }

    private func handle(_ joints: [BodyJoint: DetectedJoint]) {
        switch stage {
        case .positioning, .countdown: break
        default: return
        }
        let issue = guidance.issue(for: joints, pose: pose)
        let shown = shownIssue.update(issue)
        if let issue {
            goodSince = nil
            if case .countdown = stage {
                countdownTask?.cancel()
                stage = .positioning(issue)
            } else {
                stage = .positioning(shown)
            }
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
            stage = .positioning(shown)
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
        audio.say(String(localized: "Great. Now raise your arms to shoulder height and turn slowly in place to your right, once all the way round. It takes about fifteen seconds."),
                  priority: .high)
        countdownTask = Task { [weak self] in
            do {
                let result = try await front.value
                self?.frontResult = result
                // The sentence above has to end before the countdown.
                try? await Task.sleep(for: .seconds(1))
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
        recording = TurnRecording()
        recordingStarted = nil
        spans = []
        clothingChecked = basics.attire == .everyday || clothingWarningDismissed
        armsDownSince = nil
        turn = TurnState()
        turnStart = Date()
        scanBegan = Date()
        spanReference = 1

        let vision = vision
        let start = turnStart
        let heightCm = basics.heightCm
        let fractions = front.fractions.merging(defaultFractions) { measured, _ in measured }
        levelFractions = fractions
        let analyzer = RotationScanAnalyzer()
        // Ten frames a second: a quarter of a slow turn is about 35 frames.
        camera.frameRate = 10
        camera.onFrame = { [weak self] buffer in
            let time = Date().timeIntervalSince(start)
            let reading = vision.turnFrame(buffer, time: time)
                .flatMap { analyzer.reading($0, heightCm: heightCm, levelFractions: fractions) }
            Task { @MainActor in self?.handleTurn(reading, time: time) }
        }
        stage = .turning(0)
        shownFit.reset(nil)
        countdownTask = Task { [weak self] in
            // Once the intro has been said: 3, 2, 1, and the turn is filmed.
            while let self, self.audio.isSpeaking, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            for n in stride(from: 3, through: 1, by: -1) {
                guard let self, !Task.isCancelled else { return }
                self.audio.play(.tick)
                self.audio.say("\(n)", priority: .high)
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled, case .turning = self.stage else { return }
            self.beginRecording()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard case .turning = self.stage else { return }
                self.coach()
            }
        }
    }

    /// The front view's arm span, from the frames seen during the countdown (arms up,
    /// facing the phone), is what the turn is measured against.
    private func beginRecording() {
        let sorted = spans.sorted()
        if !sorted.isEmpty { spanReference = sorted[sorted.count * 3 / 4] }
        recording = TurnRecording()
        recordingStarted = Date()
        lastProgressAt = Date()
        audio.play(.go)
    }

    /// Every frame of the turn: kept while the user is whole in the picture with the
    /// arms out; the voice speaks up only when something is wrong.
    private func handleTurn(_ reading: FrameReading?, time: Double) {
        guard case .turning = stage else { return }
        let now = Date()
        if let reading {
            turn.reading = reading
            turn.cutEdges = StopGuide.cutEdges(reading)
            lastReadingAt = now
        } else if now.timeIntervalSince(lastReadingAt) > 0.6 {
            turn.reading = nil
            turn.cutEdges = []
        }
        guard turn.clothing.isEmpty, let reading, let span = reading.armSpan else { return }
        // Arms lowered for most of a second (a missed wrist for a frame doesn't count).
        // Side-on the joints of the arms can't be read, so only the wider views judge it.
        let wideView = recordingStarted == nil || span / spanReference > 0.6
        if wideView, StopGuide.armsDown(reading) { armsDownSince = armsDownSince ?? now } else { armsDownSince = nil }
        let armsDown = armsDownSince.map { now.timeIntervalSince($0) > 0.8 } ?? false
        let fit: StopFit
        if !StopGuide.fullyVisible(reading) {
            fit = .stepBack
        } else if !turn.cutEdges.isDisjoint(with: [.left, .right]) {
            fit = .handsOutOfFrame
        } else if armsDown {
            fit = .openArms
        } else {
            fit = .ok
        }
        turn.fit = shownFit.update(fit)
        guard let started = recordingStarted else {
            // The countdown, facing the phone: the front span, and loose clothing.
            guard fit == .ok else { return nudge(fit) }
            spans.append(span)
            if !clothingChecked, span >= StopGuide.openArmSpan {
                clothingChecked = true
                let bmi = basics.weightKg / ((basics.heightCm / 100) * (basics.heightCm / 100))
                let findings = ClothingCheck.findings(armThickness: reading.armThickness,
                                                      waistWidthCm: reading.levels[.waist]?.widthCm,
                                                      hipWidthCm: reading.levels[.hip]?.widthCm,
                                                      bmi: bmi, sex: basics.sex)
                clothingFindings = findings
                if !findings.isEmpty {
                    countdownTask?.cancel()
                    turn.clothing = findings
                    audio.play(.problem)
                    say(String(localized: "Your clothes look loose, which makes the measurements too large. Take them off or put on something fitted."), priority: .high)
                }
            }
            return
        }
        guard fit == .ok else { return nudge(fit) }
        recording.add(.init(time: now.timeIntervalSince(started), spanRatio: span / spanReference,
                            widths: reading.levels.mapValues(\.widthCm)))
        // The ring fills as the user goes round.
        let progress = recording.progress
        if progress > turnProgress + 0.01 { lastProgressAt = now }
        turnProgress = progress
        let passed = Int((progress * Double(StationScan.stationCount)).rounded(.down))
        turn.station = min(StationScan.stationCount - 1, passed)
        turn.captured = Set(0..<min(StationScan.stationCount, passed + 1))
        stage = .turning(progress)
        if recording.isComplete || recording.tooFast { finishTurn() }
    }

    /// Shoulder joints' separation over body height, in the same units both ways.
    private static func shoulderSeparation(_ reading: FrameReading) -> Double? {
        guard let l = reading.joints[.leftShoulder], let r = reading.joints[.rightShoulder],
              reading.floor > reading.top else { return nil }
        return abs(l.x - r.x) * 9 / 16 / (reading.floor - reading.top)
    }

    private func nudge(_ fit: StopFit) {
        // Fitting in the picture and dropped arms are said straight away; turning waits a
        // little longer, since the user is usually still on the way.
        let urgent = fit == .openArms || fit == .stepBack || fit == .handsOutOfFrame
        guard Date().timeIntervalSince(lastHintAt) > (urgent ? 1.5 : 3), !audio.isSpeaking else { return }
        switch fit {
        case .ok: return
        case .handsOutOfFrame: hint(String(localized: "Step back until your hands fit in the picture too."))
        case .turnFurther: hint(String(localized: "Keep turning slowly to your right."))
        case .turnBack: hint(String(localized: "A little too far. Turn back slightly, counter-clockwise."))
        case .comeCloser: hint(String(localized: "Come a little closer to the phone."))
        case .moveToCentre: hint(String(localized: "Move to the middle of the picture."))
        case .openArms: hint(String(localized: "Keep your arms out at shoulder height."))
        case .stepBack: hint(String(localized: "Step back until you're fully visible, head to feet."))
        }
    }

    /// Runs twice a second during the turn: a turn that has stopped moving is nudged on,
    /// one that takes far too long is started again.
    private func coach() {
        guard let started = recordingStarted else { return }
        if Date().timeIntervalSince(started) > maxTurnDuration { return restartTurn() }
        guard Date().timeIntervalSince(lastHintAt) > 5, !audio.isSpeaking else { return }
        if turn.reading == nil {
            hint(String(localized: "Step back into the frame."))
        } else if Date().timeIntervalSince(lastProgressAt) > 5 {
            hint(String(localized: "Keep turning slowly to your right."))
        }
    }

    /// The turn again from the front: it went too fast, or didn't come round.
    private func restartTurn(tooFast: Bool = false) {
        guard let front = frontResult else { return retry() }
        countdownTask?.cancel()
        audio.play(.problem)
        say(tooFast ? String(localized: "That was a little fast. Once more, more slowly.")
                    : String(localized: "Let's try the turn again."), priority: .high)
        startStations(front)
    }

    /// An instruction: waits for whatever is being said to finish, unless told to cut in.
    private func say(_ text: String, priority: ScanAudio.Priority = .queued) {
        lastHintAt = Date()
        audio.say(text, priority: priority)
    }

    /// A correction while the user moves: dropped if something is being said.
    private func hint(_ text: String) {
        lastHintAt = Date()
        audio.say(text, priority: .normal)
    }

    private func finishTurn() {
        if recording.tooFast { return restartTurn(tooFast: true) }
        // The eight directions found in the turn, as the stops the measurement uses.
        scan = StationScan()
        for (k, widths) in recording.stations().enumerated() {
            if let widths { scan.record(widths, at: k) }
        }
        guard scan.captured.count >= scan.minimumStations else { return restartTurn() }
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

        let scanSeconds = Date().timeIntervalSince(scanBegan)
        Task {
            let outcome: Result<BodyProfile, Error>
            var milliseconds = 0.0
            do {
                let frontResult = try await front.value
                let findings = clothingFindings
                let clock = ContinuousClock()
                let started = clock.now
                outcome = await Task.detached(priority: .userInitiated) {
                    Result { try Self.measure(front: frontResult, scan: scan, basics: basics, findings: findings) }
                }.value
                let elapsed = clock.now - started
                milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            } catch {
                outcome = .failure(error)
            }
            if ValidationStore.isEnabled {
                // Validation mode: the same turn measured by the experimental engine too,
                // kept for comparing with a tape. What the app saves doesn't change.
                let engineA = ValidationRun.EngineA(profile: try? outcome.get(), milliseconds: milliseconds,
                                                    memoryMB: DeviceInfo.memoryFootprintMB)
                let profiles = Array(scan.profiles.values)
                let store = ValidationStore.shared
                let participant = store.nextParticipant, device = DeviceInfo.model, lidar = DeviceInfo.hasLiDAR
                // In the background: the result screen doesn't wait for it.
                Task {
                    let record = await Task.detached(priority: .utility) {
                        ValidationRun.record(participant: participant, device: device, hasLiDAR: lidar, basics: basics,
                                             engineA: engineA, profiles: profiles, scanSeconds: scanSeconds)
                    }.value
                    store.upsert(record)
                }
            }

            // Photos are no longer needed once measured.
            self.front = nil
            camera.stop()

            switch outcome {
            case var .success(profile):
                TapeCalibration.apply(to: &profile)
                let girths = scan.girths()
                let missing = [BodyLevel.chest, .waist].filter { girths[$0] == nil }
                guard missing.isEmpty else {
                    partialResult = profile
                    let names = missing.map(\.title).joined(separator: ", ")
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
                // Two or more girths over two standard deviations above the statistics for
                // this height, weight and age is what a sweater or loose shirt does (a device
                // scan in clothes: +13, +15 and +7 cm; the same person in underwear: none).
                let prior = basics.prior()
                let inflated = [(BodyLevel.chest, BodyDimension.chest), (.waist, .waist), (.hip, .hip)].filter { level, dim in
                    guard let measured = girths[level]?.cm, let expected = prior[dim] else { return false }
                    return measured - expected.cm > 2 * expected.uncertaintyCm
                }
                // In everyday clothes that's expected and already accounted for.
                if inflated.count >= 2, basics.attire != .everyday {
                    stage = .clothesSuspected
                    audio.play(.problem)
                    audio.say(String(localized: "These measurements look larger than your body, probably because of your clothes. For the right sizes, scan again in fitted clothes or underwear."),
                              priority: .high)
                    return
                }
                stage = .completed
                audio.say(String(localized: "Scan complete. Your measurements are ready."), priority: .high)
                try? await Task.sleep(for: .seconds(2.5))
                stage = .finished
            case let .failure(error):
                fail(Self.message(for: error))
            }
        }
    }

    private nonisolated static func measure(front: FrontAnalysis, scan: StationScan, basics: BodyBasics,
                                            findings: [ClothingCheck.Finding]) throws -> BodyProfile {
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
        // A reading far from anything this height and weight allows is a failed detection:
        // the height/weight estimate takes its place, and the reading is kept for the review.
        // Lengths and the shoulder width combine both (inverse-variance weighting): the
        // statistics predict them to ±2 cm, as good as a photo can measure them. Girths go
        // through the clothing-aware step. Values the photos couldn't show are estimated.
        let prior = basics.prior()
        let fusion = MeasurementFusion.fuse(scan: profile, prior: prior)
        var rejectedScans: [BodyDimension: Double] = [:]
        // A girth far above the statistics may be clothes rather than a failed detection;
        // the clothing-aware step below weighs that. Far below them is a failed detection.
        let girths: Set<BodyDimension> = [.chest, .waist, .hip, .thigh]
        for d in fusion.rejected {
            if girths.contains(d), let measured = profile[d]?.cm, let expected = prior[d]?.cm, measured > expected { continue }
            rejectedScans[d] = profile[d]?.cm
            profile[d] = prior[d]
        }
        for d in [BodyDimension.shoulderWidth, .armLength, .torsoLength, .inseam, .outseam]
        where !fusion.rejected.contains(d) && profile[d] != nil {
            profile[d] = fusion.profile[d]
        }
        // The outline girths are the body plus whatever the clothes add there: separate
        // the two, with a range for each value.
        profile = ClothingAwareReconstruction().apply(to: profile, attire: basics.attire, findings: findings,
                                                      expected: prior, previous: basics.previous,
                                                      heightCm: basics.heightCm)
        profile.skeletonToMaskRatio = BodyMeasurementEngine.skeletonToMaskRatio(front.observation)
        for (d, estimate) in prior where profile[d] == nil {
            profile[d] = estimate
            profile.assessments?[d] = MeasurementAssessment(estimate)
        }
        profile.rejectedScans = rejectedScans.isEmpty ? nil : rejectedScans
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
    var fractions: [BodyLevel: Double] = [:]

    init(_ image: CGImage) throws {
        let f = try VisionBodyAnalyzer().analyze(image)
        let front = try SilhouetteAnalyzer().analyzeFront(mask: f.mask, joints: f.joints)
        let top = front.floorY - front.personHeightPx
        observation = front
        let hips = [front.joints[.leftHip], front.joints[.rightHip], front.joints[.root]].compactMap { $0?.y }
        let shoulders = [front.joints[.leftShoulder], front.joints[.rightShoulder]].compactMap { $0?.y }
        if let skeleton = JointHeights.fit(front.joints), !hips.isEmpty, !shoulders.isEmpty {
            let hip = hips.reduce(0, +) / Double(hips.count)
            let shoulder = shoulders.reduce(0, +) / Double(shoulders.count)
            // Levels from the skeleton: ANSUR's population heights, stretched between this
            // person's own hip and shoulder joints. Loose clothes and the mask's reach
            // can't move them.
            let hipRatio = skeleton.ratio(ofRow: hip), shoulderRatio = skeleton.ratio(ofRow: shoulder)
            fractions = JointHeights.levelRatios.mapValues { level in
                1 - (hipRatio + (level - 0.52) / (0.80 - 0.52) * (shoulderRatio - hipRatio))
            }
            return
        }
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

/// A value shown on screen that changes only once a new one has held for `delay`.
struct Steady<Value: Equatable> {
    private(set) var value: Value
    private var candidate: Value
    private var since = Date()
    var delay: TimeInterval = 0.35

    init(_ value: Value) {
        self.value = value
        candidate = value
    }

    mutating func update(_ new: Value, now: Date = Date()) -> Value {
        if new == value {
            candidate = new
        } else if new != candidate {
            candidate = new
            since = now
        } else if now.timeIntervalSince(since) >= delay {
            value = new
        }
        return value
    }

    mutating func reset(_ new: Value) {
        value = new
        candidate = new
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

    /// Each stop is 45° clockwise from the one before; at the sides and the back the
    /// instruction also says what faces the phone.
    static func instruction(_ station: Int) -> String {
        switch station {
        case 0: String(localized: "Face the phone, arms straight out to the sides, and hold still.")
        case 1: String(localized: "Turn 45 degrees to your right and stop.")
        case 2: String(localized: "Another 45 degrees to your right. Your left side faces the phone.")
        case 4: String(localized: "Another 45 degrees to your right. Your back faces the phone.")
        case 6: String(localized: "Another 45 degrees to your right. Your right side faces the phone.")
        case 7: String(localized: "Last photo: another 45 degrees to your right, and stop.")
        default: String(localized: "Another 45 degrees to your right, and stop.")
        }
    }
}
