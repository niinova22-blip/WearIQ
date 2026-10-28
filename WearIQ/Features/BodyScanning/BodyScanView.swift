import BodyMeasurementEngine
import SwiftUI
import WearIQCore

struct BodyScanView: View {
    @State private var model: BodyScanViewModel
    let onFinished: (BodyProfile) -> Void
    let onManualEntry: () -> Void

    init(body: BodyBasics, onFinished: @escaping (BodyProfile) -> Void, onManualEntry: @escaping () -> Void) {
        _model = State(initialValue: BodyScanViewModel(basics: body))
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

    // Text on this screen is read from 2–3 m away, so it is much larger than usual.

    private var header: some View {
        HStack(spacing: Theme.Spacing.m) {
            stepBadge(1, active: model.pose == .front, title: "Front")
            stepBadge(2, active: model.pose == .side, title: "Side")
        }
        .padding(.vertical, Theme.Spacing.s)
        .padding(.horizontal, Theme.Spacing.m)
        .background(.black.opacity(0.6), in: Capsule())
    }

    private func stepBadge(_ n: Int, active: Bool, title: LocalizedStringKey) -> some View {
        Label { Text(title) } icon: { Text("\(n)").monospacedDigit() }
            .font(.system(size: 26, weight: active ? .heavy : .regular, design: .rounded))
            .foregroundStyle(active ? .white : .white.opacity(0.5))
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
                .font(.system(size: 220, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .shadow(color: .black.opacity(0.8), radius: 12)
                .accessibilityLabel(Text("Taking photo in \(n)"))
        case .analyzing:
            VStack(spacing: Theme.Spacing.m) {
                ProgressView().tint(.white).controlSize(.large)
                Text("Measuring on your device…")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(Theme.Spacing.l)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        case let .failed(message):
            Card {
                Label("Scan didn't work", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                Text(message).font(.subheadline)
                Button("Continue with estimated values") { onFinished(model.basics.estimatedProfile()) }
                    .buttonStyle(.primary)
                Text("Estimated from your height and weight. You can correct each value with a tape measure.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Try again") { model.retry(); Task { await model.start() } }
                    .frame(maxWidth: .infinity)
                Button("Enter measurements manually", action: onManualEntry)
                    .frame(maxWidth: .infinity)
            }
        case .completed:
            VStack(spacing: Theme.Spacing.m) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 88, weight: .bold))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: model.stage)
                Text("Scan complete")
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(Theme.Spacing.xl)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .transition(.scale.combined(with: .opacity))
            .sensoryFeedback(.success, trigger: model.stage)
        case .finished:
            EmptyView()
        }
        if model.pose == .side, model.stage != .analyzing, model.stage != .finished, model.stage != .completed {
            Button("Skip side photo (less accurate)") { model.skipSidePhoto() }
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.vertical, Theme.Spacing.s)
                .padding(.horizontal, Theme.Spacing.m)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(.top, Theme.Spacing.s)
        }
    }

    private func instructionCard(_ text: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 56, weight: .bold))
            Text(text)
                .font(.system(size: 36, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(3)
        }
        .foregroundStyle(tint)
        .multilineTextAlignment(.center)
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
