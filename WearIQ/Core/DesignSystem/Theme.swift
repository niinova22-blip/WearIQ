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
    /// Brand gradient for primary actions and highlights.
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.42, green: 0.40, blue: 0.98), Color(red: 0.30, green: 0.24, blue: 0.80)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
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

/// Large rounded card used across the app: soft shadow in light mode, hairline edge in dark.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) { content }
            .padding(Theme.Spacing.m + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(scheme == .dark ? 0.07 : 0), lineWidth: 1)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 14, y: 6)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(.white)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isEnabled ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.gray.opacity(0.45)))
            }
            .shadow(color: Color.accentColor.opacity(isEnabled ? 0.35 : 0), radius: 14, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}
