import AVFoundation
import BodyMeasurementEngine
import BodyScanVision
import Observation
import WearIQCore

/// Front photo → side photo → on-device analysis.
///
/// The user props the phone up and steps back, so capture is hands-free: once the
/// pose has been good for a moment a countdown starts, and spoken cues tell the user
/// what to fix. Captured images live only in memory and are released after analysis.
@MainActor
@Observable
final class BodyScanViewModel {
    enum Stage: Equatable {
        case positioning(PoseIssue?)
        case countdown(Int)
        case analyzing
        case failed(String)
        case finished
    }

    private(set) var pose: ScanPose = .front
    private(set) var stage: Stage = .positioning(.noPerson)
    private(set) var result: BodyProfile?
    var voiceGuidance = true

    let camera = CameraController()
    let basics: BodyBasics
    private let vision = VisionBodyAnalyzer()
    private let guidance = PoseGuidance()
    private let speech = AVSpeechSynthesizer()

    private var goodSince: Date?
    private var countdownTask: Task<Void, Never>?
    private var frontImage: CGImage?
    private var sideImage: CGImage?
    private var lastSpokenIssue: PoseIssue?
    private var lastSpokenAt = Date.distantPast

    /// How long the pose must be held before the countdown starts.
    private let holdDuration: TimeInterval = 1.0

    init(basics: BodyBasics) {
        self.basics = basics
    }

    func start() async {
        let vision = vision
        camera.onFrame = { [weak self] buffer in
            let joints = vision.detectJoints(in: buffer)
            Task { @MainActor in self?.handle(joints) }
        }
        do {
            try await camera.start(position: .front)
            speak(pose == .front ? String(localized: "Stand facing the phone, arms slightly away from your body.")
                                 : String(localized: "Turn to your side."))
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    func stop() {
        countdownTask?.cancel()
        camera.onFrame = nil
        camera.stop()
    }

    /// Lets the user continue with only the front photo. Girths then use typical body
    /// proportions and are marked low confidence.
    func skipSidePhoto() {
        guard pose == .side else { return }
        countdownTask?.cancel()
        analyze()
    }

    func retry() {
        frontImage = nil
        sideImage = nil
        result = nil
        pose = .front
        goodSince = nil
        stage = .positioning(.noPerson)
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
            self.capture()
        }
    }

    private func capture() {
        guard let image = camera.captureStill() else {
            stage = .positioning(.noPerson)
            return
        }
        goodSince = nil
        switch pose {
        case .front:
            frontImage = image
            pose = .side
            stage = .positioning(nil)
            speak(String(localized: "Great. Now turn to your side and keep your arms relaxed."))
        case .side:
            sideImage = image
            analyze()
        }
    }

    private func analyze() {
        guard let front = frontImage else { return retry() }
        let side = sideImage
        let basics = basics
        stage = .analyzing
        camera.onFrame = nil

        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<BodyProfile, Error> in
                Result {
                    let vision = VisionBodyAnalyzer()
                    let silhouette = SilhouetteAnalyzer()
                    let f = try vision.analyze(front)
                    let frontObs = try silhouette.analyzeFront(mask: f.mask, joints: f.joints)
                    let sideObs = try side.map { img -> ScanObservation in
                        let s = try vision.analyze(img)
                        return try silhouette.analyzeSide(mask: s.mask, front: frontObs)
                    }
                    var scanned = try BodyMeasurementEngine().measure(heightCm: basics.heightCm, front: frontObs, side: sideObs)
                    scanned.weightKg = basics.weightKg
                    scanned.sex = basics.sex
                    // Photo values that disagree wildly with height/weight statistics are
                    // detection errors; the estimate fills them and any value the photos missed.
                    let prior = AnthropometricPrior().estimate(heightCm: basics.heightCm, weightKg: basics.weightKg, sex: basics.sex)
                    return MeasurementFusion.fuse(scan: scanned, prior: prior).profile
                }
            }.value

            // Photos are no longer needed once measured.
            frontImage = nil
            sideImage = nil
            camera.stop()

            switch outcome {
            case let .success(profile):
                result = profile
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
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier)
        speech.speak(utterance)
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
