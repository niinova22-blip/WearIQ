import StoreKit
import SwiftUI

struct PaywallView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var purchasing: Product.ID?
    var reason: LocalizedStringKey?

    private var subscriptions: SubscriptionService { container.subscriptions }

    private let features: [(String, LocalizedStringKey)] = [
        ("infinity", "Unlimited garment scans"),
        ("nosign", "No ads"),
        ("square.split.2x2", "Detailed region-by-region analysis"),
        ("arrow.left.arrow.right", "Compare several sizes"),
        ("tshirt", "Digital wardrobe"),
        ("sparkles", "Outfit suggestions and style tips"),
        ("chart.line.uptrend.xyaxis", "Measurement change tracking"),
        ("clock.arrow.circlepath", "Full fit history"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Label("WearIQ Premium", systemImage: "crown.fill")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.tint)
                        if let reason { Text(reason).foregroundStyle(.secondary) }
                    }
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        ForEach(features, id: \.0) { symbol, text in
                            Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(.tint) }
                        }
                    }
                    productButtons
                    if subscriptions.isPremium {
                        Label("Premium is active. Thank you!", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                    if let error = subscriptions.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    legal
                }
                .padding(Theme.Spacing.l)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task { if subscriptions.products.isEmpty { await subscriptions.loadProducts() } }
        }
    }

    @ViewBuilder
    private var productButtons: some View {
        if subscriptions.products.isEmpty {
            if subscriptions.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Text("Subscriptions couldn't be loaded. Check your connection and try again.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Try again") { Task { await subscriptions.loadProducts() } }
            }
        } else {
            VStack(spacing: Theme.Spacing.s) {
                ForEach(subscriptions.products) { product in
                    Button {
                        Task {
                            purchasing = product.id
                            let outcome = await subscriptions.purchase(product)
                            purchasing = nil
                            if outcome == .purchased { dismiss() }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(product.displayName).font(.headline)
                                Text(product.periodDescription).font(.subheadline).opacity(0.85)
                            }
                            Spacer()
                            if purchasing == product.id {
                                ProgressView().tint(.white)
                            } else {
                                Text(product.displayPrice).font(.headline)
                            }
                        }
                        .padding(Theme.Spacing.m)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .disabled(purchasing != nil || subscriptions.isPremium)
                }
                Text("Subscriptions renew automatically until cancelled. Cancel anytime in your App Store account settings at least 24 hours before the period ends.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var legal: some View {
        HStack(spacing: Theme.Spacing.m) {
            Button("Restore purchases") { Task { await subscriptions.restore() } }
            Spacer()
            Button("Terms") { openURL(AppLinks.terms) }
            Button("Privacy") { openURL(AppLinks.privacy) }
        }
        .font(.footnote)
    }
}

enum AppLinks {
    /// Apple's standard licence agreement, until a custom one is published.
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacy = URL(string: "https://niinova22-blip.github.io/WearIQ/privacy.html")!
}

extension Product {
    var periodDescription: String {
        guard let period = subscription?.subscriptionPeriod else { return "" }
        switch period.unit {
        case .month: return String(localized: "Billed monthly")
        case .year: return String(localized: "Billed yearly")
        case .week: return String(localized: "Billed weekly")
        case .day: return String(localized: "Billed daily")
        @unknown default: return ""
        }
    }
}
