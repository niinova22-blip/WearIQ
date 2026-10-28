import Foundation
import ProductMeasurementParser
import Testing
@testable import WearIQ

/// Reads real store pages through the app's own pipeline (network + web view + OCR).
/// Diagnostic only: runs when TEST_RUNNER_WEARIQ_LIVE_LINKS=1 (see link-diagnostics.yml),
/// because live stores change and rate-limit.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WEARIQ_LIVE_LINKS"] == "1"))
struct LiveLinkTests {
    static let links = [
        "https://www.trendyol.com/tudors/erkek-slim-fit-dar-kesim-duz-oxford-armali-dugmeli-yaka-antrasit-spor-gomlek-p-1060983333",
        "https://www.koton.com/cepli-pamuklu-klasik-yaka-uzun-kollu-fermuarli-gabardin-gomlek-kahve-4155003-2/",
        "https://www.mavi.com/kahverengi-gomlek/p/0212083-70219",
        "https://www.boyner.com.tr/the-north-face-nf0a8g0r8k21-m-quest-jacket-lacivert-erkek-spor-mont-p-15851698",
        "https://www.amazon.com.tr/dp/B0HBZ8KJND",
        "https://www.zara.com/tr/tr/man-shirts-l737.html",
        "https://www.defacto.com.tr/erkek-gomlek",
    ]

    @Test(arguments: links)
    func readLink(_ link: String) async {
        let start = Date()
        do {
            let lookup = try await ProductDataService().product(at: URL(string: link)!)
            let i = lookup.info
            var lines = ["OK \(link)", "  name: \(i.name ?? "-") | brand: \(i.brand ?? "-") | category: \(i.category.map { "\($0)" } ?? "-") | fit: \(i.fitStyle.map { "\($0)" } ?? "-")",
                         "  sizes: \(i.availableSizes) | chart images: \(i.sizeChartImageURLs.count) | html tables: \(i.sizeChartSections.count)"]
            for (n, section) in (lookup.chart?.sections ?? []).enumerated() {
                lines.append("  table \(n) \(section.title ?? "-"): " + section.chart.sizes.map { s in
                    s.label + "{" + s.values.map { "\($0.key.rawValue)=\(Int($0.value.cm))" }.sorted().joined(separator: ",") + "}"
                }.joined(separator: " "))
            }
            lines.append(String(format: "  %.1fs", Date().timeIntervalSince(start)))
            print(lines.joined(separator: "\n"))
        } catch {
            print("FAIL \(link): \(error) (\(String(format: "%.1fs", Date().timeIntervalSince(start))))")
        }
    }
}
