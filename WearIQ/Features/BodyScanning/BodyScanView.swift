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
            Group {
                switch model.stage {
                case .turning:
                    TurnGuideOverlay(state: model.turn)
                case .positioning, .countdown:
                    GeometryReader { proxy in
                        JointsView(joints: model.liveJoints, rect: cameraImageRect(in: proxy.size), tint: .cyan)
                    }
                default:
                    EmptyView()
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
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
        .sensoryFeedback(.impact(weight: .medium), trigger: model.turn.captured.count)
        .sensoryFeedback(.success, trigger: model.turn.measured.count)
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
        case .turning:
            let station = min(model.turn.station, StationScan.stationCount - 1)
            VStack(spacing: Theme.Spacing.m) {
                HStack(spacing: Theme.Spacing.l) {
                    StationDial(station: station, captured: model.turn.captured, holding: model.turn.holding)
                        .frame(width: 130, height: 130)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Step \(station + 1) of \(StationScan.stationCount)")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                            .monospacedDigit()
                        Text(StationGuide.title(station))
                            .font(.system(size: 38, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        fitLabel(model.turn.fit)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .contentTransition(.opacity)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: Theme.Spacing.s) {
                    ForEach([BodyLevel.chest, .waist, .hip], id: \.self) { level in
                        regionChip(level, done: model.turn.measured.contains(level))
                    }
                }
                // The one posture that lets chest, waist and hips all be measured.
                Label("Arms straight out · turn clockwise", systemImage: "figure.arms.open")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(Theme.Spacing.l)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .animation(.easeInOut(duration: 0.25), value: model.turn)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Step \(station + 1) of \(StationScan.stationCount): \(StationGuide.instruction(station))"))
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

    @ViewBuilder
    private func fitLabel(_ fit: StopFit?) -> some View {
        switch fit {
        case .ok:
            Label("Hold still…", systemImage: "pause.circle.fill").foregroundStyle(.green)
        case .turnFurther:
            Label("Turn further", systemImage: "arrow.clockwise").foregroundStyle(.yellow)
        case .turnBack:
            Label("Turned too far", systemImage: "arrow.counterclockwise").foregroundStyle(.orange)
        case .openArms:
            Label("Open your arms", systemImage: "figure.arms.open").foregroundStyle(.orange)
        case nil:
            Label("Turn and stop", systemImage: "arrow.clockwise").foregroundStyle(.yellow)
        }
    }

    private func regionChip(_ level: BodyLevel, done: Bool) -> some View {
        Label {
            Text(level.title)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dotted")
                .contentTransition(.symbolEffect(.replace))
        }
        .font(.system(size: 20, weight: .bold, design: .rounded))
        .foregroundStyle(done ? Color.black : .white)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(done ? Color.green : .white.opacity(0.18), in: Capsule())
        .animation(.spring(duration: 0.35), value: done)
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

/// Where the camera image sits on screen: portrait 9:16 frames, shown aspect-fit.
private func cameraImageRect(in size: CGSize) -> CGRect {
    let aspect = 9.0 / 16.0
    let width = min(size.width, size.height * aspect)
    let height = width / aspect
    return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
}

private func point(_ x: Double, _ y: Double, in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
}

/// The detected joints and the bones between them, drawn over the camera so the user
/// sees what the scan sees.
private struct JointsView: View {
    let joints: [BodyJoint: Point2D]
    let rect: CGRect
    let tint: Color

    private static let bones: [(BodyJoint, BodyJoint)] = [
        (.nose, .neck), (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.neck, .root), (.root, .leftHip), (.root, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]

    var body: some View {
        ZStack {
            Path { p in
                for (a, b) in Self.bones {
                    guard let pa = joints[a], let pb = joints[b] else { continue }
                    p.move(to: point(pa.x, pa.y, in: rect))
                    p.addLine(to: point(pb.x, pb.y, in: rect))
                }
            }
            .stroke(tint.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            ForEach(Array(joints.keys), id: \.self) { joint in
                if let j = joints[joint] {
                    Circle()
                        .fill(.white)
                        .overlay(Circle().stroke(tint, lineWidth: 2.5))
                        .frame(width: 11, height: 11)
                        .position(point(j.x, j.y, in: rect))
                }
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 2)
        .animation(.easeOut(duration: 0.15), value: joints)
    }
}

/// Guidance drawn over the camera during the turn, anchored to the person: the joints,
/// a ring on the floor with one sector per stop, and the chest, waist and hip lines
/// where the girths are measured, which turn green once measured from enough sides.
private struct TurnGuideOverlay: View {
    let state: BodyScanViewModel.TurnState

    var body: some View {
        GeometryReader { proxy in
            let rect = cameraImageRect(in: proxy.size)
            if let reading = state.reading {
                ZStack {
                    floorRing(reading, in: rect)
                    JointsView(joints: reading.joints, rect: rect, tint: state.fit == .ok ? .green : .cyan)
                    ForEach([BodyLevel.chest, .waist, .hip], id: \.self) { level in
                        if let band = reading.levels[level] {
                            bandView(level, band, in: rect)
                        }
                    }
                }
                .animation(.easeOut(duration: 0.18), value: reading)
            }
        }
    }

    private func bandView(_ level: BodyLevel, _ band: LevelReading, in rect: CGRect) -> some View {
        let done = state.measured.contains(level)
        let pad = 0.03
        let start = point(band.left - pad, band.y, in: rect)
        let end = point(band.right + pad, band.y, in: rect)
        let color: Color = done ? .green : .white
        let edgeLeft = point(band.left, band.y, in: rect)
        let edgeRight = point(band.right, band.y, in: rect)
        return ZStack {
            Path { p in
                p.move(to: start)
                p.addLine(to: end)
            }
            .stroke(color.opacity(done ? 1 : 0.85),
                    style: StrokeStyle(lineWidth: done ? 6 : 4, lineCap: .round, dash: done ? [] : [10, 8]))
            .shadow(color: color.opacity(done ? 0.9 : 0.4), radius: done ? 8 : 3)
            // The measured edges of the outline at this level.
            ForEach([edgeLeft, edgeRight], id: \.x) { edge in
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                    .position(edge)
            }
            Text(level.title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(done ? Color.black : .white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(done ? Color.green : .black.opacity(0.6), in: Capsule())
                .fixedSize()
                .position(x: start.x - 38, y: start.y)
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(color)
                .shadow(color: .black.opacity(0.6), radius: 4)
                .position(x: end.x + 22, y: end.y)
        }
        .animation(.spring(duration: 0.4), value: done)
    }

    /// An ellipse on the floor around the feet, one sector per stop, starting nearest
    /// the camera: captured stops are green, the current one is highlighted.
    private func floorRing(_ reading: FrameReading, in rect: CGRect) -> some View {
        let center = point(reading.centerX, reading.floor, in: rect)
        let width = Double(rect.width)
        let hipWidth: Double = reading.levels[.hip].map { ($0.right - $0.left) * width } ?? width * 0.2
        let rx: Double = Swift.max(hipWidth * 1.6, width * 0.24)
        return ZStack {
            ForEach(0..<StationScan.stationCount, id: \.self) { i in
                sector(i, center: center, rx: rx, ry: rx * 0.28)
            }
        }
    }

    private func sector(_ i: Int, center: CGPoint, rx: Double, ry: Double) -> some View {
        let done = state.captured.contains(i)
        let current = i == state.station
        let count = Double(StationScan.stationCount)
        let gap = 0.07
        // Centred on its direction: stop 0 is the point of the ring nearest the camera.
        // The preview is mirrored, so a turn to the user's right moves towards screen right.
        let a0 = Double.pi / 2 - (Double(i) - 0.5 + gap) / count * 2 * Double.pi
        let a1 = Double.pi / 2 - (Double(i) + 0.5 - gap) / count * 2 * Double.pi
        let path = Path { p in
            let steps = 12
            for s in 0...steps {
                let a = a0 + (a1 - a0) * Double(s) / Double(steps)
                let pt = CGPoint(x: Double(center.x) + rx * cos(a), y: Double(center.y) + ry * sin(a))
                if s == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
        let color: Color = done ? .green : current ? (state.holding ? .green : .yellow) : .white.opacity(0.3)
        return path
            .stroke(color, style: StrokeStyle(lineWidth: done || current ? 10 : 6, lineCap: .round))
            .shadow(color: done || current ? color.opacity(0.8) : Color.clear, radius: 6)
            .animation(.spring(duration: 0.35), value: done)
            .animation(.easeInOut(duration: 0.2), value: current)
    }
}

/// Top view of the turn as the user sees it: the phone ahead (top), the user in the
/// middle, eight stops around; turning right goes clockwise. The arrow shows which way
/// the user's chest should point at the current stop.
private struct StationDial: View {
    let station: Int
    let captured: Set<Int>
    let holding: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let radius = size / 2 - 8
            ZStack {
                ForEach(0..<StationScan.stationCount, id: \.self) { i in
                    let count = Double(StationScan.stationCount)
                    Circle()
                        .trim(from: (Double(i) - 0.5 + 0.08) / count, to: (Double(i) + 0.5 - 0.08) / count)
                        .stroke(color(i), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        // trim starts at 3 o'clock; stop 0 sits at 12 o'clock, towards the phone.
                        .rotationEffect(.degrees(-90))
                        .frame(width: radius * 2, height: radius * 2)
                }
                Image(systemName: "arrow.up")
                    .font(.system(size: size * 0.26, weight: .heavy))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(Double(station) * 45))
                    .animation(.spring(duration: 0.5), value: station)
                Image(systemName: "iphone")
                    .font(.system(size: size * 0.13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .offset(y: -(size / 2 + 6))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func color(_ i: Int) -> Color {
        if captured.contains(i) { return .green }
        if i == station { return holding ? .green.opacity(0.7) : .yellow }
        return .white.opacity(0.25)
    }
}
