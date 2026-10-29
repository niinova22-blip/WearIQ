import Testing
@testable import ProductMeasurementParser
import WearIQCore

@Suite struct FabricAdviceTests {
    @Test func readsCompositions() {
        #expect(FabricAdvice.fibres(in: "%98 Pamuk %2 Elastan") == [.cotton: 98, .elastane: 2])
        #expect(FabricAdvice.fibres(in: "98% cotton, 2% elastane") == [.cotton: 98, .elastane: 2])
        #expect(FabricAdvice.fibres(in: "Ana Kumaş: %83 Pamuk, %17 Poliester") == [.cotton: 83, .polyester: 17])
        #expect(FabricAdvice.fibres(in: "Viskon: %95, Elastan: %5") == [.viscose: 95, .elastane: 5])
    }

    @Test func stretchAndShrink() {
        let tee = FabricAdvice.notes(composition: "%100 Pamuk", category: .tshirt)
        #expect(tee.contains(.noStretch))
        #expect(tee.contains(.cottonShrinks))
        #expect(FabricAdvice.shrinkRisk(tee))
        let jeans = FabricAdvice.notes(composition: "%98 Pamuk %2 Elastan", category: .pants, productName: "Slim Jean")
        #expect(jeans.contains(.someStretch(percent: 2)))
        #expect(jeans.contains(.cottonShrinks))  // 2% elastane still shrinks like cotton
        let leggings = FabricAdvice.notes(composition: "%80 Polyamid %20 Elastan", category: .pants)
        #expect(leggings.contains(.highStretch(percent: 20)))
        #expect(leggings.contains(.syntheticStable))
        let rigid = FabricAdvice.notes(composition: "%100 Cotton", category: .pants, productName: "Straight Fit Jean")
        #expect(rigid.contains(.denimGives))
    }

    @Test func findsTheCompositionInPageText() {
        let text = "Erkek eşofman altı. Ana Kumaş: %83 Pamuk, %17 Poliester. Kalıp: Standart"
        #expect(FabricAdvice.compositionText(in: text)?.contains("83") == true)
        #expect(FabricAdvice.compositionText(in: "Fiyat 299 TL, %20 indirim") == nil)
    }
}
