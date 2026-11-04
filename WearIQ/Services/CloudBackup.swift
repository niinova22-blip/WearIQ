import FitEngine
import Foundation
import SwiftData
import WearIQCore

/// An optional backup of the user's numbers in their own iCloud (key-value storage), so
/// a new phone starts where the old one left off: body profiles (theirs and the people
/// they shop for), checks, purchases and brand sizes, followed products, wardrobe items
/// without photos, and the settings that shape advice. No photo is ever in it; scans are
/// never uploaded. Off until the user turns it on; restoring is offered on a phone with
/// no data of its own.
@MainActor
enum CloudBackup {
    static let enabledKey = "iCloudBackup"
    private static let key = "backup.v1"
    /// iCloud key-value storage holds 1 MB in all.
    private static let budget = 900_000

    struct Payload: Codable {
        struct PersonItem: Codable { var id: UUID; var name: String; var createdAt: Date; var relation: String }
        struct ProfileItem: Codable { var createdAt: Date; var data: Data; var personID: UUID? }
        struct AnalysisItem: Codable {
            var productKey: String, createdAt: Date, productName: String?, brand: String?
            var image: String?, page: String?, spec: Data, analysis: Data, material: String?, personID: UUID?
        }
        struct PurchaseItem: Codable {
            var createdAt: Date, brand: String, productName: String?, category: String?, size: String, feel: String
            var recommendedSize: String?, returned: Bool?, token: String?, productKey: String?, personID: UUID?
        }
        struct TrackedItem: Codable {
            var page: String, createdAt: Date, productName: String?, image: String?, size: String?
            var lastPrice: Double?, firstPrice: Double?, currency: String?
        }
        struct WardrobeItem: Codable {
            var id: UUID, createdAt: Date, name: String, brand: String?, size: String?, category: String, color: String
            var fitStyle: String?, seasons: [String], styles: [String], fitScore: Double?, measurements: Data?
            var wornCount: Int?, lastWornAt: Date?, isReference: Bool?
        }

        var createdAt = Date()
        var people: [PersonItem] = []
        var profiles: [ProfileItem] = []
        var analyses: [AnalysisItem] = []
        var purchases: [PurchaseItem] = []
        var tracked: [TrackedItem] = []
        var wardrobe: [WardrobeItem] = []
        var numbers: [String: Double] = [:]
        var texts: [String: String] = [:]
    }

    /// Settings worth carrying over (each person's basics have the person's id after them).
    private static let settingPrefixes = ["heightCm", "weightKg", "bodySex", "ageYears", "fitPreference", "styleProfile"]

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// When the last backup was made, if iCloud has one.
    static var lastBackup: Date? {
        guard let payload = stored() else { return nil }
        return payload.createdAt
    }

