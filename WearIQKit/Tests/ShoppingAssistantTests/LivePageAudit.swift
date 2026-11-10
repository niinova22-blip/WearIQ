import FitEngine
import Foundation
import ProductMeasurementParser
import Testing
@testable import ShoppingAssistant
import WearIQCore

/// Real store pages, rendered the way the app's web view renders them, through the whole
/// reading and sizing pipeline. Diagnostic only: LIVE_PAGES=dir of {url, html, text,
/// sizeGroups, guide} JSON files (made by a headless-browser script), so stores can be
/// checked from a machine that isn't geo-blocked. Prints one block per page.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIVE_PAGES"] != nil))
struct LivePageAudit {
    struct Dump: Decodable {
        var url: String
        var html: String
        var text: String?
        var sizeGroups: [SizeOptionGroup]?
        var guide: String?
    }

    struct LiveSpec: Codable {
        var body: String
        var size: String
        var name: String
        var spec: GarmentSpec
    }

    private static func m(_ cm: Double) -> MeasuredValue { MeasuredValue(cm: cm, uncertaintyCm: 1, source: .scan) }

    static let shoppers: [(String, BodyProfile)] = [
        ("K165/S", BodyProfile(values: [.height: m(165), .chest: m(86), .waist: m(68), .hip: m(94), .thigh: m(54),
                                        .shoulderWidth: m(37), .armLength: m(56), .torsoLength: m(41), .inseam: m(76),
                                        .outseam: m(101)], sex: .female)),
        ("K168/L", BodyProfile(values: [.height: m(168), .chest: m(102), .waist: m(86), .hip: m(110), .thigh: m(64),
                                        .shoulderWidth: m(39), .armLength: m(57), .torsoLength: m(42), .inseam: m(77),
                                        .outseam: m(103)], sex: .female)),
        ("E178/M", BodyProfile(values: [.height: m(178), .chest: m(97), .waist: m(84), .hip: m(98), .thigh: m(56),
                                        .shoulderWidth: m(45), .armLength: m(62), .torsoLength: m(47), .inseam: m(81),
                                        .outseam: m(107)], sex: .male)),
        ("E182/XL", BodyProfile(values: [.height: m(182), .chest: m(112), .waist: m(102), .hip: m(110), .thigh: m(63),
                                         .shoulderWidth: m(48), .armLength: m(64), .torsoLength: m(49), .inseam: m(82),
                                         .outseam: m(109)], sex: .male)),
    ]

    static func describe(_ sizes: [SizeEntry]) -> String {
        sizes.map { size -> String in
            let values: [String] = size.values.map { (key: GarmentDimension, value: MeasuredValue) -> String in
                String(key.rawValue.prefix(5)) + "=" + String(Int(value.cm))
            }
            return size.label + "{" + values.sorted().joined(separator: ",") + "}"
        }.joined(separator: " ")
    }

    @Test func audit() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LIVE_PAGES"]!)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [String] = []
        for file in files {
            guard let dump = try? JSONDecoder().decode(Dump.self, from: Data(contentsOf: file)) else {
                out.append("== \(file.lastPathComponent): unreadable"); continue
            }
            let page = ShoppingAssistant.Page(url: dump.url, html: dump.html, text: dump.text,
                                              sizeGroups: dump.sizeGroups ?? [], guide: dump.guide)
            let info = ShoppingAssistant.product(page)
            out.append("== \(file.deletingPathExtension().lastPathComponent)  \(dump.url.prefix(110))")
            out.append("  name: \(info.name ?? "-") | brand: \(info.brand ?? "-") | price: \(info.price.map { "\($0)" } ?? "-") \(info.currency ?? "")")
            out.append("  category: \(info.category.map { "\($0)" } ?? "-") | fit: \(info.fitStyle.map { "\($0)" } ?? "-") | leg: \(info.legCut.map { "\($0)" } ?? "-") | audience: \(info.audience.map { "\($0)" } ?? "-") | stretch: \(info.stretch.map { "\($0)" } ?? "-")")
            out.append("  sizes: \(info.availableSizes) (\(info.sizeSource.map { "\($0)" } ?? "-")) | groups: \((dump.sizeGroups ?? []).map { "\($0.caption.prefix(20)):\($0.labels.count)" })")
            out.append("  tables: \(info.sizeChartSections.count) | chart images: \(info.sizeChartImageURLs.count) | guide json: \(dump.guide != nil) | material: \(info.material?.prefix(60) ?? "-")")
            if let model = info.modelFit { out.append("  model: \(model)") }
            if let (spec, source) = ProductSpec.make(from: info, fallbackAudience: nil, region: .tr) {
                out.append("  chart(\(source), \(spec.chartKind)): " + Self.describe(spec.sizes))
            } else {
                out.append("  chart: NONE")
            }
            let audience = info.audience
            for (label, body) in Self.shoppers {
                if audience == .women && body.sex == .male { continue }
                if audience == .men && body.sex == .female { continue }
                let a = ShoppingAssistant.advise(page, shopper: .init(body: body, region: .tr))
                // The garment for the avatar probe (RenderProbe.liveProducts), once per page.
                if let dirPath = ProcessInfo.processInfo.environment["LIVE_SPECS"], let size = a.size,
                   let (spec, _) = ProductSpec.make(from: info, fallbackAudience: body.sex == .female ? .women : .men, region: .tr) {
                    let name = file.deletingPathExtension().lastPathComponent + "__" + label.replacingOccurrences(of: "/", with: "-")
                    let entry = LiveSpec(body: label, size: size, name: info.name ?? "", spec: spec)
                    try? JSONEncoder().encode(entry).write(to: URL(fileURLWithPath: dirPath).appendingPathComponent(name + ".json"))
                }
                out.append("  \(label): \(a.status) \(a.size ?? "")\(a.otherSize.map { "/\($0)" } ?? "") conf=\(a.confidence.map { "\($0)" } ?? "-") risk=\(a.risk.map { "\($0)" } ?? "-")\(a.fromStandardChart ? " std" : "")")
            }
        }
        let report = out.joined(separator: "\n")
        if let path = ProcessInfo.processInfo.environment["LIVE_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            print(report)
        }
    }
}
