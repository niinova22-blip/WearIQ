#if DEBUG
import FitEngine
import Foundation
import OutfitRecommendationEngine
import SwiftData
import WearIQCore

/// Screenshot mode for App Store images, compiled into Debug builds only.
///
/// Launch with `-WQDemo <home|result|wardrobe|style|profile>`. The app then runs on an
/// in-memory store filled with a sample body profile and wardrobe. The fit result shown
/// is produced by the real `FitEngine` from a sample size chart, not hand-written.
enum DemoMode {
    static var screen: String? { UserDefaults.standard.string(forKey: "WQDemo") }
    static var isActive: Bool { screen != nil }

    static var initialTab: AppTab {
        switch screen {
        case "wardrobe": .wardrobe
        case "style": .style
        case "profile", "passport", "memory": .profile
        case "scan": .scan
        default: .home
        }
    }

    static var opensResult: Bool { screen == "result" }
    /// The newest check on the avatar, for checking the renderer on CI.
    static var opensAvatar: Bool { screen == "avatar" }
    /// Profile → size passport, and Profile → shopping memory (what Safari saw).
    static var opensPassport: Bool { screen == "passport" }
    static var opensMemory: Bool { screen == "memory" }

    private static var turkish: Bool { Locale.current.language.languageCode?.identifier == "tr" }
    private static func text(_ tr: String, _ en: String) -> String { turkish ? tr : en }

    @MainActor
    static func seed(_ context: ModelContext, engine: any FitAnalyzing) throws {
        // A woman of average build: most of the app's shoppers.
        let body = BodyProfile(values: [
            .height: MeasuredValue(cm: 168, uncertaintyCm: 0, source: .userProvided),
            .shoulderWidth: MeasuredValue(cm: 38.5, uncertaintyCm: 1.2, source: .scan),
            .chest: MeasuredValue(cm: 90, uncertaintyCm: 1.8, source: .scan),
            .waist: MeasuredValue(cm: 71, uncertaintyCm: 1.6, source: .scan),
            .hip: MeasuredValue(cm: 98, uncertaintyCm: 1.8, source: .scan),
            .thigh: MeasuredValue(cm: 56, uncertaintyCm: 2, source: .scan),
            .armLength: MeasuredValue(cm: 57, uncertaintyCm: 1.5, source: .scan),
            .torsoLength: MeasuredValue(cm: 41, uncertaintyCm: 2, source: .scan),
            .inseam: MeasuredValue(cm: 78, uncertaintyCm: 2, source: .scan),
        ], createdAt: Date().addingTimeInterval(-86_400 * 3), weightKg: 60, sex: .female)
        context.insert(try StoredBodyProfile(profile: body))
        UserDefaults.standard.set(BodySex.female.rawValue, forKey: "bodySex")
        let style = StyleProfile(undertone: .warm, depth: .medium, vibe: .classic, occasion: .everyday, ease: .fitted, scanned: true)
        if let data = try? JSONEncoder().encode(style) {
            UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: "styleProfile")
        }
        var learned = StyleLearning.Style(topFit: .regular, bottomFit: .regular, legCut: .straight)
        learned.confirmed = true
        LearnedStyle(style: learned, topColor: .white, bottomColor: .denim).save()

