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
            NavigationStack { HomeView(selectTab: { selection = $0 }) }
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
    }
}

#Preview {
    MainTabView().environment(AppContainer.preview())
}
