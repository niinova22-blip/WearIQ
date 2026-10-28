import Foundation
import Observation
import ProductMeasurementParser
import ScanQuota
import WearIQCore

/// A garment being prepared for analysis: product info from a link/barcode plus a size
/// chart from structured data, OCR or manual entry. Anything the engine needs that we
/// couldn't read is surfaced as an `Issue` for the user to fill in.
@Observable
final class GarmentDraft {
    var info: ProductInfo
    var category: GarmentCategory?
    var fitStyle: FitStyle
    var stretch: FabricStretch
    var thickness: FabricThickness = .thin
    var chartKind: SizeChartKind?
    var sizes: [SizeEntry] = []
    private(set) var chartWarnings: [ParsedSizeChart.Warning] = []

    init(info: ProductInfo = ProductInfo()) {
        self.info = info
        category = info.category
        fitStyle = info.fitStyle ?? .regular
        stretch = info.stretch ?? .none
    }

    enum Issue: Equatable {
        case missingCategory
        case missingChartKind
        case noSizes
        /// No size has the measurement the engine can't do without (chest for tops, waist for pants).
        case missingCriticalMeasurement(GarmentDimension)
    }

    var issues: [Issue] {
        var result: [Issue] = []
        if category == nil { result.append(.missingCategory) }
        if chartKind == nil { result.append(.missingChartKind) }
        if sizes.isEmpty {
            result.append(.noSizes)
        } else if let category {
            let critical = Self.criticalDimension(for: category)
            if !sizes.contains(where: { $0.values[critical] != nil }) {
                result.append(.missingCriticalMeasurement(critical))
            }
        }
        return result
    }

    static func criticalDimension(for category: GarmentCategory) -> GarmentDimension {
        category == .pants ? .waist : .chest
    }

    /// Dimensions worth asking for, in table order.
    static func dimensions(for category: GarmentCategory) -> [GarmentDimension] {
        switch category {
        case .pants: [.waist, .hip, .thigh, .inseam, .outseam]
        case .tshirt: [.chest, .shoulderWidth, .waist, .bodyLength]
        case .shirt, .jacket: [.chest, .shoulderWidth, .sleeveLength, .waist, .bodyLength]
        }
    }

    func apply(_ chart: ParsedSizeChart) {
        sizes = chart.sizes
        chartWarnings = chart.warnings
        if let kind = chart.kind { chartKind = kind }
    }

    func addSize(label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !sizes.contains(where: { $0.label == trimmed }) else { return }
        sizes.append(SizeEntry(label: trimmed, values: [:]))
    }

    func removeSize(at index: Int) {
        guard sizes.indices.contains(index) else { return }
        sizes.remove(at: index)
    }

    func setValue(_ cm: Double?, size index: Int, dimension: GarmentDimension) {
        guard sizes.indices.contains(index) else { return }
        if let cm, cm > 0 {
            sizes[index].values[dimension] = MeasuredValue(cm: cm, uncertaintyCm: 0.5, source: .manual)
        } else {
            sizes[index].values[dimension] = nil
        }
    }

    var spec: GarmentSpec? {
        guard issues.isEmpty, let category, let chartKind else { return nil }
        return GarmentSpec(category: category, fitStyle: fitStyle, stretch: stretch,
                           thickness: thickness, chartKind: chartKind, sizes: sizes)
    }

    /// Identifies the product for quota purposes. Without a link or barcode, the size
    /// chart itself identifies it, so re-reading the same screenshot stays free.
    var productKey: String {
        if let key = info.productKey { return key }
        let chart = sizes.map { size in
            size.label + ":" + size.values.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue)=\(Int($0.value.cm * 10))" }.joined(separator: ",")
        }.joined(separator: "|")
        return "chart:" + DailyScanQuotaManager.digest("\(category?.rawValue ?? "")|\(chart)")
    }
}
