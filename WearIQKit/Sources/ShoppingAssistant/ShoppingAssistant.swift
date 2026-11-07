import FitEngine
import Foundation
import ProductMeasurementParser
import WearIQCore

/// The smart shopping memory's reasoning, shared by the Safari extension (which reads a
/// product page as the user browses) and the app (which files what the extension saw).
///
/// A page arrives as the parts that matter, gathered by the extension's content script:
/// the structured data and meta tags, any size tables, the composition and model lines,
/// and the size buttons. From them: the product, a size chart (the store's, or typical
/// measurements for its size labels), the size for the user's body, how sure it is, the
/// return risk, and the size for the user's own style.
public enum ShoppingAssistant {
    /// What the content script sends.
    public struct Page: Codable, Sendable, Equatable {
        public var url: String
        public var title: String?
        /// A small page: structured data, meta tags and size tables.
        public var html: String
        /// Visible text lines about the fabric and the model.
        public var text: String?
        /// Size labels offered on the page (its size buttons).
        public var sizes: [String]?
        /// The visible size selectors, each with its caption (newer extension versions).
        public var sizeGroups: [SizeOptionGroup]?
        /// The store's size guide data, for stores that load it on request (Zara's
        /// size-measure-guide JSON).
        public var guide: String?

        public init(url: String, title: String? = nil, html: String, text: String? = nil, sizes: [String]? = nil,
                    sizeGroups: [SizeOptionGroup]? = nil, guide: String? = nil) {
            self.url = url; self.title = title; self.html = html; self.text = text; self.sizes = sizes
            self.sizeGroups = sizeGroups; self.guide = guide
        }
    }

    /// The user's body and style, as the app leaves them for the extension.
    public struct Shopper: Codable, Sendable, Equatable {
        public var body: BodyProfile
        public var style: StyleLearning.Style?
        /// The size system the user shops in, for stores that list no sizes.
        public var region: SizeRegion?

        public init(body: BodyProfile, style: StyleLearning.Style? = nil, region: SizeRegion? = nil) {
            self.body = body; self.style = style; self.region = region
        }
    }

    public struct Advice: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable {
            /// A size was found.
            case sized
            /// Between two sizes.
            case between
            /// A garment, but no size could be worked out (no chart, no sizes).
            case noChart
            /// Measurements needed first.
            case noBody
            /// Not a garment page.
            case notGarment
        }

        public var status: Status
        public var name: String?
        public var brand: String?
        public var category: GarmentCategory?
        public var size: String?
        public var otherSize: String?
        public var confidence: ConfidenceLevel?
        public var risk: ReturnRisk.Level?
        public var nonReturnable: Bool = false
        public var styleSize: String?
        public var fromStandardChart: Bool = false
        public var price: Double?
        public var currency: String?
    }

    /// The product as read from the page.
    public static func product(_ page: Page) -> ProductInfo {
        var info = ProductPageParser().parse(html: page.html, pageURL: URL(string: page.url))
        if info.name == nil { info.name = page.title }
        if info.category == nil { info.category = GarmentClassifier.category(from: [info.name, info.categoryText, page.title].compactMap { $0 }.joined(separator: " ")) }
        if info.fitStyle == nil, let name = info.name { info.fitStyle = GarmentClassifier.fitStyle(from: name) }
        if info.legCut == nil, let name = info.name { info.legCut = GarmentClassifier.legCut(from: name) }
        if info.audience == nil { info.audience = GarmentClassifier.audience(in: [page.title]) }
        // The visible size selectors beat sizes found loose in script data; the older
        // flat list is a last resort.
        let shown = SizeOptions.labels(from: page.sizeGroups ?? [], category: info.category)
        if !shown.isEmpty, info.sizeSource.map({ $0 > .pageButtons }) ?? true {
            info.availableSizes = shown
            info.sizeSource = .pageButtons
        } else if info.availableSizes.isEmpty, page.sizeGroups == nil, let sizes = page.sizes {
            info.availableSizes = sizes
        }
        if let text = page.text {
            if info.material == nil { info.material = FabricAdvice.compositionText(in: text) }
            if info.modelFit == nil { info.modelFit = ModelFitParser.parse(text, audience: info.audience, category: info.category) }
        }
        if info.stretch == nil, let material = info.material { info.stretch = GarmentClassifier.stretch(fromComposition: material) }
        if let guide = page.guide, let chart = InditexSizeGuide.chart(from: Data(guide.utf8), category: info.category) {
            info.sizeChartSections = [SizeChartSection(title: nil, fitStyle: nil, chart: chart)]
        }
        return info
    }

    public static func advise(_ page: Page, shopper: Shopper?) -> Advice {
        let info = product(page)
        var advice = Advice(status: .notGarment, name: info.name, brand: info.brand, category: info.category,
                            price: info.price, currency: info.currency)
        guard info.category != nil else { return advice }
        guard let shopper else { advice.status = .noBody; return advice }
        let audience: GarmentAudience? = shopper.body.sex.map { $0 == .female ? .women : .men }
        guard let (spec, source) = ProductSpec.make(from: info, fallbackAudience: audience, region: shopper.region ?? .eu) else {
            advice.status = .noChart
            return advice
        }
        advice.fromStandardChart = source == .standard
        let analysis = FitEngine().analyze(body: shopper.body, garment: spec)
        switch analysis.recommendation {
        case let .size(label, confidence):
            advice.status = .sized
            advice.size = label
            advice.confidence = confidence
        case let .between(smaller, larger):
            advice.status = .between
            advice.size = smaller
            advice.otherSize = larger
        case .insufficientData:
            advice.status = .noChart
            return advice
        }
        let risk = ReturnRisk.assess(analysis, category: spec.category, productName: info.name)
        advice.risk = source == .standard ? max(risk.level, .medium) : risk.level
        advice.nonReturnable = risk.nonReturnable
        if let style = shopper.style {
            advice.styleSize = StyleLearning.sizeForStyle(style, spec: spec, body: shopper.body, analysis: analysis)?.size
        }
        return advice
    }
}
