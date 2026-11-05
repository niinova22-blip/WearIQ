import FitEngine
import SwiftUI
import WearIQCore

/// How likely the order is to go back, for the size picked, and why; a stronger warning
/// for garments that usually can't be returned (swimwear, underwear).
struct ReturnRiskCard: View {
    let analysis: FitAnalysis
    let size: String?
    let category: GarmentCategory?
    let productName: String?

    var body: some View {
        let risk = ReturnRisk.assess(analysis, size: size, category: category, productName: productName)
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: risk.level.symbol)
                    .font(.title3)
                    .foregroundStyle(risk.level.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(risk.level.title).font(.headline)
                    if let size { Text("For size \(size)").font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            ForEach(risk.reasons, id: \.self) { reason in
                Label(reason.text, systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if risk.nonReturnable {
                Label(risk.level == .low
                      ? String(localized: "Swimwear and underwear usually can't be returned once opened. This size looks right; check the store's return rules all the same.")
                      : String(localized: "Swimwear and underwear usually can't be returned once opened, and this size isn't a sure fit. Measure yourself with a tape or ask the store before ordering."),
                      systemImage: "exclamationmark.shield.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(risk.level == .low ? Color.orange : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension ReturnRisk.Level {
    var title: String {
        switch self {
        case .low: String(localized: "Return risk: low")
        case .medium: String(localized: "Return risk: medium")
        case .high: String(localized: "Return risk: high")
        }
    }

    var symbol: String {
        switch self {
        case .low: "checkmark.shield.fill"
        case .medium: "exclamationmark.triangle.fill"
        case .high: "arrow.uturn.backward.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }
}

extension ReturnRisk.Reason {
    var text: String {
        switch self {
        case .insufficientData: String(localized: "The size chart is missing what decides the size.")
        case .noSizeFits: String(localized: "No size on the chart fits you where it matters most.")
        case .betweenSizes: String(localized: "You're between two sizes; either could feel off.")
        case .fromEstimates: String(localized: "Your key measurement is an estimate from height and weight. A scan makes this surer.")
        case .criticalRegionOff: String(localized: "This size is off where it matters most (chest for tops, waist and hips for bottoms).")
        case .otherRegionOff: String(localized: "This size is clearly off somewhere (length or sleeves).")
        case .lowConfidence: String(localized: "Your measurements sit at the edge of this size: the size next to it could be the right one.")
        case .mediumConfidence: String(localized: "A small difference in your measurements could change the size.")
        }
    }
}
