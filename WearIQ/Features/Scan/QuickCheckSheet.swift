import ProductMeasurementParser
import SwiftUI
import WearIQCore

/// When a product can't be identified (clothing barcodes are mostly brand-internal),
/// two taps are enough for advice: what kind of garment, and the size on its tag.
struct QuickCheckSheet: View {
    var barcode: String?
    let onCheck: (GarmentDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var category: GarmentCategory = .shirt
    @State private var fit: FitStyle = .regular
    @State private var tagSize: String?

    private var sizes: [String] {
        category == .pants ? ["28", "29", "30", "31", "32", "33", "34", "36", "38", "40"] : ["XS", "S", "M", "L", "XL", "XXL"]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    if barcode != nil {
                        Label("This barcode isn't in any public catalogue. Most clothing barcodes are brand-internal.",
                              systemImage: "barcode")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    section("What is it?") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Theme.Spacing.s)], spacing: Theme.Spacing.s) {
                            ForEach(GarmentCategory.allCases, id: \.self) { c in
                                chip(c.title, symbol: c.symbol, selected: category == c) {
                                    category = c
                                    tagSize = nil
                                }
                            }
                        }
                    }
                    section("Fit") {
                        Picker("Fit", selection: $fit) {
                            Text("Slim").tag(FitStyle.slim)
                            Text("Regular").tag(FitStyle.regular)
                            Text("Oversize").tag(FitStyle.oversized)
                        }
                        .pickerStyle(.segmented)
                    }
                    section("Size on the tag") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: Theme.Spacing.s)], spacing: Theme.Spacing.s) {
                            ForEach(sizes, id: \.self) { s in
                                chip(s, symbol: nil, selected: tagSize == s) { tagSize = s }
                            }
                        }
                    }
                }
                .padding(Theme.Spacing.m)
            }
            .background(Theme.screenBackground)
            .navigationTitle("Quick check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Check the fit", action: check)
                    .buttonStyle(.primary)
                    .disabled(tagSize == nil)
                    .padding(Theme.Spacing.m)
                    .background(.bar)
            }
            .sensoryFeedback(.selection, trigger: tagSize)
        }
    }

    private func check() {
        var info = ProductInfo()
        info.gtin = barcode
        info.category = category
        info.fitStyle = fit
        // Compare every common size so the result shows whether the tag size is the right one.
        info.availableSizes = sizes
        let draft = GarmentDraft(info: info)
        draft.preferredLabel = tagSize
        dismiss()
        onCheck(draft)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title).font(.headline)
            content()
        }
    }

    private func chip(_ title: String, symbol: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.title3) }
                Text(title).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: symbol == nil ? 44 : 72)
            .foregroundStyle(selected ? .white : .primary)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.cardBackground))
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: selected)
    }
}

extension GarmentCategory {
    var symbol: String {
        switch self {
        case .shirt: "tshirt"
        case .tshirt: "tshirt.fill"
        case .jacket: "jacket"
        case .pants: "figure.walk"
        }
    }
}
