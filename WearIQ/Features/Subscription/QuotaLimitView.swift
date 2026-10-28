import SwiftUI

/// Shown when the free daily scans are used up. The real paywall (StoreKit 2)
/// replaces the placeholder section in phase 6.
struct QuotaLimitView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.l) {
                Image(systemName: "hourglass")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("You've used today's free scans")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Free scans renew tomorrow. Your saved analyses stay available and opening them doesn't use a scan.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Card {
                    Label("Premium: unlimited scans, no ads", systemImage: "crown.fill")
                        .font(.headline)
                    ComingInPhase(phase: 6)
                }
                Spacer()
            }
            .padding(Theme.Spacing.l)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
