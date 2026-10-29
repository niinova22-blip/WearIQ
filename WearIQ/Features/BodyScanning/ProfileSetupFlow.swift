import AVFoundation
import BodyMeasurementEngine
import ProductMeasurementParser
import SwiftUI
import WearIQCore

/// Height, weight & preferences → camera permission → front/side scan → review & correct.
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
    @AppStorage("usualTopSize") private var usualTopSize: String = ""
    @AppStorage("usualWaistSize") private var usualWaistSize: String = ""
    @AppStorage("fitPreference") private var fitPreference: FitPreference = .asDesigned
    @State private var path: [Step] = []

    var body: some View {
        NavigationStack(path: $path) {
            HeightPreferencesView(heightCm: $heightCm, weightKg: $weightKg, sexRaw: $sexRaw,
                                  usualTopSize: $usualTopSize, usualWaistSize: $usualWaistSize, preference: $fitPreference) {
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
        BodyBasics(heightCm: heightCm, weightKg: weightKg, sex: BodySex(rawValue: sexRaw),
                   usualTopSize: usualTopSize, usualWaistSize: usualWaistSize)
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
    /// The sizes the user usually buys ("M", waist "32"); empty if not given.
    var usualTopSize: String = ""
    var usualWaistSize: String = ""

    /// Best estimate without photos: height/weight statistics, sharpened by the sizes the
    /// user usually wears (a size label pins chest, waist and hip to a few centimetres).
    func prior() -> [BodyDimension: MeasuredValue] {
        var values = AnthropometricPrior().estimate(heightCm: heightCm, weightKg: weightKg, sex: sex)
        let audience: GarmentAudience? = sex.map { $0 == .female ? .women : .men }
        var fromSizes: [BodyDimension: MeasuredValue] = [:]
        if !usualTopSize.isEmpty, let size = StandardSizeCharts.chart(for: [usualTopSize], category: .shirt, audience: audience)?.sizes.first {
            fromSizes[.chest] = size.values[.chest]
            fromSizes[.waist] = size.values[.waist]
            fromSizes[.hip] = size.values[.hip]
        }
        if !usualWaistSize.isEmpty, let size = StandardSizeCharts.chart(for: [usualWaistSize], category: .pants, audience: audience)?.sizes.first {
            // A trouser size describes the waist better than a top size does.
            fromSizes[.waist] = size.values[.waist]
            fromSizes[.hip] = size.values[.hip] ?? fromSizes[.hip]
        }
        for (dim, s) in fromSizes {
            // Size charts give ranges; brands differ, so count it as a ±4 cm reading.
            let reading = MeasuredValue(cm: s.cm, uncertaintyCm: 4, source: .estimated)
            guard let p = values[dim] else { values[dim] = reading; continue }
            let vp = p.uncertaintyCm * p.uncertaintyCm, vs = reading.uncertaintyCm * reading.uncertaintyCm
            values[dim] = MeasuredValue(cm: (p.cm / vp + reading.cm / vs) / (1 / vp + 1 / vs),
                                        uncertaintyCm: (1 / (1 / vp + 1 / vs)).squareRoot(), source: .estimated)
        }
        return values
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
    @Binding var usualTopSize: String
    @Binding var usualWaistSize: String
    @Binding var preference: FitPreference
    let onContinue: () -> Void

    var body: some View {
        Form {
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
                Picker("Body type", selection: $sexRaw) {
                    Text("Male").tag(BodySex.male.rawValue)
                    Text("Female").tag(BodySex.female.rawValue)
                    Text("Prefer not to say").tag("")
                }
            } header: {
                Text("Your weight")
            } footer: {
                Text("Used to estimate values the photos can't show clearly. Stays on this device.")
            }
            Section {
                Picker("Tops", selection: $usualTopSize) {
                    Text("Not sure").tag("")
                    ForEach(["XS", "S", "M", "L", "XL", "XXL", "3XL"], id: \.self) { Text($0).tag($0) }
                }
                Picker("Trousers (waist)", selection: $usualWaistSize) {
                    Text("Not sure").tag("")
                    ForEach(["26", "28", "29", "30", "31", "32", "33", "34", "36", "38", "40"], id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text("Sizes you usually wear")
            } footer: {
                Text("Makes chest, waist and hip estimates much closer.")
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
            Button("Continue", action: onContinue)
                .buttonStyle(.primary)
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
