import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        if container.onboardingCompleted {
            MainTabView()
        } else {
            OnboardingView()
        }
    }
}

enum AppTab: Hashable {
    case home, scan, wardrobe, style, profile
}

struct MainTabView: View {
    @State private var selection: AppTab = .home
    @Environment(AppContainer.self) private var container
    @Query private var purchases: [PurchaseRecord]
    @Query(sort: \SavedAnalysis.createdAt, order: .reverse) private var analyses: [SavedAnalysis]

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                HomeView(selectTab: { selection = $0 })
                #if DEBUG
                    .navigationDestination(isPresented: .constant(DemoMode.opensResult)) { DemoResultView() }
                    // Its rows link on, which a constantly presented destination doesn't survive.
                    .fullScreenCover(isPresented: .constant(DemoMode.opensHistory)) { NavigationStack { ScanHistoryView() } }
                    .fullScreenCover(isPresented: .constant(DemoMode.opensAvatar)) { DemoAvatarView() }
                    .sheet(isPresented: .constant(DemoMode.opensPaywall)) { PaywallView(reason: "Style is part of Premium.") }
                #endif
            }
                .tabItem { Label("Home", systemImage: "house") }
                .tag(AppTab.home)
            NavigationStack { ScanEntryView() }
                .tabItem { Label("Scan", systemImage: "viewfinder") }
                .tag(AppTab.scan)
            NavigationStack { WardrobeView() }
                .tabItem { Label("Wardrobe", systemImage: "tshirt") }
                .tag(AppTab.wardrobe)
            NavigationStack { StyleAssistantView() }
                .tabItem { Label("Style", systemImage: "sparkles") }
                .tag(AppTab.style)
            NavigationStack { ProfileView() }
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(AppTab.profile)
        }
        .sensoryFeedback(.selection, trigger: selection)
        // A link shared from a store app opens on the scan tab.
        .onChange(of: container.pendingProductLink) { _, link in
            if link != nil { selection = .scan }
        }
        // A purchase reminder tapped: ask how it fit.
        .sheet(item: Binding(get: { purchases.first { $0.token != nil && $0.token == container.pendingPurchaseToken } },
                             set: { if $0 == nil { container.pendingPurchaseToken = nil } })) { record in
            PurchaseOutcomeSheet(record: record)
        }
        // A checked garment opened from Siri, Spotlight or visual intelligence.
        .sheet(item: Binding(get: { analyses.first { $0.productKey == container.pendingAnalysisKey } },
                             set: { if $0 == nil { container.pendingAnalysisKey = nil } })) { saved in
            NavigationStack { FitResultView(saved: saved) }
        }
        #if DEBUG
        .onAppear { if DemoMode.isActive { selection = DemoMode.initialTab } }
        #endif
    }
}

#if DEBUG
/// Opens the newest saved analysis, for the screenshot of a fit result.
private struct DemoResultView: View {
    @Query(sort: \SavedAnalysis.createdAt, order: .reverse) private var analyses: [SavedAnalysis]

    var body: some View {
        if let saved = analyses.first { FitResultView(saved: saved) }
    }
}

/// An outfit on the avatar: the jeans with the tee, as the store images show it.
private struct DemoAvatarView: View {
    @Query(sort: \SavedAnalysis.createdAt, order: .reverse) private var analyses: [SavedAnalysis]

    var body: some View {
        if let main = analyses.first(where: { $0.productKey == "demo-jeans" }) ?? analyses.first,
           let spec = main.spec, let analysis = main.analysis, let size = analysis.recommendedSize?.label {
            AvatarFitView(analysis: analysis, spec: spec, sizeLabel: size, material: main.material,
                          productName: main.productName, imageURL: main.imageURL, startingCompanion: tee)
        }
    }

    private var tee: AvatarFitView.Companion? {
        guard let t = analyses.first(where: { $0.productKey == "demo-tee" }), let spec = t.spec, let analysis = t.analysis,
              let size = analysis.recommendedSize?.label else { return nil }
        return AvatarFitView.Companion(key: t.productKey, name: t.productName ?? "", spec: spec, analysis: analysis,
                                       material: t.material, size: size)
    }
}
#endif

#Preview {
    MainTabView().environment(AppContainer.preview())
}
