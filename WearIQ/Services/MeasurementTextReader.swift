import Foundation
import ProductMeasurementParser
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Measurements a product page gives in prose ("M beden ürünün iç boyu 79 cm") read by
/// Apple's on-device language model, on iOS 26 phones with Apple Intelligence. The model
/// only proposes; `TextMeasurements` keeps a number only when it is in the text, under a
/// name the textile dictionary knows, for a size the store sells. Nothing leaves the
/// phone. Elsewhere it proposes nothing and the page reads as before.
enum MeasurementTextReader {
    static func chart(text: String, sizes: [String]) async -> ParsedSizeChart? {
        let proposals = await proposals(for: text, sizes: sizes)
        guard !proposals.isEmpty else { return nil }
        return TextMeasurements.chart(from: proposals, text: text, sizes: sizes)
    }

    static func proposals(for text: String, sizes: [String]) async -> [TextMeasurements.Proposal] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await OnDeviceMeasurementModel.proposals(for: text, sizes: sizes)
        }
        #endif
        return []
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct StatedMeasurements {
    @Guide(description: "Every number in the text that measures the garment or a body, one entry per number")
    var measurements: [StatedMeasurement]
}

@available(iOS 26.0, *)
@Generable
struct StatedMeasurement {
    @Guide(description: "The size label the number is for, exactly as written (for example M, 32 or 38). Empty when the text names no size.")
    var size: String
    @Guide(description: "The measurement's name exactly as written in the text (for example İç boy, Bel, Paça genişliği, inseam)")
    var name: String
    @Guide(description: "The number as written, with a dot for decimals")
    var value: Double
    @Guide(description: "The unit written with the number", .anyOf(["cm", "inch"]))
    var unit: String
    @Guide(description: "body: the body a size is made for; garment: the finished garment measured round; flat: the garment laid flat and measured across; model: the person in the photos",
           .anyOf(["body", "garment", "flat", "model"]))
    var basis: String
}

@available(iOS 26.0, *)
enum OnDeviceMeasurementModel {
    static func proposals(for text: String, sizes: [String]) async -> [TextMeasurements.Proposal] {
        guard case .available = SystemLanguageModel.default.availability else { return [] }
        let sold = sizes.isEmpty ? "" : " The store sells these sizes: \(sizes.joined(separator: ", "))."
        let instructions = "You read clothing product descriptions in Turkish or English and list the measurements they state. "
            + "Copy names, numbers and size labels exactly as they are written. Never add a number that isn't in the text." + sold
        let session = LanguageModelSession(instructions: { instructions })
        let prompt: String = text
        do {
            let response = try await session.respond(to: prompt, generating: StatedMeasurements.self)
            return response.content.measurements.map {
                TextMeasurements.Proposal(size: $0.size, name: $0.name, value: $0.value, unit: $0.unit, basis: $0.basis)
            }
        } catch {
            return []
        }
    }
}
#endif
