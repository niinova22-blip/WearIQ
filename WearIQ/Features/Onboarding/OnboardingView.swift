import SwiftUI

/// Benefits + privacy pages, then the profile setup flow (height, camera, scan, review).
struct OnboardingView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.modelContext) private var modelContext
    @State private var page = 0
    @State private var showSetup = false

    private struct Page {
        let symbol: String
        let title: LocalizedStringKey
        let text: LocalizedStringKey
    }

    private let pages = [
        Page(symbol: "figure.stand", title: "Scan once",
             text: "One minute, once. Every garment is checked against your body."),
        Page(symbol: "ruler", title: "Know how it fits",
             text: "See it on your 3D avatar: shoulders, waist, sleeves and where the hem ends."),
        Page(symbol: "checkmark.seal", title: "Pick the right size",
             text: "A size recommendation with an honest confidence, not a guess."),
        Page(symbol: "lock.shield", title: "Private by design",
             text: "Photos are processed only on this phone and deleted right away. Nothing is sent anywhere."),
    ]

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    VStack(spacing: Theme.Spacing.l) {
                        ZStack {
                            Circle()
                                .fill(Theme.accentGradient.opacity(0.15))
                                .frame(width: 180, height: 180)
                            Circle()
                                .fill(Theme.accentGradient)
                                .frame(width: 120, height: 120)
                                .shadow(color: .pink.opacity(0.35), radius: 20, y: 10)
                            Image(systemName: pages[i].symbol)
                                .font(.system(size: 52, weight: .semibold))
                                .foregroundStyle(.white)
                                .symbolEffect(.bounce, value: page == i)
                        }
                        .accessibilityHidden(true)
                        VStack(spacing: Theme.Spacing.s) {
                            Text(pages[i].title)
                                .font(.largeTitle.bold())
                                .multilineTextAlignment(.center)
                            Text(pages[i].text)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 320)
                        }
                    }
                    .padding(Theme.Spacing.l)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button(page == pages.count - 1 ? LocalizedStringKey("Get started") : LocalizedStringKey("Continue")) {
                if page < pages.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    showSetup = true
                }
            }
            .buttonStyle(.primary)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.m)
            // A new phone: the measurements and checks backed up from the old one.
            if CloudBackup.lastBackup != nil {
                Button("Restore from iCloud") {
                    if CloudBackup.restore(into: modelContext) {
                        UserDefaults.standard.set(true, forKey: CloudBackup.enabledKey)
                        container.onboardingCompleted = true
                    }
                }
                .padding(.bottom, Theme.Spacing.m)
            }
        }
        .fullScreenCover(isPresented: $showSetup) {
            ProfileSetupFlow {
                showSetup = false
                container.onboardingCompleted = true
            }
        }
    }
}

#Preview {
    OnboardingView().environment(AppContainer.preview())
}
