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
        case "profile": .profile
        default: .home
        }
    }

    static var opensResult: Bool { screen == "result" }

    private static var turkish: Bool { Locale.current.language.languageCode?.identifier == "tr" }
    private static func text(_ tr: String, _ en: String) -> String { turkish ? tr : en }

    @MainActor
    static func seed(_ context: ModelContext, engine: any FitAnalyzing) throws {
        let body = BodyProfile(values: [
            .height: MeasuredValue(cm: 178, uncertaintyCm: 0, source: .userProvided),
            .shoulderWidth: MeasuredValue(cm: 46, uncertaintyCm: 1.5, source: .scan),
            .chest: .manual(100),
            .waist: .manual(86),
            .hip: .manual(98),
            .armLength: MeasuredValue(cm: 63, uncertaintyCm: 2, source: .scan),
            .torsoLength: MeasuredValue(cm: 46, uncertaintyCm: 2.5, source: .scan),
            .inseam: MeasuredValue(cm: 81, uncertaintyCm: 2.5, source: .scan),
        ], createdAt: Date().addingTimeInterval(-86_400 * 3))
        context.insert(try StoredBodyProfile(profile: body))

        func size(_ label: String, chest: Double, shoulder: Double, sleeve: Double, length: Double) -> SizeEntry {
            SizeEntry(label: label, values: [.chest: .manual(chest), .shoulderWidth: .manual(shoulder),
                                             .sleeveLength: .manual(sleeve), .bodyLength: .manual(length)])
        }
        let shirt = GarmentSpec(category: .shirt, fitStyle: .regular, chartKind: .garment, sizes: [
            size("S", chest: 104, shoulder: 44, sleeve: 62, length: 74),
            size("M", chest: 110, shoulder: 46, sleeve: 63.5, length: 76),
            size("L", chest: 116, shoulder: 48, sleeve: 65, length: 78),
            size("XL", chest: 122, shoulder: 50, sleeve: 66.5, length: 80),
        ])
        let pants = GarmentSpec(category: .pants, fitStyle: .slim, stretch: .low, chartKind: .garment, sizes: [
            SizeEntry(label: "30", values: [.waist: .manual(80), .hip: .manual(98), .inseam: .manual(80)]),
            SizeEntry(label: "32", values: [.waist: .manual(85), .hip: .manual(102), .inseam: .manual(81)]),
            SizeEntry(label: "34", values: [.waist: .manual(90), .hip: .manual(106), .inseam: .manual(82)]),
        ])
        let analyses: [(String, String, GarmentSpec, TimeInterval)] = [
            ("demo-pants", text("Slim Fit Chino Pantolon", "Slim Fit Chinos"), pants, -7_200),
            ("demo-shirt", text("Oxford Gömlek", "Oxford Shirt"), shirt, 0),
        ]
        for (key, name, spec, offset) in analyses {
            context.insert(try SavedAnalysis(productKey: key, productName: name, brand: text("Örnek Marka", "Sample Brand"),
                                             imageURL: nil, pageURL: nil, spec: spec,
                                             analysis: engine.analyze(body: body, garment: spec, preference: .asDesigned),
                                             createdAt: Date().addingTimeInterval(offset)))
        }

        let wardrobe: [WardrobeEntry] = [
            WardrobeEntry(name: text("Beyaz Oxford gömlek", "White Oxford shirt"), category: .top, color: .white, size: "M",
                          fitStyle: .regular, styles: [.smartCasual, .business], fitScore: 0.9),
            WardrobeEntry(name: text("Lacivert triko", "Navy knit sweater"), category: .top, color: .navy, size: "M",
                          seasons: [.autumn, .winter], styles: [.casual, .smartCasual], fitScore: 0.8),
            WardrobeEntry(name: text("Bej chino", "Beige chinos"), category: .bottom, color: .beige, size: "32",
                          fitStyle: .slim, styles: [.casual, .smartCasual, .business], fitScore: 0.85),
            WardrobeEntry(name: text("Koyu kot pantolon", "Dark denim jeans"), category: .bottom, color: .denim, size: "32",
                          styles: [.casual], fitScore: 0.75),
            WardrobeEntry(name: text("Kahverengi deri ceket", "Brown leather jacket"), category: .outerwear, color: .brown,
                          size: "L", seasons: [.spring, .autumn], styles: [.casual, .smartCasual, .evening], fitScore: 0.7),
            WardrobeEntry(name: text("Beyaz sneaker", "White sneakers"), category: .shoes, color: .white, size: "43",
                          styles: [.casual, .smartCasual, .sporty]),
            WardrobeEntry(name: text("Gri yün kaban", "Grey wool coat"), category: .outerwear, color: .gray, size: "L",
                          seasons: [.autumn, .winter], styles: [.smartCasual, .business, .formal], fitScore: 0.8),
        ]
        wardrobe.forEach(context.insert)
        try context.save()
    }
}
#endif
