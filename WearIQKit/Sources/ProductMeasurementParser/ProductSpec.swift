import Foundation
import WearIQCore

/// A garment ready for the fit engine from what a product page says, with no one to ask:
/// the store's own size table when the page has one (the one for the product's fit when
/// it has several), otherwise typical measurements for the store's size labels. Used
/// where nothing can be asked of the user (the Safari extension reading a page as it's
/// browsed); the app's draft screen does the same with the user able to correct it.
public enum ProductSpec {
    public enum Source: String, Codable, Sendable {
        case store, standard
    }

    public static func make(from info: ProductInfo, fallbackAudience: GarmentAudience? = nil)
        -> (spec: GarmentSpec, source: Source)? {
        guard let category = info.category else { return nil }
        var fit = info.fitStyle ?? .regular
        var chart: ParsedSizeChart?
        var source = Source.store
        if !info.sizeChartSections.isEmpty {
            let section = SizeTableReader.best(info.sizeChartSections, fit: info.fitStyle) ?? info.sizeChartSections[0]
            chart = section.chart
            if let f = section.fitStyle { fit = f }
        }
        if chart.map({ $0.sizes.isEmpty || $0.kind == nil }) ?? true {
            let labels = info.availableSizes.isEmpty
                ? (category == .pants && info.audience != .women
                    ? ["28", "29", "30", "31", "32", "33", "34", "36", "38"] : ["XS", "S", "M", "L", "XL", "XXL"])
                : info.availableSizes
            chart = StandardSizeCharts.chart(for: labels, category: category, audience: info.audience ?? fallbackAudience,
                                             anchor: info.modelFit)
            source = .standard
        }
        guard let chart, let kind = chart.kind, !chart.sizes.isEmpty else { return nil }
        let critical: GarmentDimension = category.isBottom ? .waist : .chest
        guard chart.sizes.contains(where: { $0.values[critical] != nil }) else { return nil }
        let spec = GarmentSpec(category: category, fitStyle: fit, stretch: info.stretch ?? .none, chartKind: kind,
                               sizes: SizeOrder.sorted(chart.sizes),
                               legCut: category == .pants || category == .shorts ? info.legCut : nil)
        return (spec, source)
    }
}
