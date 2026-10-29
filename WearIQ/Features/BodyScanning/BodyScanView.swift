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
            stepBadge(1, active: !model.turnNext, title: "Front")
            stepBadge(2, active: model.turnNext, title: "Turn")
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
        case let .turning(progress):
            VStack(spacing: Theme.Spacing.m) {
                ZStack {
                    Circle().stroke(.white.opacity(0.25), lineWidth: 14)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: progress)
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.system(size: 52, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 170, height: 170)
                Text("Turn slowly")
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(Theme.Spacing.l)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Turning, \(Int(progress * 100)) percent"))
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
                Button("Try again") { model.retry(); Task { await model.start() } }
                    .buttonStyle(.primary)
                if let partial = model.partialResult {
                    Button("Keep what was measured") { onFinished(partial) }
                        .frame(maxWidth: .infinity)
                }
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
