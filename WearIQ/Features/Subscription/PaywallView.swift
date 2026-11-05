import StoreKit
import SwiftUI

struct PaywallView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var purchasing: Product.ID?
    /// Whether this Apple Account can still have the yearly plan's free week (once per account).
    @State private var trialEligible = false
    var reason: LocalizedStringKey?

    private var subscriptions: SubscriptionService { container.subscriptions }

    private let features: [(String, LocalizedStringKey)] = [
        ("infinity", "Unlimited garment checks"),
        ("nosign", "No ads"),
        ("sparkles", "The Style tab: your colours, cuts and outfits"),
        ("figure.stand", "Size advice for the way you like to wear clothes"),
        ("tshirt", "Digital wardrobe"),
        ("person.2", "Shop for your partner, kids or a gift"),
        ("chart.line.uptrend.xyaxis", "Measurement change tracking"),
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
            .task {
                if subscriptions.products.isEmpty { await subscriptions.loadProducts() }
                if let yearly = subscriptions.products.first(where: { $0.subscription?.subscriptionPeriod.unit == .year }) {
                    trialEligible = await yearly.subscription?.isEligibleForIntroOffer ?? false
                }
            }
        }
    }

    @ViewBuilder
    private var productButtons: some View {
        if subscriptions.products.isEmpty, Self.demoPlans {
            // Screenshot mode: the plans as App Store Connect sells them.
            VStack(spacing: Theme.Spacing.s) {
                demoPlan(String(localized: "Premium Yearly"), "Free for 7 days, then $39.99 a year", "$39.99", saving: 52, yearly: true)
                demoPlan(String(localized: "Premium Monthly"), "Billed monthly", "$6.99", saving: nil, yearly: false)
            }
        } else if subscriptions.products.isEmpty {
            if subscriptions.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Text("Subscriptions couldn't be loaded. Check your connection and try again.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Try again") { Task { await subscriptions.loadProducts() } }
            }
        } else {
            VStack(spacing: Theme.Spacing.s) {
                // Yearly first: the better deal, and the one with the free trial.
                ForEach(subscriptions.products.sorted { ($0.subscription?.subscriptionPeriod.unit == .year ? 0 : 1) < ($1.subscription?.subscriptionPeriod.unit == .year ? 0 : 1) }) { product in
                    let yearly = product.subscription?.subscriptionPeriod.unit == .year
                    Button {
                        Task {
                            purchasing = product.id
                            let outcome = await subscriptions.purchase(product)
                            purchasing = nil
                            if outcome == .purchased { dismiss() }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(product.displayName).font(.headline)
                                    if yearly, let saving = savingPercent(yearly: product) {
                                        Text("Save \(saving)%")
                                            .font(.caption.weight(.bold))
                                            .padding(.horizontal, 7).padding(.vertical, 2)
                                            .background(Theme.gold, in: Capsule())
                                            .foregroundStyle(.black)
                                    }
                                }
                                if yearly, trialEligible, product.subscription?.introductoryOffer?.paymentMode == .freeTrial {
                                    Text("Free for 7 days, then \(product.displayPrice) a year").font(.subheadline).opacity(0.9)
                                } else if yearly {
                                    Text("\(product.priceFormatStyle.format(product.price / 12)) a month, billed yearly")
                                        .font(.subheadline).opacity(0.9)
                                } else {
                                    Text(product.periodDescription).font(.subheadline).opacity(0.85)
                                }
                            }
                            Spacer()
                            if purchasing == product.id {
                                ProgressView().tint(yearly ? .white : .accentColor)
                            } else {
                                Text(product.displayPrice).font(.headline)
                            }
                        }
                        .padding(Theme.Spacing.m)
                        .foregroundStyle(yearly ? Color.white : Color.primary)
                        .background {
                            if yearly {
                                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.accentGradient)
                            } else {
                                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5)
                            }
                        }
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

extension PaywallView {
    static var demoPlans: Bool {
        #if DEBUG
        DemoMode.opensPaywall
        #else
        false
        #endif
    }

    func demoPlan(_ name: String, _ detail: LocalizedStringKey, _ price: String, saving: Int?, yearly: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.headline)
                    if let saving {
                        Text("Save \(saving)%")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.gold, in: Capsule())
                            .foregroundStyle(.black)
                    }
                }
                Text(detail).font(.subheadline).opacity(0.9)
            }
            Spacer()
            Text(price).font(.headline)
        }
        .padding(Theme.Spacing.m)
        .foregroundStyle(yearly ? Color.white : Color.primary)
        .background {
            if yearly {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.accentGradient)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
    }

    /// How much the yearly plan saves against twelve months of the monthly one.
    func savingPercent(yearly: Product) -> Int? {
        guard let monthly = subscriptions.products.first(where: { $0.subscription?.subscriptionPeriod.unit == .month }) else { return nil }
        let twelve = monthly.price * 12
        guard twelve > 0 else { return nil }
        let saving = (1 - NSDecimalNumber(decimal: yearly.price / twelve).doubleValue) * 100
        return saving >= 5 ? Int(saving.rounded()) : nil
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
