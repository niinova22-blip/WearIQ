import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(AppContainer.self) private var container
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]
    let selectTab: (AppTab) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.m) {
                quotaCard
                profileCard
                Button("Scan a garment") { selectTab(.scan) }
                    .buttonStyle(.primary)
            }
            .padding(Theme.Spacing.m)
        }
        .background(Theme.screenBackground)
        .navigationTitle("WearIQ")
    }

    private var quotaCard: some View {
        Card {
            if container.isPremium {
                Label("Premium: unlimited scans", systemImage: "crown.fill")
                    .font(.headline)
            } else {
                let left = container.quota.remaining()
                Text("Scans left today")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(left) / \(container.quota.dailyLimit)")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .contentTransition(.numericText())
                Text("Free scans renew every day.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var profileCard: some View {
        Card {
            Text("Body profile")
                .font(.headline)
            if let profile = profiles.first?.profile {
                Text("\(profile.values.count) measurements saved")
                    .foregroundStyle(.secondary)
                let rough = profile.values.values.filter { $0.confidence == .low }.count
                if rough > 0 {
                    Label("\(rough) values are rough estimates. Correct them with a tape measure for better advice.",
                          systemImage: "ruler")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Button("View measurements") { selectTab(.profile) }
            } else {
                Text("No measurements yet. Scan your body or enter values with a tape measure.")
                    .foregroundStyle(.secondary)
                Button("Set up body profile") { selectTab(.profile) }
            }
        }
    }
}

#Preview {
    NavigationStack { HomeView(selectTab: { _ in }) }
        .environment(AppContainer.preview())
        .modelContainer(AppContainer.preview().modelContainer)
}
