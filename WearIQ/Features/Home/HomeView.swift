import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(AppContainer.self) private var container
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]
    @Query(sort: \SavedAnalysis.createdAt, order: .reverse) private var analyses: [SavedAnalysis]
    @State private var remaining = 0
    let selectTab: (AppTab) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.m) {
                heroCard
                HStack(spacing: Theme.Spacing.m) {
                    quotaTile
                    profileTile
                }
                if !analyses.isEmpty { recentCard }
            }
            .padding(Theme.Spacing.m)
        }
        .background(Theme.screenBackground)
        .safeAreaInset(edge: .bottom) { BannerAdSlot() }
        .navigationTitle("WearIQ")
        .task { await container.ads.prepare(isPremium: container.isPremium) }
        // The quota store isn't observable; refresh whenever the screen shows or a new analysis lands.
        .onAppear { remaining = container.quota.remaining() }
        .onChange(of: analyses.count) { remaining = container.quota.remaining() }
    }

    private var heroCard: some View {
        Button { selectTab(.scan) } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Image(systemName: "tshirt.fill")
                    .font(.system(size: 30, weight: .semibold))
                Text("Will it fit you?")
                    .font(.system(.title, design: .rounded, weight: .bold))
                Text("Paste a product link and see your size in seconds.")
                    .font(.callout)
                    .opacity(0.85)
                HStack {
                    Text("Check a garment").font(.headline)
                    Image(systemName: "arrow.right")
                }
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, 10)
                .background(.white.opacity(0.2), in: Capsule())
            }
            .foregroundStyle(.white)
            .padding(Theme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: Color.accentColor.opacity(0.3), radius: 20, y: 10)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: analyses.count)
    }

    private var quotaTile: some View {
        Card {
            if container.isPremium {
                Image(systemName: "crown.fill").font(.title2).foregroundStyle(.yellow)
                Text("Premium").font(.headline)
                Text("Unlimited").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("\(remaining)/\(container.quota.dailyLimit)")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .contentTransition(.numericText())
                Text("Scans left today").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var profileTile: some View {
        Button { selectTab(.profile) } label: {
            Card {
                Image(systemName: "figure.stand").font(.title2).foregroundStyle(.tint)
                if let profile = profiles.first?.profile {
                    Text("Body profile").font(.headline)
                    Text("\(profile.values.count) measurements").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Body profile").font(.headline)
                    Text("Set up").font(.footnote).foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var recentCard: some View {
        Card {
            HStack {
                Text("Recent analyses").font(.headline)
                Spacer()
                NavigationLink("See all") { ScanHistoryView() }
            }
            ForEach(analyses.prefix(3)) { saved in
                NavigationLink {
                    FitResultView(saved: saved)
                } label: {
                    ScanHistoryRow(saved: saved)
                }
                .foregroundStyle(.primary)
            }
        }
    }
}

#Preview {
    NavigationStack { HomeView(selectTab: { _ in }) }
        .environment(AppContainer.preview())
        .modelContainer(AppContainer.preview().modelContainer)
}
