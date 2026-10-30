import AVFoundation
import BodyMeasurementEngine
import ProductMeasurementParser
import SwiftData
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
    /// 0 until the user picks an age.
    @AppStorage("ageYears") private var ageYears: Double = 0
    @AppStorage("fitPreference") private var fitPreference: FitPreference = .asDesigned
    @State private var path: [Step] = []
    /// What the user said they wear for this scan; nil until they pick.
    @State private var attire: ScanAttire?
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]

    var body: some View {
        NavigationStack(path: $path) {
            HeightPreferencesView(heightCm: $heightCm, weightKg: $weightKg, sexRaw: $sexRaw, ageYears: $ageYears,
                                  preference: $fitPreference) {
                path.append(.scanGuide)
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .scanGuide:
                    ScanGuideView(attire: $attire, onScan: { path.append(.scan) }, onManual: startManualEntry)
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
        BodyBasics(heightCm: heightCm, weightKg: weightKg, sex: BodySex(rawValue: sexRaw),
                   ageYears: ageYears > 0 ? ageYears : nil, attire: attire, previous: profiles.first?.profile)
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
    /// Sharpens the waist estimate; optional.
    var ageYears: Double?
    /// What the user wears for the scan; decides how much of the outline is clothes.
    var attire: ScanAttire?
    /// The last saved profile: its tape and fitted-clothes values help a scan in
    /// everyday clothes.
    var previous: BodyProfile?

    /// Best estimate without photos: height/weight (and age) statistics.
    func prior() -> [BodyDimension: MeasuredValue] {
        AnthropometricPrior().estimate(heightCm: heightCm, weightKg: weightKg, sex: sex, ageYears: ageYears)
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
    @Binding var ageYears: Double
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
                Picker("Age", selection: Binding(get: { Int(ageYears) }, set: { ageYears = Double($0) })) {
                    Text("Not set").tag(0)
                    ForEach(18...90, id: \.self) { Text("\($0)").tag($0) }
                }
            } header: {
                Text("Weight and age")
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
    /// The scan measures the outline, so loose clothes would be measured as body.
    /// Starting needs the user to say what they wear: fitted clothes are measured
    /// directly; with everyday clothes the scan works out what is clothes and says how
    /// sure it is of each value.
    @Binding var attire: ScanAttire?
    let onScan: () -> Void
    let onManual: () -> Void

    @State private var status = CameraController.authorizationStatus
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                clothingCard
                tip("iphone.gen3", "Prop the phone upright at waist height, about 2–3 m away.")
                tip("lightbulb", "Use a bright room with a plain background.")
                tip("figure.arms.open", "First a front photo: face the phone, arms slightly away from your body.")
                tip("arrow.trianglehead.2.clockwise.rotate.90", "Then hold your arms straight out and turn clockwise in 8 small steps, stopping at each one. The voice tells you where to face; this measures your chest, waist and hips.")
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
                        .disabled(attire == nil)
                }
                Button("Enter measurements manually", action: onManual)
            }
            .padding(Theme.Spacing.m)
            .background(.bar)
        }
    }

    private var clothingCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Label("For the most accurate measurements", systemImage: "tshirt.fill")
                .font(.title3.weight(.bold))
            Text("The scan measures your outline, so every layer of loose clothing adds centimetres.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Label("Best: scan in your underwear. The photos never leave this phone; they're analysed here and deleted right after measuring.",
                  systemImage: "1.circle.fill")
                .font(.subheadline)
            Label("Otherwise: a fitted T-shirt or tank top with leggings or fitted shorts. Tie long hair up.",
                  systemImage: "2.circle.fill")
                .font(.subheadline)
            Text("What are you wearing?")
                .font(.headline)
                .padding(.top, Theme.Spacing.xs)
            attireOption(.fitted, title: "Underwear or fitted clothes",
                         detail: "Most accurate: your outline is your body.")
            attireOption(.everyday, title: "My everyday clothes",
                         detail: "Works too. Where clothes hide your body, values are estimated and shown with a range.")
        }
        .padding(Theme.Spacing.m)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            .strokeBorder(attire == nil ? Color.orange : .green, lineWidth: 1.5))
        .sensoryFeedback(.selection, trigger: attire)
    }

    private func attireOption(_ option: ScanAttire, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        Button {
            attire = option
        } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                Image(systemName: attire == option ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(attire == option ? Color.green : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(attire == option ? .isSelected : [])
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
