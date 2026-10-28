import SwiftUI

struct WardrobeView: View {
    var body: some View {
        PremiumFeaturePlaceholder(
            title: "Digital wardrobe",
            detail: "Keep your clothes with category, colour, size, fit, season and photo, and filter them anytime.",
            symbol: "tshirt",
            phase: 7)
        .navigationTitle("Wardrobe")
    }
}

struct StyleAssistantView: View {
    var body: some View {
        PremiumFeaturePlaceholder(
            title: "Style assistant",
            detail: "Outfit suggestions from your own wardrobe for daily, work, formal, sport and evening occasions.",
            symbol: "sparkles",
            phase: 7)
        .navigationTitle("Style")
    }
}

struct PremiumFeaturePlaceholder: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let symbol: String
    let phase: Int

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        } actions: {
            HStack {
                Label("Premium", systemImage: "crown.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                ComingInPhase(phase: phase)
            }
        }
        .background(Theme.screenBackground)
    }
}

#Preview {
    NavigationStack { WardrobeView() }
}
