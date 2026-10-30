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
        detector.window = 0.5
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
            audio.say(String(localized: "Stand about three steps back from the phone, facing it, arms slightly away from your body."), priority: .high)
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

    func retry() {
        countdownTask?.cancel()
        front?.cancel()
        front = nil
        scan = StationScan()
        stillness.reset()
        turn = TurnState()
        retakeQueue = []
        retakesOffered = false
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
        stillness.reset()
        stationStart = Date()
    }

    func retryAfterChangingClothes() {
        turn.clothing = []
        stillness.reset()
        stationStart = Date()
        say(StationGuide.instruction(turn.station))
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
        audio.say(String(localized: "Great. Now I'll measure you from eight sides. Hold your arms straight out at shoulder height and keep them there. Each time, turn 45 degrees clockwise, to your right, and wait for the tone."),
                  priority: .high)
        countdownTask = Task { [weak self] in
            do {
                let result = try await front.value
                // A moment to lift the arms; the first instruction waits for the sentence above.
                try? await Task.sleep(for: .seconds(3))
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
        shownFit.reset(nil)
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
        let now = Date()
        if let reading {
            turn.reading = reading
            turn.cutEdges = StopGuide.cutEdges(reading)
            lastReadingAt = now
        } else if now.timeIntervalSince(lastReadingAt) > 0.6 {
            turn.reading = nil
            turn.cutEdges = []
        }
        guard turn.clothing.isEmpty else { return }
        guard let reading else {
            stillness.reset()
            turn.holding = false
            return
        }
        stillness.add(reading, time: time)
        // A moment to hear the instruction and start moving.
        guard Date().timeIntervalSince(stationStart) > 1.0, let span = reading.armSpan else { return }
        let station = turn.station
        let shoulders = Self.shoulderSeparation(reading)
        // Judged on every frame, so the voice guides while the user moves ("come closer",
        // "turn further") instead of waiting for them to stand still first. Fitting in the
        // picture comes first: with a hand cut off, the arm span says nothing about the turn.
        let fit: StopFit
        if !StopGuide.fullyVisible(reading) {
            fit = .stepBack
        } else if !turn.cutEdges.isDisjoint(with: [.left, .right]) {
            fit = .handsOutOfFrame
        } else if reading.floor - reading.top < StopGuide.minimumBodySpan {
            fit = .comeCloser
        } else if abs(reading.centerX - 0.5) > 0.18 {
            fit = .moveToCentre
        } else if StopGuide.armsDown(reading) {
            // Checked at every stop before the turn: dropped arms also shrink the span,
            // which would otherwise read as "turn further".
            fit = .openArms
        } else if station == 0 {
            fit = span >= StopGuide.openArmSpan ? .ok : .openArms
        } else {
            fit = StopGuide.fit(station: station, spanRatio: span / spanReference,
                                shoulderRatio: shoulders.flatMap { s in shoulderReference.map { s / $0 } })
        }
        // Right place: hold still for the capture.
        let shown = shownFit.update(fit)
        guard let widths = stillness.stillWidths(at: time) else {
            turn.fit = shown
            turn.holding = false
            if fit == .ok { holdStillHint() } else { nudge(fit) }
            return
        }
        turn.fit = fit == .ok ? .ok : shown
        turn.holding = fit == .ok
        guard fit == .ok else { return nudge(fit) }
        // Going round again: stops that measured well are passed by.
        if turn.retaking, !retakeQueue.contains(station) {
            audio.play(.tick)
            return advance()
        }
        if station == 0, !turn.retaking {
            // Facing the phone with the arms out is where loose clothing shows.
            let bmi = basics.weightKg / ((basics.heightCm / 100) * (basics.heightCm / 100))
            let findings = ClothingCheck.findings(armThickness: reading.armThickness,
                                                  waistWidthCm: reading.levels[.waist]?.widthCm,
                                                  hipWidthCm: reading.levels[.hip]?.widthCm,
                                                  bmi: bmi, sex: basics.sex)
            clothingFindings = findings
            // In everyday clothes that's expected: the measurement accounts for it.
            if !findings.isEmpty, !clothingWarningDismissed, basics.attire != .everyday {
                turn.clothing = findings
                turn.holding = false
                audio.play(.problem)
                say(String(localized: "Your clothes look loose, which makes the measurements too large. Take them off or put on something fitted."), priority: .high)
                return
            }
            spanReference = span
            shoulderReference = shoulders
        }
        capturePrecise(fallback: widths)
    }

    /// Re-measures the stop on stills at the best segmentation quality; the live frames'
    /// faster masks have softer edges. Three stills 150 ms apart (different camera
    /// frames) are measured and the median width per level kept, so one frame's
    /// segmentation slip doesn't decide the stop. Falls back to the live widths if
    /// none can be measured.
    private func capturePrecise(fallback: [BodyLevel: Double]) {
        guard !capturing else { return }
        capturing = true
        turn.capturing = true
        audio.play(.tick)
        let station = turn.station
        let heightCm = basics.heightCm
        let fractions = levelFractions
        Task {
            var images: [CGImage] = []
            for k in 0..<3 {
                if k > 0 { try? await Task.sleep(for: .milliseconds(150)) }
                if let image = camera.captureStill() { images.append(image) }
            }
            let stills = images
            let precise = await Task.detached(priority: .userInitiated) { () -> [BodyLevel: Double]? in
                let readings: [[BodyLevel: Double]] = stills.compactMap { image in
                    guard let frame = VisionBodyAnalyzer().turnFrame(image, time: 0),
                          let reading = RotationScanAnalyzer().reading(frame, heightCm: heightCm, levelFractions: fractions),
                          StopGuide.fullyVisible(reading) else { return nil }
                    return reading.levels.mapValues(\.widthCm)
                }
                var widths: [BodyLevel: Double] = [:]
                for level in BodyLevel.allCases {
                    let values = readings.compactMap { $0[level] }.sorted()
                    if !values.isEmpty { widths[level] = values[values.count / 2] }
                }
                return widths[.waist] != nil || widths[.hip] != nil ? widths : nil
            }.value
            capturing = false
            turn.capturing = false
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

    /// In the right place but still moving: one short word, not a sentence.
    private func holdStillHint() {
        guard Date().timeIntervalSince(lastHintAt) > 3, !audio.isSpeaking else { return }
        hint(String(localized: "Good, now hold still."))
    }

    private func nudge(_ fit: StopFit) {
        // Fitting in the picture and dropped arms are said straight away; turning waits a
        // little longer, since the user is usually still on the way.
        let urgent = fit == .openArms || fit == .stepBack || fit == .handsOutOfFrame
        guard Date().timeIntervalSince(lastHintAt) > (urgent ? 1.5 : 3), !audio.isSpeaking else { return }
        switch fit {
        case .ok: return
        case .handsOutOfFrame: hint(String(localized: "Step back until your hands fit in the picture too."))
        case .turnFurther: hint(String(localized: "Turn a little further clockwise."))
        case .turnBack: hint(String(localized: "A little too far. Turn back slightly, counter-clockwise."))
        case .comeCloser: hint(String(localized: "Come a little closer to the phone."))
        case .moveToCentre: hint(String(localized: "Move to the middle of the picture."))
        case .openArms: hint(String(localized: "Raise your arms to shoulder height, straight out to the sides."))
        case .stepBack: hint(String(localized: "Step back until you're fully visible, head to feet."))
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

        if turn.retaking {
            retakeQueue.removeAll { $0 == station }
            guard !retakeQueue.isEmpty else { return finishTurn() }
            return advance()
        }
        stage = .turning(Double(station + 1) / Double(StationScan.stationCount))
        guard station + 1 < StationScan.stationCount else {
            turn.station = station + 1
            return finishTurn()
        }
        advance()
    }

    /// On to the next stop, 45° further clockwise.
    private func advance() {
        let next = turn.station + 1
        turn.station = next
        turn.holding = false
        turn.fit = nil
        shownFit.reset(nil)
        stillness.reset()
        stationStart = Date()
        say(String(localized: "Good.") + " " + StationGuide.instruction(next))
    }

    /// Runs twice a second: helps when a stop is taking long.
    private func coach() {
        if Date().timeIntervalSince(turnStart) > maxTurnDuration { return finishTurn() }
        guard Date().timeIntervalSince(lastHintAt) > 8, !audio.isSpeaking else { return }
        if turn.reading == nil {
            hint(String(localized: "Step back into the frame."))
        } else if turn.fit == nil {
            hint(String(localized: "Stop and hold still for a moment."))
        } else {
            hint(StationGuide.instruction(turn.station))
        }
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
        // Opposite stops see the same outline; where they disagree one was off. A few such
        // stops are taken again instead of redoing the whole turn; many mean the turn as a
        // whole went wrong, and the measurement says how sure it is.
        if !retakesOffered {
            retakesOffered = true
            let retake = scan.stopsToRetake()
            if !retake.isEmpty, retake.count <= 3 {
                // Round again from the front, in the same 45° steps, measuring only the
                // stops that need it: easier to follow than jumping to a position.
                retakeQueue = retake.sorted()
                turn.retaking = true
                turn.station = 0
                turn.fit = nil
                shownFit.reset(nil)
                turnStart = Date()
                stationStart = Date()
                stillness.reset()
                audio.play(.problem)
                say(String(localized: "One more look at \(retake.count) position(s).") + " " + StationGuide.instruction(0),
                    priority: .high)
                return
            }
        }
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
                let findings = clothingFindings
                outcome = await Task.detached(priority: .userInitiated) {
                    Result { try Self.measure(front: frontResult, scan: scan, basics: basics, findings: findings) }
                }.value
            } catch {
                outcome = .failure(error)
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
        case 1: String(localized: "Turn 45 degrees clockwise and stop.")
        case 2: String(localized: "Another 45 degrees clockwise, so your left side faces the phone.")
        case 4: String(localized: "Another 45 degrees clockwise, so your back faces the phone.")
        case 6: String(localized: "Another 45 degrees clockwise, so your right side faces the phone.")
        case 7: String(localized: "Last one: another 45 degrees clockwise, and stop.")
        default: String(localized: "Another 45 degrees clockwise, and stop.")
        }
    }
}
