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

    public static func make(from info: ProductInfo, fallbackAudience: GarmentAudience? = nil, region: SizeRegion = .eu)
        -> (spec: GarmentSpec, source: Source)? {
        var info = info
        guard let category = info.category else { return nil }
        var fit = info.fitStyle ?? .regular
        var chart: ParsedSizeChart?
        var source = Source.store
        let audience = info.audience ?? fallbackAudience
        if !info.sizeChartSections.isEmpty {
            let section = SizeTableReader.best(info.sizeChartSections, fit: info.fitStyle, category: category,
                                               audience: audience) ?? info.sizeChartSections[0]
            chart = section.chart
            if let f = section.fitStyle { fit = f }
            // Narrower than any body its labels are for: typical measurements for its sizes.
            if StandardSizeCharts.implausiblyNarrow(section.chart, category: category, audience: audience) {
                chart = nil
                if info.availableSizes.count < 2 { info.availableSizes = section.chart.sizes.map(\.label) }
            }
        }
        if chart.map({ $0.sizes.isEmpty || $0.kind == nil }) ?? true {
            let labels = standardLabels(info, category: category, audience: audience, region: region)
            chart = StandardSizeCharts.chart(for: labels, category: category, audience: audience, anchor: info.modelFit)
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

extension ProductSpec {
    /// The size labels to read typical measurements for: the store's own list, or the
    /// sizes the user's region sells this garment in when the page names fewer than two.
    /// A single size is the variant the page opened on (Hepsiburada, Koton list only the
    /// chosen one in their data): read alone it made "S" the answer for every body.
    public static func standardLabels(_ info: ProductInfo, category: GarmentCategory, audience: GarmentAudience?,
                                      region: SizeRegion) -> [String] {
        info.availableSizes.count >= 2
            ? info.availableSizes
            : SizeSystems.ladder(for: category, audience: audience, region: region, productName: info.name)
    }

    /// A spec saved while the product's name was misread (builds before 43 took the
    /// "şort" inside "tişört" for shorts): when the name now says a top where the spec
    /// says a bottom, or the other way round, the garment rebuilt on typical measurements
    /// for the size labels it had. Nil when there's nothing to fix or no chart for them.
    public static func repaired(_ spec: GarmentSpec, name: String?, audience: GarmentAudience?) -> GarmentSpec? {
        guard let name, let category = GarmentClassifier.category(from: name),
              category.isBottom != spec.category.isBottom else { return nil }
        var info = ProductInfo()
        info.name = name
        info.category = category
        info.fitStyle = GarmentClassifier.fitStyle(from: name, category: category)
        info.legCut = GarmentClassifier.legCut(from: name)
        info.stretch = spec.stretch
        info.audience = audience
        info.availableSizes = spec.sizes.map(\.label)
        return make(from: info, fallbackAudience: audience)?.spec
    }
}
