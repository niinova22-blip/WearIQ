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
                case let .positioning(issue):
                    PositioningOverlay(reading: model.liveReading, good: issue == nil)
                case .countdown:
                    PositioningOverlay(reading: model.liveReading, good: true)
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
        case .turning where !model.turn.clothing.isEmpty:
            clothingCard(model.turn.clothing)
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
        case .clothesSuspected:
            Card {
                Label("Your clothes may have been measured", systemImage: "tshirt.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Chest, waist and hips came out well above what your height, weight and age suggest. Loose clothes add several centimetres. For the right sizes, scan again in fitted clothes or underwear; the photos never leave your phone.")
                    .font(.subheadline)
                Button("Scan again") { model.retry(); Task { await model.start() } }
                    .buttonStyle(.primary)
                Button("Keep these measurements") { model.keepDespiteClothes() }
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

    /// Shown when the outline says the clothes are too loose to measure through.
    private func clothingCard(_ findings: [ClothingCheck.Finding]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Label("Your clothes look loose", systemImage: "tshirt.fill")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(.orange)
            Text(findings.contains(.looseSleeves) && findings.contains(.looseTop)
                 ? "Your sleeves and top look loose, which adds centimetres to every measurement."
                 : findings.contains(.looseSleeves)
                 ? "Your sleeves look loose, which adds centimetres to the measurements."
                 : "Your top hides your waist, which adds centimetres to the measurements.")
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
            Text("Take it off or change into something fitted, then come back to the front position.")
                .font(.system(size: 18, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            Button("I've changed, try again") { model.retryAfterChangingClothes() }
                .buttonStyle(.primary)
            Button("Continue anyway") { model.dismissClothingWarning() }
                .frame(maxWidth: .infinity)
                .foregroundStyle(.white)
        }
        .padding(Theme.Spacing.l)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    @ViewBuilder
    private func fitLabel(_ fit: StopFit?) -> some View {
        switch fit {
        case .ok:
            Label("Hold still…", systemImage: "pause.circle.fill").foregroundStyle(.green)
        case .turnFurther:
            Label("Turn further", systemImage: "arrow.clockwise").foregroundStyle(.yellow)
        case .turnBack:
            Label("Turn back counter-clockwise", systemImage: "arrow.counterclockwise").foregroundStyle(.orange)
        case .openArms:
            Label("Open your arms", systemImage: "figure.arms.open").foregroundStyle(.orange)
        case .stepBack:
            Label("Step back", systemImage: "arrow.down.to.line").foregroundStyle(.orange)
        case .comeCloser:
            Label("Come closer", systemImage: "arrow.up.to.line").foregroundStyle(.orange)
        case .moveToCentre:
            Label("Move to the middle", systemImage: "arrow.left.and.right").foregroundStyle(.orange)
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

/// The person's own outline, traced live from the segmentation, so the user sees what
/// the scan sees: whether the arms are out and whether head and feet are in the picture.
private struct LiveOutline: View {
    let outline: [OutlineRow]
    let rect: CGRect
    let tint: Color

    var body: some View {
        let shape = Path { p in
            guard let first = outline.first else { return }
            p.move(to: point(first.left, first.y, in: rect))
            for row in outline.dropFirst() { p.addLine(to: point(row.left, row.y, in: rect)) }
            for row in outline.reversed() { p.addLine(to: point(row.right, row.y, in: rect)) }
            p.closeSubpath()
        }
        ZStack {
            shape.fill(tint.opacity(0.22))
            shape.stroke(tint, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                .shadow(color: tint.opacity(0.7), radius: 5)
        }
        .animation(.easeOut(duration: 0.15), value: outline)
    }
}

/// During the turn: the target pose for the current stop, and the user's live outline on top.
private struct TurnGuideOverlay: View {
    let state: BodyScanViewModel.TurnState

    var body: some View {
        GeometryReader { proxy in
            let rect = cameraImageRect(in: proxy.size)
            let matched = state.fit == .ok
            ZStack {
                TargetFigure(pose: .armsOut(station: min(state.station, StationScan.stationCount - 1)),
                             matched: matched, rect: rect)
                if let reading = state.reading {
                    LiveOutline(outline: reading.outline, rect: rect, tint: matched ? .green : .cyan)
                }
            }
        }
    }
}

/// Before the front photo: the target stance and the live outline.
private struct PositioningOverlay: View {
    let reading: FrameReading?
    let good: Bool

    var body: some View {
        GeometryReader { proxy in
            let rect = cameraImageRect(in: proxy.size)
            ZStack {
                TargetFigure(pose: .front, matched: good, rect: rect)
                if let reading {
                    LiveOutline(outline: reading.outline, rect: rect, tint: good ? .green : .cyan)
                }
            }
        }
    }
}

/// A see-through human figure showing where and how to stand: in the middle of the
/// picture at a good distance. For the front photo the arms hang slightly away from the
/// body; during the turn they are held straight out and the figure is turned clockwise
/// by 45° per stop, with a nose showing where the face points (hidden from behind). It
/// turns green while the user matches it.
///
/// Built from typical body proportions in stature units: each part's half-width seen at
/// an angle is √((w·cos θ)² + (d·sin θ)²) for its front half-width w and side half-depth d.
private struct TargetFigure: View {
    enum Pose: Equatable {
        case front
        case armsOut(station: Int)
    }

    let pose: Pose
    let matched: Bool
    let rect: CGRect

    /// (height above the floor, front half-width, side half-depth) up the torso and neck.
    private static let torso: [(y: Double, w: Double, d: Double)] = [
        (0.47, 0.095, 0.075), (0.52, 0.105, 0.078), (0.56, 0.095, 0.070), (0.60, 0.085, 0.062),
        (0.66, 0.092, 0.066), (0.72, 0.100, 0.072), (0.78, 0.115, 0.066), (0.815, 0.12, 0.060),
        (0.83, 0.05, 0.045), (0.87, 0.035, 0.040),
    ]
    /// One leg: (height, half-width, half-depth), centred 0.055 out from the middle.
    private static let leg: [(y: Double, w: Double, d: Double)] = [
        (0.0, 0.040, 0.075), (0.04, 0.030, 0.035), (0.28, 0.042, 0.045), (0.40, 0.055, 0.060), (0.49, 0.065, 0.070),
    ]

    var body: some View {
        let theta: Double = switch pose {
        case let .armsOut(station): Double(station) * 45 * .pi / 180
        case .front: 0
        }
        let c = cos(theta), s = sin(theta)
        let stature = 0.56 * rect.height
        let floor = rect.minY + 0.93 * rect.height
        let mid = rect.midX
        func half(_ w: Double, _ d: Double) -> Double { ((w * c) * (w * c) + (d * s) * (d * s)).squareRoot() }
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: mid + x * stature, y: floor - y * stature) }

        let figure = Path { p in
            // Torso and neck.
            let rows = Self.torso
            p.move(to: pt(-half(rows[0].w, rows[0].d), rows[0].y))
            for r in rows.dropFirst() { p.addLine(to: pt(-half(r.w, r.d), r.y)) }
            for r in rows.reversed() { p.addLine(to: pt(half(r.w, r.d), r.y)) }
            p.closeSubpath()
            // Legs: their centres come together as the body turns side-on.
            for side in [-1.0, 1.0] {
                let centre = side * 0.055 * abs(c)
                p.move(to: pt(centre - half(Self.leg[0].w, Self.leg[0].d), Self.leg[0].y))
                for r in Self.leg.dropFirst() { p.addLine(to: pt(centre - half(r.w, r.d), r.y)) }
                for r in Self.leg.reversed() { p.addLine(to: pt(centre + half(r.w, r.d), r.y)) }
                p.closeSubpath()
            }
            // Head.
            let headW = half(0.058, 0.07) * stature, headH = 0.125 * stature
            p.addEllipse(in: CGRect(x: mid - headW, y: floor - 0.997 * stature, width: 2 * headW, height: headH))
            // Arms.
            switch pose {
            case .front:
                // Hanging slightly away from the body, about 15° out.
                for side in [-1.0, 1.0] {
                    let shoulder = pt(side * 0.115, 0.80), hand = pt(side * 0.20, 0.46)
                    p.addPath(Self.limb(from: shoulder, to: hand, width: 0.055 * stature))
                }
            case .armsOut:
                // Straight out at shoulder height; seen side-on they point at the phone.
                for side in [-1.0, 1.0] {
                    let reach = side * 0.5 * c
                    p.addPath(Self.limb(from: pt(side * 0.1 * abs(c), 0.80), to: pt(reach, 0.80), width: 0.055 * stature))
                }
            }
        }
        let color: Color = matched ? .green : .white
        let showNose = c > -0.3
        let nose = pt(0.075 * s, 0.935)
        return ZStack {
            figure.fill(color.opacity(matched ? 0.25 : 0.14))
            figure.stroke(color.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineJoin: .round, dash: [8, 6]))
            if showNose, case .armsOut = pose {
                Circle().fill(color.opacity(0.8))
                    .frame(width: 0.03 * stature, height: 0.03 * stature)
                    .position(nose)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: pose)
        .animation(.easeInOut(duration: 0.2), value: matched)
    }

    /// A rounded bar between two points.
    private static func limb(from a: CGPoint, to b: CGPoint, width: Double) -> Path {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max((dx * dx + dy * dy).squareRoot(), 1)
        let nx = -dy / length * width / 2, ny = dx / length * width / 2
        var p = Path()
        p.move(to: CGPoint(x: a.x + nx, y: a.y + ny))
        p.addLine(to: CGPoint(x: b.x + nx, y: b.y + ny))
        p.addArc(center: b, radius: width / 2, startAngle: .radians(atan2(ny, nx)), endAngle: .radians(atan2(-ny, -nx)), clockwise: true)
        p.addLine(to: CGPoint(x: a.x - nx, y: a.y - ny))
        p.addArc(center: a, radius: width / 2, startAngle: .radians(atan2(-ny, -nx)), endAngle: .radians(atan2(ny, nx)), clockwise: true)
        p.closeSubpath()
        return p
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

