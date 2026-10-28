import Foundation
import ProductMeasurementParser
import UIKit
import WearIQCore

/// A product page plus its size chart, when the store links one as an image.
struct ProductLookup {
    var info: ProductInfo
    var chart: SizeChartScan?
}

protocol ProductDataServicing {
    func product(at url: URL) async throws -> ProductLookup
}

enum ProductDataError: LocalizedError, Equatable {
    case invalidURL
    case blocked(statusCode: Int)
    case notAProductPage
    case offline

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            String(localized: "That doesn't look like a product link.")
        case .blocked:
            String(localized: "This store doesn't allow its product pages to be read automatically.")
        case .notAProductPage:
            String(localized: "No product information was found on this page.")
        case .offline:
            String(localized: "You appear to be offline.")
        }
    }
}

/// Fetches a product page and reads the structured data the store publishes, plus the
/// size chart image the page links to (read on-device with OCR).
/// No private APIs, no login, no bypassing bot protection: if a store doesn't publish
/// data, the user is offered the size chart screenshot route instead.
struct ProductDataService: ProductDataServicing {
    var session: URLSession = .shared
    var parser = ProductPageParser()
    var chartReader = OCRService()

    /// Stores serve their regular mobile page to a mobile browser; some serve an empty
    /// shell or an error to unknown clients.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private static let maxChartBytes = 8_000_000

    static func normalizedURL(from input: String) -> URL? {
        // Share sheets often paste "Product name https://…"; take the first link.
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(input.startIndex..., in: input)
        guard let url = detector?.firstMatch(in: input, range: range)?.url,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }

    func product(at url: URL) async throws -> ProductLookup {
        var info: ProductInfo?
        var directError: Error?
        var renderedPage: WebPageLoader.Page?
        do {
            info = try await fetchDirect(url)
        } catch ProductDataError.offline {
            throw ProductDataError.offline
        } catch {
            directError = error
        }

        // Many stores render sizes and charts with JavaScript, or answer plain HTTP
        // clients with a browser check. Load those like Safari does.
        if info.map(Self.lacksSizeData) ?? true {
            let page = await WebPageLoader.load(url) { page in
                let info = parser.parse(html: page.html, pageURL: page.url)
                if !info.sizeChartSections.isEmpty || !info.sizeChartImageURLs.isEmpty { return true }
                // Product found but no size guide button after a few seconds: nothing more will come.
                return !info.isEmpty && page.sizeGuideControls == 0 && page.elapsed > 8
            }
            if let page {
                var rendered = parser.parse(html: page.html, pageURL: page.url)
                if rendered.modelFit == nil { rendered.modelFit = ModelFitParser.parse(page.text) }
                if !rendered.isEmpty { info = info.map { Self.merge($0, rendered) } ?? rendered }
                renderedPage = page
            }
        }

        guard let info else { throw directError ?? ProductDataError.notAProductPage }
        if let chart = await readChart(info) { return ProductLookup(info: info, chart: chart) }
        return ProductLookup(info: info, chart: await readRenderedGuide(renderedPage, fit: info.fitStyle))
    }

    /// Last resorts for size guides that aren't tables or linked images: the page's
    /// visible text, then OCR of a snapshot of the opened guide.
    private func readRenderedGuide(_ page: WebPageLoader.Page?, fit: FitStyle?) async -> SizeChartScan? {
        guard let page else { return nil }
        let text = page.text.replacingOccurrences(of: "\t", with: "  ")
        let chart = SizeChartParser().parse(text)
        if chart.sizes.count >= 2 {
            let section = SizeChartSection(title: nil, fitStyle: nil, chart: chart)
            return SizeChartScan(sections: [section], chosen: section)
        }
        if let snapshot = page.snapshot {
            return try? await chartReader.readSections(from: snapshot, fit: fit)
        }
        return nil
    }

    private func fetchDirect(_ url: URL) async throws -> ProductInfo {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue(Locale.preferredLanguages.prefix(2).joined(separator: ","), forHTTPHeaderField: "Accept-Language")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw ProductDataError.offline
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProductDataError.blocked(statusCode: http.statusCode)
        }
        let info = parser.parse(html: String(decoding: data, as: UTF8.self), pageURL: response.url ?? url)
        if info.isEmpty { throw ProductDataError.notAProductPage }
        return info
    }

    /// No size chart yet: the rendered page may have one behind a button.
    static func lacksSizeData(_ info: ProductInfo) -> Bool {
        info.isEmpty || (info.sizeChartSections.isEmpty && info.sizeChartImageURLs.isEmpty)
    }

    /// Fills what the plain fetch missed from the rendered page.
    static func merge(_ a: ProductInfo, _ b: ProductInfo) -> ProductInfo {
        var m = a
        m.name = a.name ?? b.name
        m.brand = a.brand ?? b.brand
        m.imageURL = a.imageURL ?? b.imageURL
        m.gtin = a.gtin ?? b.gtin
        m.sku = a.sku ?? b.sku
        m.categoryText = a.categoryText ?? b.categoryText
        m.material = a.material ?? b.material
        if a.availableSizes.isEmpty { m.availableSizes = b.availableSizes }
        if a.sizeChartImageURLs.isEmpty { m.sizeChartImageURLs = b.sizeChartImageURLs }
        if a.sizeChartSections.isEmpty { m.sizeChartSections = b.sizeChartSections }
        m.category = a.category ?? b.category
        m.fitStyle = a.fitStyle ?? b.fitStyle
        m.stretch = a.stretch ?? b.stretch
        m.audience = a.audience ?? b.audience
        m.modelFit = a.modelFit ?? b.modelFit
        return m
    }

    /// Tries the linked chart images in page order; a chart that can't be read is not an
    /// error, the user can still add one by hand.
    private func readChart(_ info: ProductInfo) async -> SizeChartScan? {
        if !info.sizeChartSections.isEmpty {
            return SizeChartScan(sections: info.sizeChartSections,
                                 chosen: SizeTableReader.best(info.sizeChartSections, fit: info.fitStyle))
        }
        for imageURL in info.sizeChartImageURLs.prefix(2) {
            var request = URLRequest(url: imageURL, timeoutInterval: 15)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  data.count <= Self.maxChartBytes,
                  let image = UIImage(data: data),
                  let scan = try? await chartReader.readSections(from: image, fit: info.fitStyle) else { continue }
            return scan
        }
        return nil
    }
}
