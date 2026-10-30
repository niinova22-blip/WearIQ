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
            // Layers, back to front: the picture's frame (which edges the body runs off), the
            // target pose, the measured levels, the live outline, the capture flash.
            Group {
                switch model.stage {
                case .turning:
                    FrameGuide(cut: model.turn.cutEdges, seen: model.turn.reading != nil)
                    TurnGuideOverlay(state: model.turn)
                case let .positioning(issue):
                    FrameGuide(cut: model.liveReading.map(StopGuide.cutEdges) ?? [], seen: model.liveReading != nil)
                    PositioningOverlay(reading: model.liveReading, good: issue == nil)
                case .countdown:
                    FrameGuide(cut: [], seen: true)
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
                    StationDial(station: station, captured: model.turn.captured, holding: model.turn.holding,
                                capturing: model.turn.capturing)
                        .frame(width: 130, height: 130)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Step \(station + 1) of \(StationScan.stationCount)")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                            .monospacedDigit()
                        Text(model.turn.retaking ? String(localized: "Second look") : StationGuide.title(station))
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
                Label("Arms straight out · 45° clockwise each time", systemImage: "figure.arms.open")
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
        case .ok where model.turn.capturing:
            Label("Measuring…", systemImage: "camera.aperture").foregroundStyle(.green)
        case .ok:
            Label("Hold still…", systemImage: "pause.circle.fill").foregroundStyle(.green)
        case .handsOutOfFrame:
            Label("Step back: hands cut off", systemImage: "arrow.down.to.line").foregroundStyle(.orange)
        case .turnFurther:
            Label("A little further", systemImage: "arrow.clockwise").foregroundStyle(.yellow)
        case .turnBack:
            Label("Turn back counter-clockwise", systemImage: "arrow.counterclockwise").foregroundStyle(.orange)
        case .openArms:
            Label("Raise your arms", systemImage: "figure.arms.open").foregroundStyle(.orange)
        case .stepBack:
            Label("Step back", systemImage: "arrow.down.to.line").foregroundStyle(.orange)
        case .comeCloser:
            Label("Come closer", systemImage: "arrow.up.to.line").foregroundStyle(.orange)
        case .moveToCentre:
            Label("Move to the middle", systemImage: "arrow.left.and.right").foregroundStyle(.orange)
        case nil:
            Label("Turn 45° and stop", systemImage: "arrow.clockwise").foregroundStyle(.yellow)
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

/// The person's own silhouette, drawn live from the segmentation as just its outline, so
/// the user sees what the scan sees (whether the arms are out, whether head and feet are
/// in the picture) without the camera image being covered.
///
/// Each row's stretches of body are joined to the overlapping stretches of the next row
/// by slanted quads, so the edge runs smoothly instead of in steps; the gaps between arms
/// and body and between the legs stay open. The pieces are merged into one region and
/// only its boundary is stroked.
private struct LiveOutline: View {
    let outline: [OutlineRow]
    let rect: CGRect
    let tint: Color

    var body: some View {
        let contour = Self.region(outline, in: rect).normalized(eoFill: false)
        ZStack {
            contour.stroke(tint.opacity(0.45), style: StrokeStyle(lineWidth: 6, lineJoin: .round)).blur(radius: 5)
            contour.stroke(tint.opacity(0.95), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .compositingGroup()
        .animation(.easeOut(duration: 0.15), value: outline)
    }

    static func region(_ outline: [OutlineRow], in rect: CGRect) -> Path {
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        func spans(_ row: OutlineRow) -> [OutlineSpan] {
            row.spans.isEmpty ? [OutlineSpan(left: row.left, right: row.right)] : row.spans
        }
        var p = Path()
        for (i, row) in outline.enumerated() {
            let next = i + 1 < outline.count ? outline[i + 1] : nil
            for span in spans(row) {
                let partners = next.map { spans($0).filter { $0.right > span.left && $0.left < span.right } } ?? []
                if let next, !partners.isEmpty {
                    for t in partners {
                        p.move(to: pt(span.left, row.y))
                        p.addLine(to: pt(span.right, row.y))
                        p.addLine(to: pt(t.right, next.y))
                        p.addLine(to: pt(t.left, next.y))
                        p.closeSubpath()
                    }
                } else {
                    // An end (top of the head, a hand, the feet): a thin cap.
                    let height = next.map { $0.y - row.y } ?? 0.004
                    p.addRect(CGRect(origin: pt(span.left, row.y),
                                     size: CGSize(width: (span.right - span.left) * rect.width, height: max(1, height * rect.height))))
                }
            }
        }
        return p
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
                    LevelLines(reading: reading, measured: state.measured, rect: rect)
                    LiveOutline(outline: reading.outline, rect: rect, tint: matched ? .silhouetteMatched : .silhouette)
                }
                // A soft flash while the stop's stills are taken.
                Rectangle()
                    .fill(.white)
                    .opacity(state.capturing ? 0.12 : 0)
                    .animation(.easeOut(duration: 0.25), value: state.capturing)
            }
        }
    }
}

/// Where chest, waist and hips are measured on the live outline: a short line across
/// each, a little wider than the body, green once that level has been measured from
/// enough sides.
private struct LevelLines: View {
    let reading: FrameReading
    let measured: Set<BodyLevel>
    let rect: CGRect

    var body: some View {
        ZStack {
            ForEach([BodyLevel.chest, .waist, .hip], id: \.self) { level in
                if let l = reading.levels[level] {
                    let done = measured.contains(level)
                    let pad = (l.right - l.left) * 0.18
                    Path { p in
                        p.move(to: point(l.left - pad, l.y, in: rect))
                        p.addLine(to: point(l.right + pad, l.y, in: rect))
                    }
                    .stroke(done ? Color.green : .white.opacity(0.7),
                            style: StrokeStyle(lineWidth: done ? 3 : 2, lineCap: .round, dash: done ? [] : [5, 5]))
                    Text(level.title)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(done ? Color.green : .white.opacity(0.85))
                        .shadow(color: .black.opacity(0.8), radius: 3)
                        .position(point(l.right + pad, l.y, in: rect))
                        .offset(x: 30)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: measured)
    }
}

/// The picture's corners as brackets, so the user sees the space they must fit in:
/// green when the whole body, hands included, is inside, and an orange bar along each
/// edge the body runs off. Fitting in the picture comes before everything else.
private struct FrameGuide: View {
    let cut: StopGuide.Edges
    let seen: Bool
    @State private var pulse = false

    var body: some View {
        GeometryReader { proxy in
            let r = cameraImageRect(in: proxy.size).insetBy(dx: 12, dy: 12)
            let inside = seen && cut.isEmpty
            ZStack {
                Self.brackets(r, length: min(r.width, r.height) * 0.12)
                    .stroke(inside ? Color.silhouetteMatched : .white.opacity(0.55),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                ForEach(Self.sides(cut, in: r), id: \.0) { _, from, to in
                    Path { p in
                        p.move(to: from)
                        p.addLine(to: to)
                    }
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .shadow(color: .orange, radius: pulse ? 12 : 4)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: cut)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever()) { pulse = true }
        }
    }

    static func brackets(_ r: CGRect, length: CGFloat) -> Path {
        var p = Path()
        for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                 (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
            p.move(to: CGPoint(x: corner.x + dx * length, y: corner.y))
            p.addLine(to: corner)
            p.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * length))
        }
        return p
    }

    static func sides(_ cut: StopGuide.Edges, in r: CGRect) -> [(Int, CGPoint, CGPoint)] {
        var out: [(Int, CGPoint, CGPoint)] = []
        if cut.contains(.top) { out.append((0, CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY))) }
        if cut.contains(.bottom) { out.append((1, CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY))) }
        if cut.contains(.left) { out.append((2, CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.maxY))) }
        if cut.contains(.right) { out.append((3, CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY))) }
        return out
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
                    LiveOutline(outline: reading.outline, rect: rect, tint: good ? .silhouetteMatched : .silhouette)
                }
            }
        }
    }
}

