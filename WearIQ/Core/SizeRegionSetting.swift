import Foundation
import ProductMeasurementParser
import SwiftUI

/// The size system the user shops in (Profile → Size system): Türkiye, Europe or the
/// United States, or automatic, which follows the app's language (Turkish → Türkiye,
/// English → Europe; English on a US device → United States).
enum SizeRegionSetting {
    static let key = "sizeRegion"
    /// Stored value: "auto" or a `SizeRegion` raw value.
    static let automatic = "auto"

    static var current: SizeRegion {
        resolve(UserDefaults.standard.string(forKey: key) ?? automatic)
    }

    static func resolve(_ stored: String) -> SizeRegion {
        if let region = SizeRegion(rawValue: stored) { return region }
        return SizeRegion.automatic(language: Bundle.main.preferredLocalizations.first,
                                    region: Locale.current.region?.identifier)
    }
}

extension SizeRegion {
    var title: LocalizedStringKey {
        switch self {
        case .tr: "Türkiye"
        case .eu: "Europe"
        case .us: "United States"
        }
    }

    /// What the system looks like, for the picker's footer.
    var example: LocalizedStringKey {
        switch self {
        case .tr: "Women 36/38/40, men's trousers 46/48/50, jeans 31/32"
        case .eu: "Women 36/38/40 (EN 13402), men's trousers 46/48/50, jeans W31 L32"
        case .us: "Women 4/6/8, men's trousers and jeans 31×32"
        }
    }
}

/// Profile → Size system.
struct SizeRegionSection: View {
    @AppStorage(SizeRegionSetting.key) private var stored = SizeRegionSetting.automatic
    @Environment(\.modelContext) private var context

    var body: some View {
        Section {
            Picker("Size system", selection: $stored) {
                Text("Automatic (\(Text(SizeRegionSetting.resolve(SizeRegionSetting.automatic).title)))")
                    .tag(SizeRegionSetting.automatic)
                ForEach(SizeRegion.allCases, id: \.self) { region in
                    Text(region.title).tag(region.rawValue)
                }
            }
        } header: {
            Text("Size system")
        } footer: {
            Text("Sizes are recommended in the store's own labels. When a store lists none, WearIQ uses this system, and shows the store's size in it too. \(Text(SizeRegionSetting.resolve(stored).example))")
        }
        // The Safari extension sizes pages with it too.
        .onChange(of: stored) { _, _ in ShoppingMemory.publishShopper(context) }
    }
}
