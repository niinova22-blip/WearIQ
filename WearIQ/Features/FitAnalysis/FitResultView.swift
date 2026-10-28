import FitEngine
import SwiftUI
import WearIQCore

struct FitResultView: View {
    let productName: String?
    let brand: String?
    let imageURL: URL?
    let pageURL: URL?
    let analysis: FitAnalysis
    /// False for "insufficient data" results, which are shown but neither saved nor charged.
    let isSaved: Bool

    @State private var selectedLabel: String?
    @Environment(\.openURL) private var openURL

    init(saved: SavedAnalysis) {
        self.init(productName: saved.productName, brand: saved.brand, imageURL: saved.imageURL,
                  pageURL: saved.pageURL, analysis: saved.analysis ?? FitAnalysis(recommendation: .insufficientData(missing: []), sizes: []),
                  isSaved: true)
    }

    init(productName: String?, brand: String?, imageURL: URL?, pageURL: URL?, analysis: FitAnalysis, isSaved: Bool) {
        self.isSaved = isSaved
        self.productName = productName
        self.brand = brand
        self.imageURL = imageURL
        self.pageURL = pageURL
        self.analysis = analysis
        _selectedLabel = State(initialValue: analysis.recommendedSize?.label ?? analysis.ranked.first?.label ?? analysis.sizes.first?.label)
    }

    private var selected: SizeFit? {
        analysis.sizes.first { $0.label == selectedLabel }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.m) {
                header
                recommendationCard
                if analysis.sizes.count > 1 { sizePicker }
                if let selected { regionsCard(selected) }
                actions
            }
            .padding(Theme.Spacing.m)
        }
        .background(Theme.screenBackground)
        .navigationTitle("Fit analysis")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.m) {
            AsyncImage(url: imageURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "tshirt").font(.largeTitle).foregroundStyle(.secondary)
            }
            .frame(width: 88, height: 110)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if let brand { Text(brand).font(.subheadline).foregroundStyle(.secondary) }
                Text(productName ?? String(localized: "Garment")).font(.headline)
            }
            Spacer()
        }
    }

    private var recommendationCard: some View {
        Card {
            Text(analysis.recommendation.headline)
                .font(.title2.bold())
            if case let .size(_, confidence) = analysis.recommendation {
                Label(confidence.title, systemImage: "gauge.medium")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(FitExplanation.text(for: analysis))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sizePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(analysis.sizes, id: \.label) { size in
                    let isRecommended = size.label == analysis.recommendedSize?.label
                    Button {
                        withAnimation(.snappy) { selectedLabel = size.label }
                    } label: {
                        VStack(spacing: 2) {
                            Text(size.label).font(.headline)
                            if isRecommended {
                                Image(systemName: "star.fill").font(.caption2)
                            }
                        }
                        .frame(minWidth: 52, minHeight: 48)
                        .padding(.horizontal, Theme.Spacing.s)
                        .background(selectedLabel == size.label ? Color.accentColor : Theme.cardBackground,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(selectedLabel == size.label ? .white : .primary)
                    }
                    .accessibilityLabel(isRecommended ? Text("Size \(size.label), recommended") : Text("Size \(size.label)"))
                    .accessibilityAddTraits(selectedLabel == size.label ? .isSelected : [])
                }
            }
        }
    }

    private func regionsCard(_ size: SizeFit) -> some View {
        Card {
            Text("Size \(size.label), region by region").font(.headline)
            ForEach(size.regions, id: \.region) { region in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: region.severity.symbol)
                        .foregroundStyle(region.severity.color)
                        .accessibilityHidden(true)
                    Text(region.region.title)
                    Spacer()
                    Text(region.detailText)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .font(.subheadline)
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: Theme.Spacing.s) {
            if let pageURL {
                Button("Open product page") { openURL(pageURL) }
                    .buttonStyle(.primary)
            }
            HStack {
                Label("Add to wardrobe", systemImage: "tshirt")
                    .foregroundStyle(.secondary)
                Spacer()
                ComingInPhase(phase: 7)
            }
            .padding(.top, Theme.Spacing.s)
            Label(isSaved ? LocalizedStringKey("Analysis saved to your history.") : LocalizedStringKey("Not saved and no scan used, because data was missing."),
                  systemImage: isSaved ? "checkmark" : "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
