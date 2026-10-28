import FitEngine
import SwiftData
import SwiftUI
import WearIQCore

/// Compares the two most recent body profiles and shows which saved garments may now
/// fit differently. Not a health feature: no scores, targets or medical interpretation.
struct MeasurementTrackingView: View {
    @Environment(AppContainer.self) private var container
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]
    @Query(sort: \SavedAnalysis.createdAt, order: .reverse) private var analyses: [SavedAnalysis]
    @AppStorage("fitPreference") private var preference: FitPreference = .asDesigned

    var body: some View {
        Group {
            if !container.isPremium {
                PremiumFeaturePlaceholder(
                    title: "Measurement tracking",
                    detail: "Compare your scans over time and see which clothes may now fit differently.",
                    symbol: "chart.line.uptrend.xyaxis")
            } else if profiles.count < 2 {
                ContentUnavailableView("Only one measurement so far", systemImage: "ruler",
                                       description: Text("Scan again or update your measurements later to compare."))
            } else {
                comparison
            }
        }
        .navigationTitle("Measurement changes")
    }

    @ViewBuilder
    private var comparison: some View {
        if let new = profiles[0].profile, let old = profiles[1].profile {
            let changes = MeasurementComparison.compare(old, new)
            let impacts = analyses.compactMap { saved -> (SavedAnalysis, MeasurementComparison.GarmentImpact)? in
                guard let spec = saved.spec,
                      let impact = MeasurementComparison.impact(of: spec, size: saved.analysis?.recommendedSize?.label,
                                                                before: old, after: new, preference: preference) else { return nil }
                return (saved, impact)
            }
            List {
                Section {
                    ForEach(changes, id: \.dimension) { change in
                        HStack {
                            Text(change.dimension.title)
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text("\(change.before.cm.formatted(.number.precision(.fractionLength(0...1)))) → \(change.after.cm.formatted(.number.precision(.fractionLength(0...1)))) cm")
                                    .monospacedDigit()
                                Text(change.trend.title)
                                    .font(.caption)
                                    .foregroundStyle(change.trend == .withinMeasurementError ? .secondary : .primary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("\(profiles[1].createdAt.formatted(date: .abbreviated, time: .omitted)) → \(profiles[0].createdAt.formatted(date: .abbreviated, time: .omitted))")
                } footer: {
                    Text("Differences smaller than the measurement uncertainty are shown as \"within measurement error\" and are not treated as real change.")
                }

                Section("Clothes that may fit differently") {
                    if impacts.isEmpty {
                        Text("None of your saved garments are affected.").foregroundStyle(.secondary)
                    }
                    ForEach(impacts, id: \.0.productKey) { saved, impact in
                        NavigationLink {
                            FitResultView(productName: saved.productName, brand: saved.brand, imageURL: saved.imageURL,
                                          pageURL: saved.pageURL, analysis: impact.after, isSaved: false)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(saved.productName ?? String(localized: "Garment")).font(.headline)
                                ForEach(impact.changedRegions, id: \.region) { change in
                                    Text("\(change.region.title): \(change.from.title.lowercased()) → \(change.to.title.lowercased())")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                if impact.recommendationChanged {
                                    Text(impact.after.recommendation.headline).font(.subheadline)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

extension MeasurementComparison.Trend {
    var title: String {
        switch self {
        case .increased: String(localized: "Increased")
        case .decreased: String(localized: "Decreased")
        case .withinMeasurementError: String(localized: "Within measurement error")
        }
    }
}
