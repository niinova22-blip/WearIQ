import FitEngine
import ProductMeasurementParser
import SwiftUI
import WearIQCore
import WebKit

/// What to check together: a basket, wishlist or collection page to open, or product
/// links pasted at once.
struct BulkCheckRoute: Hashable, Identifiable {
    enum Source: Hashable {
        case page(URL)
        case links([URL])
    }

    let id = UUID()
    let source: Source

    /// A pasted block with several product links is checked directly; a single link to a
    /// basket or list page is opened in the in-app browser to find its products.
    static func from(_ text: String) -> BulkCheckRoute? {
        let links = ProductLinkExtractor.productLinks(inText: text)
        if links.count >= 2 { return BulkCheckRoute(source: .links(links)) }
        guard let url = ProductDataService.normalizedURL(from: text) else { return nil }
        return BulkCheckRoute(source: links.count == 1 ? .links(links) : .page(url))
    }
}

/// Opens a basket or list page (signing in if the store asks), finds the products on it
/// and checks them all.
struct BulkCheckView: View {
    let route: BulkCheckRoute
    @State private var found: [URL] = []
    @State private var checking: [URL]?

    var body: some View {
        Group {
            if let checking {
                BulkResultsView(urls: checking)
            } else if case let .page(url) = route.source {
                StoreBrowser(url: url, links: $found)
                    .ignoresSafeArea(edges: .bottom)
                    .safeAreaInset(edge: .bottom) { browserBar }
            } else if case let .links(urls) = route.source {
                BulkResultsView(urls: urls)
            }
        }
        .navigationTitle("Check a basket")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var browserBar: some View {
        VStack(spacing: Theme.Spacing.s) {
            Text(found.isEmpty
                 ? "Sign in if the store asks, and open your basket or list. Products on the page appear here."
                 : "\(found.count) products found on this page.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(found.isEmpty ? "Looking for products…" : "Check \(found.count) products") { checking = found }
                .buttonStyle(.primary)
                .disabled(found.isEmpty)
            Text("WearIQ only reads the product links on the page, never your sign-in details.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.m)
        .background(.bar)
    }
}

/// An in-app browser for a store page. It keeps the store's sign-in like Safari would,
/// and every second and a half reads which product pages the page links to.
private struct StoreBrowser: UIViewRepresentable {
    let url: URL
    @Binding var links: [URL]

    func makeCoordinator() -> Coordinator { Coordinator(links: $links) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Persistent, so a sign-in survives and the basket stays visible next time.
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = ProductDataService.userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        context.coordinator.watch(webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.task?.cancel()
    }

    @MainActor
    final class Coordinator {
        @Binding var links: [URL]
        var task: Task<Void, Never>?

        init(links: Binding<[URL]>) { _links = links }

        func watch(_ webView: WKWebView) {
            task = Task { [weak webView] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard let webView, let page = webView.url,
                          let html = try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String
                    else { continue }
                    let found = ProductLinkExtractor.productLinks(html: html, pageURL: page)
                    if found != links { links = found }
                }
            }
        }
    }
}

/// Reads and analyses each product one after another, showing results as they come.
private struct BulkResultsView: View {
    let urls: [URL]

    @Environment(AppContainer.self) private var container
    @AppStorage("fitPreference") private var preference: FitPreference = .asDesigned
    @State private var items: [Item] = []
    @State private var stopped: String?

    struct Item: Identifiable {
        enum State {
            case waiting, reading
            case analysed(SavedAnalysis)
            case problem(String)
        }

        let id = UUID()
        let url: URL
        var name: String?
        var imageURL: URL?
        var state: State = .waiting
    }

    var body: some View {
        List {
            if let stopped {
                Label(stopped, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ForEach(items) { item in
                row(item)
            }
        }
        .navigationDestination(for: SavedAnalysis.self) { FitResultView(saved: $0) }
        .task {
            guard items.isEmpty else { return }
            items = urls.map { Item(url: $0) }
            await checkAll()
        }
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        let content = HStack(spacing: Theme.Spacing.m) {
            AsyncImage(url: item.imageURL) { $0.resizable().scaledToFill() } placeholder: {
                Image(systemName: "tshirt").foregroundStyle(.secondary)
            }
            .frame(width: 56, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name ?? item.url.host ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                switch item.state {
                case .waiting:
                    Text("Waiting").font(.caption).foregroundStyle(.secondary)
                case .reading:
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading the product…") }
                        .font(.caption).foregroundStyle(.secondary)
                case let .analysed(saved):
                    if let analysis = saved.analysis {
                        Text(analysis.recommendation.headline)
                            .font(.headline)
                            .foregroundStyle(.tint)
                        Text(FitExplanation.text(for: analysis))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                case let .problem(message):
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        if case let .analysed(saved) = item.state {
            NavigationLink(value: saved) { content }
        } else {
            content
        }
    }

    private func checkAll() async {
        let service = ProductDataService()
        for index in items.indices {
            guard stopped == nil else {
                items[index].state = .problem(String(localized: "Not checked"))
                continue
            }
            items[index].state = .reading
            do {
                let lookup = try await service.product(at: items[index].url)
                items[index].name = lookup.info.name
                items[index].imageURL = lookup.info.imageURL
                let draft = GarmentDraft(info: lookup.info)
                if let chart = lookup.chart {
                    draft.apply(chart)
                } else {
                    draft.fillStandardChart(fallbackAudience: Self.profileAudience)
                }
                items[index].state = analyse(draft, index: index)
            } catch {
                items[index].state = .problem(error.localizedDescription)
            }
        }
    }

    private func analyse(_ draft: GarmentDraft, index: Int) -> Item.State {
        guard draft.issues.isEmpty else {
            return .problem(String(localized: "No size chart found; open the product to add one."))
        }
        do {
            switch try container.analysisCoordinator().run(draft, preference: preference) {
            case let .analyzed(saved):
                return .analysed(saved)
            case .insufficientData:
                return .problem(String(localized: "The size chart lacks the measurements needed."))
            case .needsBodyProfile:
                stopped = String(localized: "Scan or enter your measurements first.")
                return .problem(String(localized: "Not checked"))
            case .quotaExhausted:
                stopped = String(localized: "Today's free checks are used up. Premium checks without a limit.")
                return .problem(String(localized: "Not checked"))
            case .invalidDraft:
                return .problem(String(localized: "No size chart found; open the product to add one."))
            }
        } catch {
            return .problem(error.localizedDescription)
        }
    }

    private static var profileAudience: GarmentAudience? {
        switch BodySex(rawValue: UserDefaults.standard.string(forKey: "bodySex") ?? "") {
        case .male: .men
        case .female: .women
        case nil: nil
        }
    }
}