        func v(_ cm: Double) -> MeasuredValue { MeasuredValue(cm: cm, uncertaintyCm: 1, source: .manual) }
        let dress = GarmentSpec(category: .dress, fitStyle: .regular, stretch: .low, chartKind: .garment, sizes: [
            SizeEntry(label: "XS", values: [.chest: v(86), .waist: v(70), .hip: v(96), .bodyLength: v(118)]),
            SizeEntry(label: "S", values: [.chest: v(91), .waist: v(75), .hip: v(101), .bodyLength: v(119)]),
            SizeEntry(label: "M", values: [.chest: v(96), .waist: v(80), .hip: v(106), .bodyLength: v(120)]),
            SizeEntry(label: "L", values: [.chest: v(102), .waist: v(86), .hip: v(112), .bodyLength: v(121)]),
            SizeEntry(label: "XL", values: [.chest: v(108), .waist: v(92), .hip: v(118), .bodyLength: v(122)]),
        ])
        let jeans = GarmentSpec(category: .pants, fitStyle: .regular, stretch: .low, chartKind: .garment, sizes: [
            SizeEntry(label: "34", values: [.waist: v(66), .hip: v(94), .inseam: v(78)]),
            SizeEntry(label: "36", values: [.waist: v(70), .hip: v(98), .inseam: v(78)]),
            SizeEntry(label: "38", values: [.waist: v(74), .hip: v(102), .inseam: v(78)]),
            SizeEntry(label: "40", values: [.waist: v(78), .hip: v(106), .inseam: v(78)]),
        ], legCut: .straight)
        let shirt = GarmentSpec(category: .shirt, fitStyle: .relaxed, chartKind: .garment, sizes: [
            SizeEntry(label: "XS", values: [.chest: v(100), .shoulderWidth: v(39), .sleeveLength: v(58), .bodyLength: v(66)]),
            SizeEntry(label: "S", values: [.chest: v(106), .shoulderWidth: v(40.5), .sleeveLength: v(59), .bodyLength: v(68)]),
            SizeEntry(label: "M", values: [.chest: v(112), .shoulderWidth: v(42), .sleeveLength: v(60), .bodyLength: v(70)]),
            SizeEntry(label: "L", values: [.chest: v(118), .shoulderWidth: v(43.5), .sleeveLength: v(61), .bodyLength: v(72)]),
        ])
        let blazer = GarmentSpec(category: .jacket, fitStyle: .regular, chartKind: .garment, sizes: [
            SizeEntry(label: "34", values: [.chest: v(90), .shoulderWidth: v(37), .sleeveLength: v(58), .bodyLength: v(68)]),
            SizeEntry(label: "36", values: [.chest: v(94), .shoulderWidth: v(38), .sleeveLength: v(59), .bodyLength: v(69)]),
            SizeEntry(label: "38", values: [.chest: v(98), .shoulderWidth: v(39), .sleeveLength: v(60), .bodyLength: v(70)]),
            SizeEntry(label: "40", values: [.chest: v(102), .shoulderWidth: v(40), .sleeveLength: v(61), .bodyLength: v(71)]),
        ])
        // Newest last: the dress is the check the result and avatar screens show.
        let analyses: [(String, String, String, GarmentSpec, String, TimeInterval, Bool)] = [
            ("demo-blazer", text("Kruvaze Blazer Ceket", "Double-Breasted Blazer"), "Atelier Nord", blazer,
             "70% Polyester 30% Viscose", -26_000, true),
            ("demo-shirt", text("Keten Rahat Gömlek", "Relaxed Linen Shirt"), "Lumen", shirt, "100% Linen", -14_400, true),
            ("demo-jeans", text("Yüksek Bel Straight Jean", "High-Rise Straight Jeans"), "Indigo & Co", jeans,
             "99% Cotton 1% Elastane", -7_200, false),
            ("demo-dress", text("Saten Midi Elbise", "Satin Midi Dress"), "Maison Rose", dress,
             "97% Viscose 3% Elastane", 0, false),
        ]
        for (key, name, brand, spec, material, offset, safari) in analyses {
            let saved = try SavedAnalysis(productKey: key, productName: name, brand: brand, imageURL: nil, pageURL: nil, spec: spec,
                                          analysis: engine.analyze(body: body, garment: spec, preference: .asDesigned),
                                          material: material, createdAt: Date().addingTimeInterval(offset))
            saved.fromSafari = safari
            context.insert(saved)
        }
        // Sizes that fit, as told after delivery: the size passport's brand rows.
        let bought: [(String, GarmentCategory, String)] = [
            ("Lumen", .shirt, "S"), ("Indigo & Co", .pants, "36"), ("Maison Rose", .dress, "S"), ("Atelier Nord", .jacket, "36"),
        ]
        for (brand, category, size) in bought {
            context.insert(PurchaseRecord(brand: brand, productName: nil, category: category, size: size, feel: .right,
                                          createdAt: Date().addingTimeInterval(-86_400 * 20)))
        }

        let wardrobe: [WardrobeEntry] = [
            WardrobeEntry(name: text("Beyaz keten gömlek", "White linen shirt"), category: .top, color: .white, size: "S",
                          fitStyle: .relaxed, styles: [.casual, .smartCasual, .business], fitScore: 0.9),
            WardrobeEntry(name: text("Krem triko kazak", "Cream knit sweater"), category: .top, color: .beige, size: "S",
                          seasons: [.autumn, .winter], styles: [.casual, .smartCasual], fitScore: 0.85),
            WardrobeEntry(name: text("Siyah body", "Black bodysuit"), category: .top, color: .black, size: "S",
                          fitStyle: .slim, styles: [.casual, .evening, .smartCasual], fitScore: 0.9),
            WardrobeEntry(name: text("Yüksek bel straight jean", "High-rise straight jeans"), category: .bottom, color: .denim,
                          size: "36", styles: [.casual, .smartCasual], fitScore: 0.9),
            WardrobeEntry(name: text("Bej kumaş pantolon", "Beige tailored trousers"), category: .bottom, color: .beige, size: "36",
                          styles: [.smartCasual, .business, .formal], fitScore: 0.85),
            WardrobeEntry(name: text("Saten midi elbise", "Satin midi dress"), category: .dress, color: .burgundy, size: "S",
                          styles: [.evening, .formal], fitScore: 0.9),
            WardrobeEntry(name: text("Camel kaban", "Camel coat"), category: .outerwear, color: .beige, size: "S",
                          seasons: [.autumn, .winter], styles: [.smartCasual, .business, .formal], fitScore: 0.85),
            WardrobeEntry(name: text("Siyah blazer", "Black blazer"), category: .outerwear, color: .black, size: "36",
                          styles: [.smartCasual, .business, .evening], fitScore: 0.8),
            WardrobeEntry(name: text("Beyaz sneaker", "White sneakers"), category: .shoes, color: .white, size: "38",
                          styles: [.casual, .smartCasual, .sporty]),
            WardrobeEntry(name: text("Siyah loafer", "Black loafers"), category: .shoes, color: .black, size: "38",
                          styles: [.smartCasual, .business, .formal]),
        ]
        wardrobe.forEach(context.insert)
        try context.save()
    }
}
#endif