/// A dashed human outline showing where and how to stand: in the middle of
/// the picture at a good distance. For the front photo the arms hang slightly away from
/// the body; during the turn they are held straight out and the figure is turned
/// clockwise by 45° per stop. It turns green while the user matches it.
///
/// Built from typical body proportions in stature units: each part's half-width seen at
/// an angle is √((w·cos θ)² + (d·sin θ)²) for its front half-width w and side half-depth d.
/// The parts are joined into one outline with smooth curves, so no seams show inside it.
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
        (0.46, 0.088, 0.072), (0.50, 0.104, 0.080), (0.535, 0.103, 0.078), (0.57, 0.094, 0.070), (0.605, 0.086, 0.064),
        (0.65, 0.089, 0.066), (0.70, 0.097, 0.072), (0.745, 0.104, 0.074), (0.775, 0.112, 0.068), (0.80, 0.112, 0.062),
        (0.815, 0.092, 0.056), (0.828, 0.05, 0.046), (0.845, 0.036, 0.04), (0.87, 0.035, 0.04),
    ]
    /// One leg: (height, half-width, half-depth), centred 0.052 out from the middle.
    private static let leg: [(y: Double, w: Double, d: Double)] = [
        (0.0, 0.032, 0.07), (0.02, 0.028, 0.05), (0.045, 0.022, 0.026), (0.10, 0.03, 0.034), (0.19, 0.04, 0.046),
        (0.26, 0.034, 0.04), (0.29, 0.036, 0.042), (0.37, 0.048, 0.054), (0.44, 0.058, 0.064), (0.49, 0.062, 0.068),
    ]

    var body: some View {
        let theta: Double = switch pose {
        case let .armsOut(station): Double(station) * 45 * .pi / 180
        case .front: 0
        }
        let c = cos(theta), s = sin(theta)
        // Stand where the body fills about 45% of the picture's height, so the arms held
        // out during the turn fit across it.
        let stature = 0.45 * rect.height
        let floor = rect.minY + 0.86 * rect.height
        let mid = rect.midX
        func half(_ w: Double, _ d: Double) -> Double { ((w * c) * (w * c) + (d * s) * (d * s)).squareRoot() }
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: mid + x * stature, y: floor - y * stature) }

        // Torso and neck.
        let rows = Self.torso
        var parts = [Self.smooth(rows.map { pt(-half($0.w, $0.d), $0.y) } + rows.reversed().map { pt(half($0.w, $0.d), $0.y) })]
        // Legs: their centres come together as the body turns side-on.
        for side in [-1.0, 1.0] {
            let centre = side * 0.052 * abs(c)
            parts.append(Self.smooth(Self.leg.map { pt(centre - half($0.w, $0.d), $0.y) }
                + Self.leg.reversed().map { pt(centre + half($0.w, $0.d), $0.y) }))
        }
        // Head.
        let headW = half(0.056, 0.066) * stature, headH = 0.122 * stature
        parts.append(Path(ellipseIn: CGRect(x: mid - headW, y: floor - 0.997 * stature, width: 2 * headW, height: headH)))
        // Arms, tapering from the shoulder to the wrist, with the hand.
        let arm = 0.048 * stature, wrist = 0.03 * stature
        switch pose {
        case .front:
            // Hanging slightly away from the body, about 15° out.
            for side in [-1.0, 1.0] {
                let shoulder = pt(side * 0.105, 0.785), hand = pt(side * 0.19, 0.49)
                parts.append(Self.limb(from: shoulder, to: hand, startWidth: arm, endWidth: wrist))
                let palm = pt(side * 0.2, 0.455)
                parts.append(Path(ellipseIn: CGRect(x: palm.x - wrist * 0.6, y: palm.y - 0.04 * stature,
                                                    width: wrist * 1.2, height: 0.08 * stature)))
            }
        case .armsOut:
            // Straight out at shoulder height; seen side-on they point at the phone.
            for side in [-1.0, 1.0] {
                let reach = side * 0.44 * c
                parts.append(Self.limb(from: pt(side * 0.095 * abs(c), 0.785), to: pt(reach, 0.785), startWidth: arm, endWidth: wrist))
                let palm = pt(reach + side * 0.045 * c, 0.785)
                let hw = max(wrist * 0.5, 0.04 * stature * abs(c))
                parts.append(Path(ellipseIn: CGRect(x: palm.x - hw, y: palm.y - wrist * 0.6, width: 2 * hw, height: wrist * 1.2)))
            }
        }
        let figure = parts.dropFirst().reduce(parts[0]) { $0.union($1) }
        let color: Color = matched ? .silhouetteMatched : .white
        // Only the figure's outline, so it guides without covering the picture.
        return ZStack {
            figure.stroke(color.opacity(matched ? 0.8 : 0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .blur(radius: 0.6)
                .shadow(color: color.opacity(0.35), radius: 6)
        }
        .animation(.easeInOut(duration: 0.5), value: pose)
        .animation(.easeInOut(duration: 0.2), value: matched)
    }

    /// A closed curve through the points (Catmull–Rom, as cubic Béziers).
    private static func smooth(_ points: [CGPoint]) -> Path {
        var p = Path()
        let n = points.count
        guard n > 2 else { return p }
        p.move(to: points[0])
        for i in 0..<n {
            let p0 = points[(i - 1 + n) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
            p.addCurve(to: p2,
                       control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                       control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        p.closeSubpath()
        return p
    }

    /// A tapered bar with rounded ends between two points.
    private static func limb(from a: CGPoint, to b: CGPoint, startWidth: Double, endWidth: Double) -> Path {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max((dx * dx + dy * dy).squareRoot(), 1)
        let ux = -dy / length, uy = dx / length
        var p = Path()
        p.move(to: CGPoint(x: a.x + ux * startWidth / 2, y: a.y + uy * startWidth / 2))
        p.addLine(to: CGPoint(x: b.x + ux * endWidth / 2, y: b.y + uy * endWidth / 2))
        p.addLine(to: CGPoint(x: b.x - ux * endWidth / 2, y: b.y - uy * endWidth / 2))
        p.addLine(to: CGPoint(x: a.x - ux * startWidth / 2, y: a.y - uy * startWidth / 2))
        p.closeSubpath()
        return p
            .union(Path(ellipseIn: CGRect(x: a.x - startWidth / 2, y: a.y - startWidth / 2, width: startWidth, height: startWidth)))
            .union(Path(ellipseIn: CGRect(x: b.x - endWidth / 2, y: b.y - endWidth / 2, width: endWidth, height: endWidth)))
    }
}

/// Top view of the turn as the user sees it: the phone ahead (top), the user in the
/// middle, eight stops around; turning right goes clockwise. The arrow shows which way
/// the user's chest should point at the current stop.
private struct StationDial: View {
    let station: Int
    let captured: Set<Int>
    let holding: Bool
    var capturing = false

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
                // The arm turns clockwise 45° per stop, like the user.
                Image(systemName: "arrow.up")
                    .font(.system(size: size * 0.26, weight: .heavy))
                    .foregroundStyle(capturing ? .green : .white)
                    .rotationEffect(.degrees(Double(station) * 45))
                    .animation(.spring(duration: 0.5), value: station)
                Text("45°")
                    .font(.system(size: size * 0.11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .offset(y: size * 0.24)
                if holding || capturing {
                    Circle()
                        .trim(from: 0, to: capturing ? 1 : 0.6)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: radius * 1.45, height: radius * 1.45)
                        .animation(.easeInOut(duration: 0.5), value: capturing)
                }
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


private extension Color {
    /// Soft tints for the live silhouette: a pale blue while positioning, mint once it fits.
    static let silhouette = Color(red: 0.66, green: 0.8, blue: 1.0)
    static let silhouetteMatched = Color(red: 0.5, green: 0.92, blue: 0.68)
}
