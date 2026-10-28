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
        "https://www.zara.com/tr/tr/yun-karisimli-regular-fit-ceket-p08281765.html?v1=557405763&v2=1885841",
        "https://www.defacto.com.tr/erkek-gomlek",
        "https://www2.hm.com/tr_tr/productpage.1358896001.html",
        "https://www.hepsiburada.com/u-s-polo-assn-erkek-beyaz-uzun-kollu-basic-gomlek-50324708-vr013-p-HBCV0000EJ9603",
        "https://www.lcw.com/regular-fit-erkek-gomlek-indigo-o-5509776",
        "https://www.massimodutti.com/tr/yuksek-bel-genis-paca-jean-l05040840",
        "https://www.bershka.com/tr/oversize-kap%C3%BC%C5%9Fonlu-k%C3%BCrk-sweatshirt-c0p240147191.html",
        "https://www.nike.com/tr/t/miler-dri-fit-uv-korumali-uzun-kollu-kislik-erkek-kosu-ustu-oAsVnGBv/IO1233-372",
        "https://www.amazon.com.tr/dp/B0776X8B3X",
        "https://www.beymen.com/tr/p_etro-lacivert-yun-dis-gomlek_2058378",
        "https://www.beymen.com/tr/p_moncler-siyah-dis-gomlek_2046383",
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

    /// What the rendered page offers as size guide controls (to tune the button matching).
    @Test(arguments: [links[5]] + Array(links.dropFirst(7)))
    func sizeControls(_ link: String) async {
        let page = await WebPageLoader.load(URL(string: link)!, timeout: 12) { _ in false }
        var lines = ["CONTROLS \(link)", "  opened: \(page?.sizeGuideControls ?? -1) snapshot: \(page?.snapshot != nil)"]
        lines += (page?.sizeRelatedControls ?? []).map { "  " + $0 }
        let text = page?.text ?? ""
        if let r = text.range(of: "ÜRÜN BOYUTLARI", options: .caseInsensitive) ?? text.range(of: "beden", options: .caseInsensitive) {
            lines.append("  TEXT: " + text[r.lowerBound...].prefix(400).replacingOccurrences(of: "\n", with: " | "))
        }
        print(lines.joined(separator: "\n"))
    }
}
