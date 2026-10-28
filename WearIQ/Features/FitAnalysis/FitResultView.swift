import FitEngine
import OutfitRecommendationEngine
import SwiftUI
import WearIQCore

struct FitResultView: View {
    let productName: String?
    let brand: String?
    let imageURL: URL?
    let pageURL: URL?
    let analysis: FitAnalysis
    var category: GarmentCategory?
    var fitStyle: FitStyle?
    /// What the size chart was based on (store, photo, standard sizes).
    var chartNote: String?
    /// False for "insufficient data" results, which are shown but neither saved nor charged.
    let isSaved: Bool

    @State private var selectedLabel: String?
    @State private var addingToWardrobe = false
    @State private var showPaywall = false
    @Environment(AppContainer.self) private var container
    @Environment(\.openURL) private var openURL

    init(saved: SavedAnalysis) {
        self.init(productName: saved.productName, brand: saved.brand, imageURL: saved.imageURL,
                  pageURL: saved.pageURL, analysis: saved.analysis ?? FitAnalysis(recommendation: .insufficientData(missing: []), sizes: []),
                  isSaved: true, category: saved.spec?.category, fitStyle: saved.spec?.fitStyle)
    }

    init(productName: String?, brand: String?, imageURL: URL?, pageURL: URL?, analysis: FitAnalysis, isSaved: Bool,
         category: GarmentCategory? = nil, fitStyle: FitStyle? = nil, chartNote: String? = nil) {
        self.chartNote = chartNote
        self.isSaved = isSaved
        self.category = category
        self.fitStyle = fitStyle
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
        .sheet(isPresented: $addingToWardrobe) {
            WardrobeItemEditor(prefill: .init(
                name: productName, brand: brand, size: selected?.label,
                category: category.map { WardrobeCategory($0) }, fitStyle: fitStyle,
                fitScore: selected?.fitScore))
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
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

    /// Big recommended size up front, the explanation underneath.
    private var recommendationCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .center, spacing: Theme.Spacing.m) {
                if case let .size(label, _) = analysis.recommendation {
                    Text(label)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(.white)
                        .frame(width: 92, height: 92)
                        .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 16, y: 8)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(analysis.recommendation.headline)
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    if case let .size(_, confidence) = analysis.recommendation {
                        Label(confidence.title, systemImage: "gauge.with.dots.needle.67percent")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(FitExplanation.text(for: analysis))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let chartNote {
                Label(chartNote, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    private var sizePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(analysis.sizes, id: \.label) { size in
                    let isRecommended = size.label == analysis.recommendedSize?.label
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selectedLabel = size.label }
                    } label: {
                        VStack(spacing: 2) {
                            Text(size.label).font(.headline)
                            if isRecommended {
                                Image(systemName: "star.fill").font(.caption2)
                            }
                        }
                        .frame(minWidth: 52, minHeight: 48)
                        .padding(.horizontal, Theme.Spacing.s)
                        .background {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(selectedLabel == size.label ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.cardBackground))
                        }
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
            if isSaved {
                Button {
                    if container.isPremium { addingToWardrobe = true } else { showPaywall = true }
                } label: {
                    Label("Add to wardrobe", systemImage: container.isPremium ? "tshirt" : "crown.fill")
                }
                .padding(.top, Theme.Spacing.s)
            }
            if !isSaved {
                Label("Not saved and no scan used, because data was missing.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
