import BodyMeasurementEngine
import SwiftUI
import WearIQCore

struct BodyScanView: View {
    @State private var model: BodyScanViewModel
    let onFinished: (BodyProfile) -> Void
    let onManualEntry: () -> Void

    init(heightCm: Double, onFinished: @escaping (BodyProfile) -> Void, onManualEntry: @escaping () -> Void) {
        _model = State(initialValue: BodyScanViewModel(heightCm: heightCm))
        self.onFinished = onFinished
        self.onManualEntry = onManualEntry
    }

    var body: some View {
        ZStack {
            CameraPreview(session: model.camera.session)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack {
                header
                Spacer()
                overlay
            }
            .padding(Theme.Spacing.m)
        }
        .background(.black)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.voiceGuidance.toggle()
                } label: {
                    Image(systemName: model.voiceGuidance ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }
                .accessibilityLabel(model.voiceGuidance ? Text("Turn voice guidance off") : Text("Turn voice guidance on"))
            }
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.stage) { _, stage in
            if stage == .finished, let profile = model.result { onFinished(profile) }
        }
        .sensoryFeedback(.success, trigger: model.pose)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            stepBadge(1, active: model.pose == .front, title: "Front")
            stepBadge(2, active: model.pose == .side, title: "Side")
        }
        .padding(Theme.Spacing.s)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func stepBadge(_ n: Int, active: Bool, title: LocalizedStringKey) -> some View {
        Label { Text(title) } icon: { Text("\(n)").monospacedDigit() }
            .font(.subheadline.weight(active ? .bold : .regular))
            .foregroundStyle(active ? .primary : .secondary)
            .padding(.horizontal, Theme.Spacing.s)
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.stage {
        case let .positioning(issue):
            instructionCard(issue?.instruction ?? String(localized: "Hold still…"),
                            symbol: issue == nil ? "checkmark.circle.fill" : "figure.stand",
                            tint: issue == nil ? .green : .white)
        case let .countdown(n):
            Text("\(n)")
                .font(.system(size: 120, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .shadow(radius: 8)
                .accessibilityLabel(Text("Taking photo in \(n)"))
        case .analyzing:
            VStack(spacing: Theme.Spacing.s) {
                ProgressView().tint(.white)
                Text("Measuring on your device…").foregroundStyle(.white)
            }
            .padding(Theme.Spacing.l)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        case let .failed(message):
            Card {
                Label("Scan didn't work", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                Text(message).font(.subheadline)
                Button("Try again") { model.retry(); Task { await model.start() } }
                    .buttonStyle(.primary)
                Button("Enter measurements manually", action: onManualEntry)
                    .frame(maxWidth: .infinity)
            }
        case .finished:
            EmptyView()
        }
        if model.pose == .side, model.stage != .analyzing, model.stage != .finished {
            Button("Skip side photo (less accurate)") { model.skipSidePhoto() }
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.top, Theme.Spacing.s)
        }
    }

    private func instructionCard(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.title3.weight(.semibold))
            .foregroundStyle(tint)
            .multilineTextAlignment(.center)
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .accessibilityAddTraits(.updatesFrequently)
    }
}
