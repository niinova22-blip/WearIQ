import FitEngine
import SwiftData
import SwiftUI

/// Saved analyses. Opening one never uses a scan.
struct ScanHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedAnalysis.createdAt, order: .reverse) private var analyses: [SavedAnalysis]

    var body: some View {
        List {
            ForEach(analyses) { saved in
                NavigationLink {
                    FitResultView(saved: saved)
                } label: {
                    ScanHistoryRow(saved: saved)
                }
            }
            .onDelete { offsets in
                offsets.map { analyses[$0] }.forEach(modelContext.delete)
                try? modelContext.save()
            }
        }
        .overlay {
            if analyses.isEmpty {
                ContentUnavailableView("No analyses yet", systemImage: "clock",
                                       description: Text("Garments you analyse are saved here."))
            }
        }
        .safeAreaInset(edge: .bottom) { BannerAdSlot() }
        .navigationTitle("History")
    }
}

struct ScanHistoryRow: View {
    let saved: SavedAnalysis

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            AsyncImage(url: saved.imageURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "tshirt").foregroundStyle(.secondary)
            }
            .frame(width: 48, height: 60)
            .background(Theme.screenBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(saved.productName ?? String(localized: "Garment")).font(.headline).lineLimit(1)
                if let brand = saved.brand {
                    Text(brand).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(saved.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let recommendation = saved.analysis?.recommendation {
                Text(recommendation.shortLabel)
                    .font(.headline)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension SizeRecommendation {
    var shortLabel: String {
        switch self {
        case let .size(label, _): label
        case let .between(a, b): "\(a)/\(b)"
        case .insufficientData: "?"
        }
    }
}