    static func backUp(_ context: ModelContext) {
        guard isEnabled else { return }
        var payload = Payload()
        payload.people = ((try? context.fetch(FetchDescriptor<Person>())) ?? []).map {
            .init(id: $0.id, name: $0.name, createdAt: $0.createdAt, relation: $0.relationRaw)
        }
        // The latest few profiles per person: enough for "measurement changes".
        var perPerson: [UUID?: Int] = [:]
        let profiles = (try? context.fetch(FetchDescriptor<StoredBodyProfile>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        for p in profiles {
            let n = perPerson[p.personID, default: 0]
            guard n < 6 else { continue }
            perPerson[p.personID] = n + 1
            payload.profiles.append(.init(createdAt: p.createdAt, data: p.profileData, personID: p.personID))
        }
        payload.purchases = ((try? context.fetch(FetchDescriptor<PurchaseRecord>())) ?? []).map {
            .init(createdAt: $0.createdAt, brand: $0.brand, productName: $0.productName, category: $0.categoryRaw, size: $0.size,
                  feel: $0.feelRaw, recommendedSize: $0.recommendedSize, returned: $0.returned, token: $0.token,
                  productKey: $0.productKey, personID: $0.personID)
        }
        payload.tracked = ((try? context.fetch(FetchDescriptor<TrackedProduct>())) ?? []).map {
            .init(page: $0.pageURLString, createdAt: $0.createdAt, productName: $0.productName, image: $0.imageURLString,
                  size: $0.size, lastPrice: $0.lastPrice, firstPrice: $0.firstPrice, currency: $0.currency)
        }
        payload.wardrobe = ((try? context.fetch(FetchDescriptor<WardrobeEntry>())) ?? []).map {
            .init(id: $0.id, createdAt: $0.createdAt, name: $0.name, brand: $0.brand, size: $0.size, category: $0.categoryRaw,
                  color: $0.colorRaw, fitStyle: $0.fitStyleRaw, seasons: $0.seasonsRaw, styles: $0.stylesRaw, fitScore: $0.fitScore,
                  measurements: $0.measurementsData, wornCount: $0.wornCount, lastWornAt: $0.lastWornAt, isReference: $0.isReference)
        }
        payload.analyses = ((try? context.fetch(FetchDescriptor<SavedAnalysis>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []).map {
            .init(productKey: $0.productKey, createdAt: $0.createdAt, productName: $0.productName, brand: $0.brand,
                  image: $0.imageURLString, page: $0.pageURLString, spec: $0.specData, analysis: $0.analysisData,
                  material: $0.material, personID: $0.personID)
        }
        for (key, value) in UserDefaults.standard.dictionaryRepresentation()
        where settingPrefixes.contains(where: { key == $0 || key.hasPrefix($0 + ".") }) {
            if let n = value as? Double { payload.numbers[key] = n } else if let s = value as? String { payload.texts[key] = s }
        }
        // Oldest checks go first if it doesn't fit.
        while true {
            guard let data = encode(payload) else { return }
            if data.count <= budget || payload.analyses.isEmpty {
                guard data.count <= budget else { return }
                NSUbiquitousKeyValueStore.default.set(data, forKey: key)
                NSUbiquitousKeyValueStore.default.synchronize()
                return
            }
            payload.analyses.removeLast(max(1, payload.analyses.count / 4))
        }
    }

    /// Removes the backup from iCloud (backup turned off, or all data deleted).
    static func erase() {
        NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    /// Puts the backup into an empty store. Returns whether anything was restored.
    @discardableResult
    static func restore(into context: ModelContext) -> Bool {
        guard let p = stored() else { return false }
        let existingPeople = Set(((try? context.fetch(FetchDescriptor<Person>())) ?? []).map(\.id))
        for x in p.people where !existingPeople.contains(x.id) {
            context.insert(Person(name: x.name, relation: Person.Relation(rawValue: x.relation) ?? .other, id: x.id, createdAt: x.createdAt))
        }
        let existingProfiles = Set(((try? context.fetch(FetchDescriptor<StoredBodyProfile>())) ?? []).map(\.createdAt))
        for x in p.profiles where !existingProfiles.contains(x.createdAt) {
            if let profile = try? JSONDecoder().decode(BodyProfile.self, from: x.data),
               let stored = try? StoredBodyProfile(profile: profile, personID: x.personID) {
                context.insert(stored)
            }
        }
        let existingKeys = Set(((try? context.fetch(FetchDescriptor<SavedAnalysis>())) ?? []).map(\.productKey))
        for x in p.analyses where !existingKeys.contains(x.productKey) {
            if let spec = try? JSONDecoder().decode(GarmentSpec.self, from: x.spec),
               let analysis = try? JSONDecoder().decode(FitAnalysis.self, from: x.analysis),
               let saved = try? SavedAnalysis(productKey: x.productKey, productName: x.productName, brand: x.brand,
                                              imageURL: x.image.flatMap(URL.init(string:)), pageURL: x.page.flatMap(URL.init(string:)),
                                              spec: spec, analysis: analysis, material: x.material, createdAt: x.createdAt,
                                              personID: x.personID) {
                context.insert(saved)
            }
        }
        let existingTokens = Set(((try? context.fetch(FetchDescriptor<PurchaseRecord>())) ?? []).compactMap(\.token))
        for x in p.purchases where x.token.map({ !existingTokens.contains($0) }) ?? true {
            let r = PurchaseRecord(brand: x.brand, productName: x.productName, category: x.category.flatMap(GarmentCategory.init(rawValue:)),
                                   size: x.size, feel: nil, createdAt: x.createdAt, recommendedSize: x.recommendedSize,
                                   productKey: x.productKey, personID: x.personID)
            r.feelRaw = x.feel
            r.returned = x.returned
            r.token = x.token ?? r.token
            context.insert(r)
        }
        let existingPages = Set(((try? context.fetch(FetchDescriptor<TrackedProduct>())) ?? []).map(\.pageURLString))
        for x in p.tracked where !existingPages.contains(x.page) {
            guard let url = URL(string: x.page) else { continue }
            let t = TrackedProduct(pageURL: url, productName: x.productName, imageURL: x.image.flatMap(URL.init(string:)), size: x.size)
            t.createdAt = x.createdAt
            t.lastPrice = x.lastPrice
            t.firstPrice = x.firstPrice
            t.currency = x.currency
            context.insert(t)
        }
        let existingItems = Set(((try? context.fetch(FetchDescriptor<WardrobeEntry>())) ?? []).map(\.id))
        for x in p.wardrobe where !existingItems.contains(x.id) {
            let e = WardrobeEntry(name: x.name, category: .top, color: .multicolor)
            e.id = x.id
            e.createdAt = x.createdAt
            e.brand = x.brand
            e.size = x.size
            e.categoryRaw = x.category
            e.colorRaw = x.color
            e.fitStyleRaw = x.fitStyle
            e.seasonsRaw = x.seasons
            e.stylesRaw = x.styles
            e.fitScore = x.fitScore
            e.measurementsData = x.measurements
            e.wornCount = x.wornCount
            e.lastWornAt = x.lastWornAt
            e.isReference = x.isReference
            context.insert(e)
        }
        for (k, v) in p.numbers where UserDefaults.standard.object(forKey: k) == nil { UserDefaults.standard.set(v, forKey: k) }
        for (k, v) in p.texts where UserDefaults.standard.object(forKey: k) == nil { UserDefaults.standard.set(v, forKey: k) }
        try? context.save()
        return true
    }

    private static func stored() -> Payload? {
        NSUbiquitousKeyValueStore.default.synchronize()
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: key),
              let raw = try? (data as NSData).decompressed(using: .zlib) as Data else { return nil }
        return try? decoder.decode(Payload.self, from: raw)
    }

    private static func encode(_ payload: Payload) -> Data? {
        guard let raw = try? encoder.encode(payload) else { return nil }
        return try? (raw as NSData).compressed(using: .zlib) as Data
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
