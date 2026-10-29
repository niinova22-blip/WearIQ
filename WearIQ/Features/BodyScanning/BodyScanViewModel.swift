import AVFoundation
import BodyMeasurementEngine
import BodyScanVision
import Observation
import WearIQCore

/// Front photo → slow 360° turn → on-device analysis.
///
/// The user props the phone up and steps back, so capture is hands-free: once the
/// pose has been good for a moment a countdown starts, and spoken cues tell the user
/// what to fix. The front photo gives lengths and shoulder width; the turn gives real
/// girths (see `RotationScanAnalyzer`). Height/weight statistics are only used to catch
/// failed detections, never as values. Images and masks live only in memory.
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

    private(set) var pose: ScanPose = .front
    private(set) var stage: Stage = .positioning(.noPerson)
    private(set) var result: BodyProfile?
    /// Values measured before a failure, so the user can keep them and add the rest.
    private(set) var partialResult: BodyProfile?
    var voiceGuidance = true
    /// After the front photo the next capture is the turn.
    private(set) var turnNext = false

    let camera = CameraController()
    let basics: BodyBasics
    private let vision = VisionBodyAnalyzer()
    private let guidance = PoseGuidance()
    private let speech = AVSpeechSynthesizer()

    private var goodSince: Date?
    private var countdownTask: Task<Void, Never>?
    private var frontImage: CGImage?
    private let turnFrames = FrameStore()
    /// Length of the recorded turn; a slow full turn takes about 12–15 s.
    private let turnDuration: TimeInterval = 15
    private var lastSpokenIssue: PoseIssue?
    private var lastSpokenAt = Date.distantPast

    /// How long the pose must be held before the countdown starts.
    private let holdDuration: TimeInterval = 1.0

    init(basics: BodyBasics) {
        self.basics = basics
    }

    func start() async {
        activateAudio()
        watchPose()
        do {
            try await camera.start(position: .front)
            speak(String(localized: "Stand facing the phone, arms slightly away from your body."))
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    func stop() {
        countdownTask?.cancel()
        camera.onFrame = nil
        camera.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func retry() {
        frontImage = nil
        turnFrames.reset()
        result = nil
        partialResult = nil
        turnNext = false
        pose = .front
        goodSince = nil
        stage = .positioning(.noPerson)
        watchPose()
    }

    /// Spoken guidance must be heard even with the ring/silent switch on, and should
    /// lower other audio rather than stop it.
    private func activateAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? session.setActive(true)
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
            speak(issue.instruction, for: issue)
            return
        }
        guard case .positioning = stage else { return }
        let now = Date()
        if goodSince == nil { goodSince = now }
        if let since = goodSince, now.timeIntervalSince(since) >= holdDuration {
            startCountdown()
        } else {
            stage = .positioning(nil)
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            for n in stride(from: 3, through: 1, by: -1) {
                guard let self, !Task.isCancelled else { return }
                self.stage = .countdown(n)
                self.speak("\(n)")
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled else { return }
            if self.turnNext { self.recordTurn() } else { self.capture() }
        }
    }

    /// Records the slow turn: every frame becomes a person mask; widths are averaged later.
    private func recordTurn() {
        turnFrames.reset()
        let vision = vision
        let store = turnFrames
        let start = Date()
        camera.frameRate = 8
        camera.onFrame = { buffer in
            if let frame = vision.turnFrame(buffer, time: Date().timeIntervalSince(start)) { store.append(frame) }
        }
        stage = .turning(0)
        speak(String(localized: "Now turn slowly all the way around."))
        countdownTask = Task { [weak self] in
            guard let self else { return }
            var spokeHalf = false
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(start)
                if elapsed >= self.turnDuration { break }
                self.stage = .turning(elapsed / self.turnDuration)
                if !spokeHalf, elapsed > self.turnDuration / 2 {
                    spokeHalf = true
                    self.speak(String(localized: "Keep turning slowly."))
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard !Task.isCancelled else { return }
            self.camera.onFrame = nil
            self.speak(String(localized: "You can stop now."))
            self.analyze()
        }
    }

    private func capture() {
        guard let image = camera.captureStill() else {
            stage = .positioning(.noPerson)
            return
        }
        goodSince = nil
        frontImage = image
        turnNext = true
        stage = .positioning(nil)
        speak(String(localized: "Great. Keep your arms slightly away from your body. After the countdown, turn slowly all the way around."))
    }

    private func analyze() {
        guard let front = frontImage else { return retry() }
        let frames = turnFrames.drain()
        let basics = basics
        stage = .analyzing
        camera.onFrame = nil

        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<BodyProfile, Error> in
                Result {
                    let vision = VisionBodyAnalyzer()
                    let f = try vision.analyze(front)
                    let frontObs = try SilhouetteAnalyzer().analyzeFront(mask: f.mask, joints: f.joints)
                    // Lengths and shoulder width from the front photo; its girths would rely
                    // on an assumed body depth, so they are replaced by the turn's.
                    var profile = try BodyMeasurementEngine().measure(heightCm: basics.heightCm, front: frontObs, side: nil)
                    for d in [BodyDimension.chest, .waist, .hip] { profile[d] = nil }
                    let top = frontObs.floorY - frontObs.personHeightPx
                    let fractions = frontObs.levels.mapValues { ($0.y - top) / frontObs.personHeightPx }
                    let girths = (try? RotationScanAnalyzer().girths(frames: frames, heightCm: basics.heightCm,
                                                                      levelFractions: fractions)) ?? [:]
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
                    // Height/weight statistics only flag impossible readings; they never
                    // become values.
                    let rejected = MeasurementFusion.fuse(scan: profile, prior: basics.prior()).rejected
                    for d in rejected { profile[d] = nil }
                    return profile
                }
            }.value

            // Photos are no longer needed once measured.
            frontImage = nil
            camera.stop()

            switch outcome {
            case let .success(profile):
                let missing = [BodyDimension.chest, .waist].filter { profile[$0] == nil }
                guard missing.isEmpty else {
                    partialResult = profile
                    stage = .failed(String(localized: "Your chest and waist couldn't be measured from the turn. Turn a little slower with your arms away from your body, in a bright room."))
                    speak(String(localized: "Let's try the turn again."))
                    return
                }
                result = profile
                stage = .completed
                speak(String(localized: "Scan complete. Your measurements are ready."))
                try? await Task.sleep(for: .seconds(2))
                stage = .finished
            case let .failure(error):
                stage = .failed(Self.message(for: error))
            }
        }
    }

    private func speak(_ text: String, for issue: PoseIssue? = nil) {
        guard voiceGuidance else { return }
        let now = Date()
        if let issue, issue == lastSpokenIssue, now.timeIntervalSince(lastSpokenAt) < 4 { return }
        lastSpokenIssue = issue
        lastSpokenAt = now
        speech.stopSpeaking(at: .word)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice
        // A little slower and lower than the default sounds calmer and more natural.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.pitchMultiplier = 0.95
        utterance.preUtteranceDelay = 0.05
        speech.speak(utterance)
    }

    /// The most natural installed voice for the app language: premium, then enhanced
    /// (Siri-quality voices the user may have downloaded), then the default.
    private static let voice: AVSpeechSynthesisVoice? = {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
        return voices.first { $0.quality == .premium }
            ?? voices.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
            ?? AVSpeechSynthesisVoice(language: language)
    }()

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

/// Turn frames arrive on the camera queue and are read on the main actor.
private final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [RotationFrame] = []

    func append(_ frame: RotationFrame) { lock.withLock { frames.append(frame) } }
    func reset() { lock.withLock { frames.removeAll() } }
    func drain() -> [RotationFrame] { lock.withLock { defer { frames.removeAll() }; return frames } }
}
