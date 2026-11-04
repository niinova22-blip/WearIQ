import BodyMeasurementEngine
import SwiftData
import SwiftUI
import WearIQCore

/// "Shopping for Ayşe": on the home screen while someone else's measurements are in use.
struct ActivePersonBanner: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        if let id = container.activePersonID {
            HStack {
                PersonBadge(personID: id)
                Button("Back to me") { container.activePersonID = nil }
                    .font(.subheadline)
            }
        }
    }
}

/// Orders on their way: one tap to say how they fit once they've arrived.
struct PendingPurchasesCard: View {
    @Query(sort: \PurchaseRecord.createdAt, order: .reverse) private var purchases: [PurchaseRecord]
    @State private var answering: PurchaseRecord?

    /// Asked about from two days after ordering.
    private var due: [PurchaseRecord] {
        purchases.filter { $0.isPending && $0.createdAt < Date(timeIntervalSinceNow: -2 * 24 * 3600) }
    }

    var body: some View {
        if !due.isEmpty {
            Card {
                Label("Did your order arrive?", systemImage: "shippingbox.fill").font(.headline)
                ForEach(due.prefix(3)) { record in
                    Button {
                        answering = record
                    } label: {
                        HStack {
                            Text(record.productName ?? record.brand).lineLimit(1)
                            Spacer()
                            Text(record.size).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .sheet(item: $answering) { PurchaseOutcomeSheet(record: $0) }
        }
    }
}

/// Weight in Apple Health has moved since the scan: scan again, or use estimates.
struct WeightChangeCard: View {
    @AppStorage("healthWeight") private var enabled = false
    /// The reading the user already answered, so the card doesn't come back for it.
    @AppStorage("healthWeightSeen") private var seen: Double = 0
    @Environment(AppContainer.self) private var container
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]
    @State private var change: WeightChange?
    @State private var rescanning = false

    var body: some View {
        Group {
            if let change, let profile = profiles.of(nil).first?.profile {
                Card {
                    Label(change.deltaKg > 0
                          ? String(localized: "You've gained \(Int(change.deltaKg.rounded())) kg since your scan")
                          : String(localized: "You've lost \(Int((-change.deltaKg).rounded())) kg since your scan"),
                          systemImage: "scalemass.fill")
                        .font(.headline)
                    if let waist = change.expectedShifts(for: profile)[.waist] {
                        Text("Your waist may be about \(Int(abs(waist).rounded())) cm \(waist > 0 ? String(localized: "bigger") : String(localized: "smaller")). Sizes could change.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Scan again") { rescanning = true }
                            .buttonStyle(.borderedProminent)
                        Button("Use an estimate for now") { useEstimate(change, profile) }
                            .buttonStyle(.bordered)
                    }
                    Button("Not now") { dismiss(change) }
                        .font(.footnote)
                }
                .fullScreenCover(isPresented: $rescanning) {
                    ProfileSetupFlow {
                        rescanning = false
                        dismiss(change)
                    }
                }
            }
        }
        .task(id: enabled) { await check() }
    }

    private func check() async {
        guard enabled, container.activePersonID == nil, let profile = profiles.of(nil).first?.profile,
              let reading = await HealthWeight.latest(), reading.date.timeIntervalSince1970 != seen else {
            change = nil
            return
        }
        change = WeightChange.check(profile: profile, currentKg: reading.kg, measuredAt: reading.date)
    }

    /// Girths moved by the statistics, marked as estimates (advice from them is never sure).
    private func useEstimate(_ change: WeightChange, _ profile: BodyProfile) {
        if let stored = try? StoredBodyProfile(profile: change.estimatedProfile(from: profile)) {
            modelContext.insert(stored)
            try? modelContext.save()
        }
        dismiss(change)
    }

    private func dismiss(_ change: WeightChange) {
        seen = change.measuredAt.timeIntervalSince1970
        self.change = nil
    }
}
