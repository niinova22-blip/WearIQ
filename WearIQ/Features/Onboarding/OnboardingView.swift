import SwiftUI

/// Benefits + privacy pages, then the profile setup flow (height, camera, scan, review).
struct OnboardingView: View {
    @Environment(AppContainer.self) private var container
    @State private var page = 0
    @State private var showSetup = false

    private struct Page {
        let symbol: String
        let title: LocalizedStringKey
        let text: LocalizedStringKey
    }

    private let pages = [
        Page(symbol: "figure.stand", title: "Scan once",
             text: "Create your body profile one time. Every garment is checked against it afterwards."),
        Page(symbol: "ruler", title: "Know how it fits",
             text: "See how shoulders, chest, waist, sleeves and length will sit, size by size."),
        Page(symbol: "checkmark.seal", title: "Pick the right size",
             text: "Get a size recommendation with an honest confidence level, not a guess."),
        Page(symbol: "lock.shield", title: "Private by design",
             text: "Your photos are analysed on this device and deleted after measuring. No account required."),
    ]

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    VStack(spacing: Theme.Spacing.m) {
                        Image(systemName: pages[i].symbol)
                            .font(.system(size: 72, weight: .light))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text(pages[i].title)
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                        Text(pages[i].text)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(Theme.Spacing.l)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button(page == pages.count - 1 ? "Get started" : "Continue") {
                if page < pages.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    showSetup = true
                }
            }
            .buttonStyle(.primary)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.m)
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
