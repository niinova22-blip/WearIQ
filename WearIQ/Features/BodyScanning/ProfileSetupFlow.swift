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
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                ScanTutorialView()
                hero
                steps
                prepGrid
                attireChoice
                privacy
            }
            .padding(Theme.Spacing.m)
        }
        .background(Theme.screenBackground)
        .navigationTitle("Body scan")
        .navigationBarTitleDisplayMode(.inline)
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
                    Button(attire == nil ? LocalizedStringKey("Choose what you're wearing") : LocalizedStringKey("Start scan")) {
                        Task { await requestAndScan() }
                    }
                    .buttonStyle(.primary)
                    .disabled(attire == nil)
                }
                Button("Enter measurements manually", action: onManual)
                    .font(.subheadline)
            }
            .padding(Theme.Spacing.m)
            .background(.bar)
        }
    }

    /// What this is, in one look.
    private var hero: some View {
        HStack(spacing: Theme.Spacing.m) {
            ZStack {
                Circle().fill(Theme.accentGradient).frame(width: 64, height: 64)
                Image(systemName: "figure.arms.open")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating)
            }
            .shadow(color: .pink.opacity(0.35), radius: 12, y: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text("About a minute").font(.title2.bold())
                Text("Voice guidance leads you; the turn is filmed and measured on this phone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The three steps, numbered.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, "A front photo", "Face the phone, arms slightly away from your body.")
            step(2, "One slow turn", "After 3, 2, 1: arms straight out to the sides, turn once round while counting to six.")
            step(3, "Your measurements", "Chest, waist, hips and lengths, ready to check.")
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private func step(_ n: Int, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(n)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Theme.accentGradient, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// Getting ready, as four tiles.
    private var prepGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            prepTile("iphone.gen3", "Phone upright at waist height, 3 m away")
            prepTile("lightbulb.max", "Bright room, plain background")
            prepTile("shoeprints.fill", "Barefoot, long hair tied up")
            prepTile("speaker.wave.2.fill", "Sound on: you'll be facing away")
        }
    }

    private func prepTile(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint)
            Text(text).font(.footnote.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .padding(12)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The scan measures the outline: what the user wears decides how it reads it.
    private var attireChoice: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("What are you wearing?").font(.headline)
            HStack(spacing: 10) {
                attireTile(.fitted, symbol: "figure.stand", title: "Fitted or underwear", detail: "Most accurate")
                attireTile(.everyday, symbol: "tshirt", title: "Everyday clothes", detail: "Shown with a range")
            }
        }
        .sensoryFeedback(.selection, trigger: attire)
    }

    private func attireTile(_ option: ScanAttire, symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        let on = attire == option
        return Button {
            withAnimation(.snappy) { attire = option }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: symbol).font(.title2)
                    Spacer()
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(on ? Color.green : .secondary)
                }
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(on ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.clear), lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Where the photos go: nowhere.
    private var privacy: some View {
        Label {
            Text("Photos are processed only on this phone and deleted right away. Nothing is sent anywhere.")
                .font(.footnote)
        } icon: {
            Image(systemName: "lock.shield.fill").foregroundStyle(.green)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func requestAndScan() async {
        if status == .notDetermined {
            _ = await CameraController.requestAccess()
            status = CameraController.authorizationStatus
        }
        if status == .authorized { onScan() }
    }
}
