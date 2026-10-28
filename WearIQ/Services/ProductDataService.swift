import Foundation
import ProductMeasurementParser

protocol ProductDataServicing {
    func product(at url: URL) async throws -> ProductInfo
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

/// Fetches a product page and reads the structured data the store publishes.
/// No scraping of private APIs, no login, no bypassing bot protection: if a store
/// doesn't publish data, the user is offered the size chart screenshot route instead.
struct ProductDataService: ProductDataServicing {
    var session: URLSession = .shared
    var parser = ProductPageParser()

    static func normalizedURL(from input: String) -> URL? {
        // Share sheets often paste "Product name https://…"; take the first link.
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(input.startIndex..., in: input)
        guard let url = detector?.firstMatch(in: input, range: range)?.url,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }

    func product(at url: URL) async throws -> ProductInfo {
        var request = URLRequest(url: url, timeoutInterval: 15)
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
        let html = String(decoding: data, as: UTF8.self)
        let info = parser.parse(html: html, pageURL: response.url ?? url)
        if info.isEmpty { throw ProductDataError.notAProductPage }
        return info
    }
}
