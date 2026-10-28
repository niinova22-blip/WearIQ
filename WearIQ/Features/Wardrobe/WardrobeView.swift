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
    @Environment(AppContainer.self) private var container
    @State private var showPaywall = false
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
            VStack(spacing: Theme.Spacing.s) {
                if !container.isPremium {
                    Button {
                        showPaywall = true
                    } label: {
                        Label("Unlock with Premium", systemImage: "crown.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                ComingInPhase(phase: phase)
            }
        }
        .background(Theme.screenBackground)
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }
}

#Preview {
    NavigationStack { WardrobeView() }
        .environment(AppContainer.preview())
}
