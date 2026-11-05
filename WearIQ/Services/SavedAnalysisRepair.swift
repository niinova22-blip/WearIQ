import FitEngine
import Foundation
import ProductMeasurementParser
import SwiftData
import WearIQCore

/// Fixes checks saved while a product's name was misread: builds before 43 took the
/// "şort" inside "tişört" for shorts, so a T-shirt was sized on its waist and worn as
/// shorts on the avatar. The garment is rebuilt from its name and re-checked on the body
/// it was checked for.
@MainActor
enum SavedAnalysisRepair {
    @discardableResult
    static func run(_ context: ModelContext, engine: any FitAnalyzing = FitEngine()) -> Int {
        let saved = (try? context.fetch(FetchDescriptor<SavedAnalysis>())) ?? []
        guard !saved.isEmpty else { return 0 }
        let profiles = (try? context.fetch(FetchDescriptor<StoredBodyProfile>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        let preference = UserDefaults.standard.string(forKey: "fitPreference").flatMap(FitPreference.init(rawValue:)) ?? .asDesigned
        var fixed = 0
        for item in saved {
            guard let spec = item.spec,
                  let body = profiles.of(item.personID).first?.profile else { continue }
            let audience: GarmentAudience? = body.sex.map { $0 == .female ? .women : .men }
            guard let repaired = ProductSpec.repaired(spec, name: item.productName, audience: audience),
                  let specData = try? JSONEncoder().encode(repaired),
                  let analysisData = try? JSONEncoder().encode(engine.analyze(body: body, garment: repaired, preference: preference)) else { continue }
            item.specData = specData
            item.analysisData = analysisData
            fixed += 1
        }
        if fixed > 0 { try? context.save() }
        return fixed
    }
}
