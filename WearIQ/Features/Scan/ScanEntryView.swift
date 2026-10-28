import SwiftUI

/// The three ways to identify a garment. Each method is wired up in phase 3; until
/// then the rows explain what they will do instead of opening empty screens.
struct ScanEntryView: View {
    private struct Method: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
        let symbol: String
    }

    private let methods = [
        Method(id: "link", title: "Paste a product link",
               detail: "Reads the product name, sizes and size chart where the store publishes them.",
               symbol: "link"),
        Method(id: "barcode", title: "Scan a barcode",
               detail: "Identifies the product from its EAN/UPC code. A barcode alone has no measurements.",
               symbol: "barcode.viewfinder"),
        Method(id: "photo", title: "Read a size chart photo",
               detail: "Extracts measurements from a size chart screenshot or garment label on your device.",
               symbol: "text.viewfinder"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.m) {
                ForEach(methods) { method in
                    Card {
                        Label(method.title, systemImage: method.symbol)
                            .font(.headline)
                        Text(method.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ComingInPhase(phase: 3)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(Theme.Spacing.m)
        }
        .background(Theme.screenBackground)
        .navigationTitle("Scan a garment")
    }
}

#Preview {
    NavigationStack { ScanEntryView() }
}
