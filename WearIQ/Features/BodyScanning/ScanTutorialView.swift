import SwiftUI

/// How the scan goes, shown before it in a 12-second loop: the phone is propped at
/// waist height, the person steps back, holds the front pose for the photo, hears the
/// countdown from the phone and turns once round with the arms out.
struct ScanTutorialView: View {
    private static let length = 12.0

    private enum Step: Int, CaseIterable {
        case place, stepBack, front, countdown, turn, done

        /// When each step starts, seconds into the loop.
        static let starts: [Double] = [0, 1.8, 3.6, 5.6, 7.0, 10.8]

        var caption: LocalizedStringKey {
            switch self {
            case .place: "Prop the phone upright at waist height"
            case .stepBack: "Step back about three steps"
            case .front: "Arms slightly out: the front photo"
            case .countdown: "Listen: 3, 2, 1"
            case .turn: "Arms straight out, turn once round slowly"
            case .done: "Done: your measurements are ready"
            }
        }
    }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.length)
            let step = Step.allCases.last { Step.starts[$0.rawValue] <= t } ?? .place
            let local = t - Step.starts[step.rawValue]
            VStack(spacing: 10) {
                ZStack(alignment: .bottom) {
                    room
                    phone(step: step, local: local)
                        .offset(x: -110, y: -58)
                    person(step: step, local: local, t: t)
                        .offset(x: personX(t), y: -14)
                        .scaleEffect(personScale(t), anchor: .bottom)
                    if step == .front, local > 1.2, local < 1.5 {
                        Rectangle().fill(.white.opacity(0.75)).allowsHitTesting(false)
                    }
                    if step == .done {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.green, .white)
                            .offset(y: -70)
                            .transition(.scale)
                    }
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                Text(step.caption)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .animation(.easeInOut, value: step.rawValue)
                HStack(spacing: 6) {
                    ForEach(Step.allCases, id: \.self) { s in
                        Capsule()
                            .fill(s.rawValue <= step.rawValue ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.secondary.opacity(0.25)))
                            .frame(width: s == step ? 18 : 6, height: 6)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("How the scan works: prop the phone at waist height, step back, hold the front pose, then turn once round slowly with your arms out."))
    }

    /// A room: wall, floor, a little light.
    private var room: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(red: 0.2, green: 0.22, blue: 0.3), Color(red: 0.12, green: 0.13, blue: 0.18)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [Color(red: 0.32, green: 0.28, blue: 0.26), Color(red: 0.22, green: 0.19, blue: 0.18)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 40)
        }
    }

    /// The phone on a stand at waist height; sound waves while it speaks.
    private func phone(step: Step, local: Double) -> some View {
        let placed = step != .place || local > 0.8
        return ZStack {
            Rectangle().fill(Color.gray.opacity(0.6)).frame(width: 4, height: 54).offset(y: 34)
            Image(systemName: "iphone.gen3")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white)
            if step == .countdown || step == .turn {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accentGradient)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .offset(x: 30, y: -14)
            }
            if step == .countdown {
                Text(verbatim: "\(max(1, 3 - Int(local / 0.45)))")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .offset(x: 30, y: -42)
            }
        }
        .offset(y: placed ? 0 : -120)
        .opacity(placed ? 1 : 0)
        .animation(.spring(duration: 0.6), value: placed)
    }

    /// The person: standing, the front pose, then turning with the arms out.
    private func person(step: Step, local: Double, t: Double) -> some View {
        let symbol: String = switch step {
        case .place, .stepBack: "figure.walk"
        case .front: "figure.stand"
        case .countdown, .turn, .done: "figure.arms.open"
        }
        let turnSpan = Step.starts[Step.done.rawValue] - Step.starts[Step.turn.rawValue]
        let angle = step == .turn ? local / turnSpan * 360 : 0
        return Image(systemName: symbol)
            .font(.system(size: 92, weight: .regular))
            .foregroundStyle(.white.opacity(0.92))
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
    }

    /// Next to the phone at first, then three steps back.
    private func personX(_ t: Double) -> Double {
        let from = Step.starts[Step.stepBack.rawValue], to = Step.starts[Step.front.rawValue]
        let f = min(1, max(0, (t - from) / (to - from)))
        return -40 + f * 120
    }

    private func personScale(_ t: Double) -> Double {
        let from = Step.starts[Step.stepBack.rawValue], to = Step.starts[Step.front.rawValue]
        let f = min(1, max(0, (t - from) / (to - from)))
        return 1 - 0.28 * f
    }
}

#Preview {
    ScanTutorialView().padding()
}
