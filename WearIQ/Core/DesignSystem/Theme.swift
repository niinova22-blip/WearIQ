import FitEngine
import SwiftUI

enum Theme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    static let cornerRadius: CGFloat = 20
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let screenBackground = Color(uiColor: .systemGroupedBackground)
}

extension FitSeverity {
    /// Green = fits, yellow = small mismatch, red = clear mismatch, grey = no data.
    /// Always shown together with text, never colour alone (accessibility).
    var color: Color {
        switch self {
        case .good: .green
        case .minor: .yellow
        case .major: .red
        case .unknown: .gray
        }
    }

    var symbol: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .minor: "exclamationmark.circle.fill"
        case .major: "xmark.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }
}

/// Large rounded card used across the app.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) { content }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

/// Honest marker for features that are planned but not built yet. Shown instead of
/// fake buttons so nothing in the UI pretends to work when it doesn't.
struct ComingInPhase: View {
    let phase: Int

    var body: some View {
        Label("Coming in phase \(phase)", systemImage: "hammer")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel(Text("Not available yet, planned for phase \(phase)"))
    }
}
