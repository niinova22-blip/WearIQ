import AVFoundation
import BodyMeasurementEngine
import ProductMeasurementParser
import SwiftUI
import WearIQCore

/// Gender, height, weight & fit preference → camera permission → scan → review & correct.
/// Used after onboarding and for re-scanning from the profile tab.
struct ProfileSetupFlow: View {
    /// The review step carries its profile. Keeping it in separate @State broke on device:
    /// the destination was built from a stale body and showed an empty profile.
    enum Step: Hashable {
        case scanGuide
        case scan
        case review(BodyProfile)
    }

    let onFinished: () -> Void

    @AppStorage("heightCm") private var heightCm: Double = 175
    @AppStorage("weightKg") private var weightKg: Double = 75
    @AppStorage("bodySex") private var sexRaw: String = ""
    @AppStorage("fitPreference") private var fitPreference: FitPreference = .asDesigned
    @State private var path: [Step] = []

    var body: some View {
        NavigationStack(path: $path) {
            HeightPreferencesView(heightCm: $heightCm, weightKg: $weightKg, sexRaw: $sexRaw, preference: $fitPreference) {
                path.append(.scanGuide)
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .scanGuide:
                    ScanGuideView(onScan: { path.append(.scan) }, onManual: startManualEntry)
                case .scan:
                    BodyScanView(body: bodyBasics) { scanned in
                        path.append(.review(scanned))
                    } onManualEntry: {
                        startManualEntry()
                    }
                case let .review(profile):
                    MeasurementReviewView(profile: profile, onSaved: onFinished)
                }
            }
        }
    }

    private var bodyBasics: BodyBasics {
        BodyBasics(heightCm: heightCm, weightKg: weightKg, sex: BodySex(rawValue: sexRaw))
    }

    /// Starts from height/weight estimates so the user corrects values instead of typing all of them.
    private func startManualEntry() {
        path.append(.review(bodyBasics.estimatedProfile()))
    }
}

/// What the user tells us before scanning.
struct BodyBasics: Equatable, Sendable {
    var heightCm: Double
    var weightKg: Double
    var sex: BodySex?

    /// Best estimate without photos: height/weight statistics.
    func prior() -> [BodyDimension: MeasuredValue] {
        AnthropometricPrior().estimate(heightCm: heightCm, weightKg: weightKg, sex: sex)
    }

    /// Height as typed, everything else estimated.
    func estimatedProfile() -> BodyProfile {
        var values = prior()
        values[.height] = MeasuredValue(cm: heightCm, uncertaintyCm: 1, source: .userProvided)
        return BodyProfile(values: values, weightKg: weightKg, sex: sex)
    }
}

struct HeightPreferencesView: View {
    @Binding var heightCm: Double
    @Binding var weightKg: Double
    @Binding var sexRaw: String
    @Binding var preference: FitPreference
    let onContinue: () -> Void

    var body: some View {
        Form {
            // Body proportions and size charts differ between men and women, so this
            // comes first and has to be answered.
            Section {
                Picker("Gender", selection: $sexRaw) {
                    Text("Male").tag(BodySex.male.rawValue)
                    Text("Female").tag(BodySex.female.rawValue)
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } header: {
                Text("Gender")
            } footer: {
                Text("Needed to use the right body proportions and size charts.")
            }
            Section {
                Picker("Height", selection: Binding(get: { Int(heightCm) }, set: { heightCm = Double($0) })) {
                    ForEach(120...230, id: \.self) { Text("\($0) cm").tag($0) }
                }
                .pickerStyle(.wheel)
            } header: {
                Text("Your height")
            } footer: {
                Text("Your height is the ruler for every other measurement, so please enter it accurately.")
            }
            Section {
                Picker("Weight", selection: Binding(get: { Int(weightKg) }, set: { weightKg = Double($0) })) {
                    ForEach(35...200, id: \.self) { Text("\($0) kg").tag($0) }
                }
                .pickerStyle(.wheel)
            } header: {
                Text("Your weight")
            } footer: {
                Text("Used to estimate values the photos can't show clearly. Stays on this device.")
            }
            Section("How do you like clothes to fit?") {
                Picker("Fit", selection: $preference) {
                    Text("Snugger").tag(FitPreference.snugger)
                    Text("As designed").tag(FitPreference.asDesigned)
                    Text("Looser").tag(FitPreference.looser)
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("About you")
        .safeAreaInset(edge: .bottom) {
            Button(BodySex(rawValue: sexRaw) == nil ? LocalizedStringKey("Choose your gender to continue") : "Continue", action: onContinue)
                .buttonStyle(.primary)
                .disabled(BodySex(rawValue: sexRaw) == nil)
                .padding(Theme.Spacing.m)
        }
    }
}

struct ScanGuideView: View {
    let onScan: () -> Void
    let onManual: () -> Void

    @State private var status = CameraController.authorizationStatus
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                tip("iphone.gen3", "Prop the phone upright at waist height, about 2–3 m away.")
                tip("tshirt", "Wear fitted clothes (e.g. sportswear) so your outline is visible.")
                tip("lightbulb", "Use a bright room with a plain background.")
                tip("figure.arms.open", "First a front photo: face the phone, arms slightly away from your body.")
                tip("arrow.trianglehead.2.clockwise.rotate.90", "Then turn on the spot in 8 small steps, stopping briefly at each one. The voice tells you where to face; this measures your chest, waist and hips.")
                tip("speaker.wave.2", "Voice cues guide you; the photo is taken automatically.")
                tip("lock.shield", "Photos are analysed on this device and deleted right after measuring.")
            }
            .padding(Theme.Spacing.m)
        }
        .navigationTitle("Body scan")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Theme.Spacing.s) {
                if status == .denied || status == .restricted {
                    Text("Camera access is off. You can allow it in Settings or enter your measurements with a tape measure.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(.primary)
                } else {
                    Button("Start scan") { Task { await requestAndScan() } }
                        .buttonStyle(.primary)
                }
                Button("Enter measurements manually", action: onManual)
            }
            .padding(Theme.Spacing.m)
            .background(.bar)
        }
    }

    private func tip(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(.tint) }
    }

    private func requestAndScan() async {
        if status == .notDetermined {
            _ = await CameraController.requestAccess()
            status = CameraController.authorizationStatus
        }
        if status == .authorized { onScan() }
    }
}
