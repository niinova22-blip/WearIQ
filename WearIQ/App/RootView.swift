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

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                HomeView(selectTab: { selection = $0 })
                #if DEBUG
                    .navigationDestination(isPresented: .constant(DemoMode.opensResult)) { DemoResultView() }
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
#endif

#Preview {
    MainTabView().environment(AppContainer.preview())
}
