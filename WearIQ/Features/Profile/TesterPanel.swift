import BodyMeasurementEngine
import FitEngine
import Foundation
import ProductMeasurementParser
import ShoppingAssistant
import SwiftData
import SwiftUI
import WearIQCore

/// Builds the app is tested with (Debug, and TestFlight builds with Premium unlocked for
/// testers): never a store build.
enum TesterBuild {
    static var isActive: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.object(forInfoDictionaryKey: "WQUnlockPremium") as? Bool == true
        #endif
    }
}

/// Two ready-made shoppers for testers, a woman and a man of average build, each with
/// thirty products already checked (from the engine tests' catalog, `TestCatalog`). They
/// are people in "Shopping for", so switching to one moves every screen to them: checks,
/// avatar, style pairings, size passport.
@MainActor
enum TestShoppers {
    struct Persona {
        let id: UUID
        let name: String
        let sex: BodySex
        let audience: GarmentAudience
    }

    static let woman = Persona(id: UUID(uuidString: "7E57E11F-0000-4000-8000-00000000F001")!,
                               name: String(localized: "Test · Elif"), sex: .female, audience: .women)
    static let man = Persona(id: UUID(uuidString: "7E57E11F-0000-4000-8000-00000000A001")!,
                             name: String(localized: "Test · Mert"), sex: .male, audience: .men)
    static let all = [woman, man]

    static func isTestPerson(_ id: UUID?) -> Bool { all.contains { $0.id == id } }

    /// A plausible height and weight: heights around each sex's average, a healthy BMI.
    static func basics(_ persona: Persona) -> (height: Double, weight: Double, age: Double) {
        let height = persona.sex == .female ? Double.random(in: 158...172) : Double.random(in: 171...186)
        let bmi = persona.sex == .female ? Double.random(in: 19.5...23.5) : Double.random(in: 21.5...25)
        let weight = (bmi * height * height / 10_000).rounded()
        return (height.rounded(), weight, Double(Int.random(in: 22...38)))
    }

    /// The body: the population's measurements for that height, weight, sex and age, as
    /// if scanned (each within the scan's usual error), so advice reads as for a scan.
    static func body(_ persona: Persona, height: Double, weight: Double, age: Double) -> BodyProfile {
        let estimate = AnthropometricPrior().estimate(heightCm: height, weightKg: weight, sex: persona.sex, ageYears: age)
        var values: [BodyDimension: MeasuredValue] = [.height: MeasuredValue(cm: height, uncertaintyCm: 0, source: .userProvided)]
        for (d, v) in estimate where d != .height {
            values[d] = MeasuredValue(cm: (v.cm * 10).rounded() / 10, uncertaintyCm: min(v.uncertaintyCm, 2.5), source: .scan)
        }
        return BodyProfile(values: values, weightKg: weight, sex: persona.sex)
    }

    /// Creates both (or makes them anew, with new heights and weights).
    static func install(_ context: ModelContext, engine: any FitAnalyzing = FitEngine()) throws {
        remove(context)
        for persona in all {
            context.insert(Person(name: persona.name, relation: .other, id: persona.id))
            let b = basics(persona)
            let body = body(persona, height: b.height, weight: b.weight, age: b.age)
            context.insert(try StoredBodyProfile(profile: body, personID: persona.id))
            for (i, product) in TestCatalog.products(for: persona.audience).enumerated() {
                let analysis = engine.analyze(body: body, garment: product.spec, preference: .asDesigned)
                context.insert(try SavedAnalysis(productKey: product.key, productName: product.name, brand: product.brand,
                                                 imageURL: nil, pageURL: nil, spec: product.spec, analysis: analysis,
                                                 material: product.material,
                                                 createdAt: Date().addingTimeInterval(-Double(i) * 3_600),
                                                 personID: persona.id))
            }
        }
        try context.save()
    }

    static func remove(_ context: ModelContext) {
        let ids = Set(all.map(\.id))
        for p in (try? context.fetch(FetchDescriptor<Person>())) ?? [] where ids.contains(p.id) { context.delete(p) }
        for p in (try? context.fetch(FetchDescriptor<StoredBodyProfile>())) ?? [] where p.personID.map({ ids.contains($0) }) == true {
            context.delete(p)
        }
        for a in (try? context.fetch(FetchDescriptor<SavedAnalysis>())) ?? [] where a.personID.map({ ids.contains($0) }) == true {
            context.delete(a)
        }
        try? context.save()
    }
}

/// Profile → "Test panel" (test builds only): the two test shoppers, switching between
/// them and back, their measurements and checks, and making them anew.
struct TesterPanelView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]
    @Query(sort: \SavedAnalysis.createdAt, order: .reverse) private var analyses: [SavedAnalysis]
    @State private var error: String?
    @State private var confirmRemove = false

    private var installed: Bool { profiles.contains { TestShoppers.isTestPerson($0.personID) } }

    var body: some View {
        List {
            Section {
                Text("Two ready-made shoppers, a woman and a man, each with 30 checked products: every kind of garment, cut and leg. Switch to one and every screen (checks, avatar, style, size passport) is theirs. Your own data isn't touched.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button(installed ? "Make them again (new height and weight)" : "Create the test shoppers") {
                    do { try TestShoppers.install(modelContext) } catch { self.error = error.localizedDescription }
                }
            } footer: {
                Text("Only in test builds. Heights and weights are picked at random in a healthy range; measurements are the population's for them.")
            }
            if installed {
                ForEach(TestShoppers.all, id: \.id) { persona in
                    shopper(persona)
                }
                Section {
                    Button {
                        container.activePersonID = nil
                    } label: {
                        Label("Back to me", systemImage: container.activePersonID == nil ? "checkmark.circle.fill" : "person.crop.circle")
                    }
                    Button("Remove the test shoppers", role: .destructive) { confirmRemove = true }
                }
            }
        }
        .navigationTitle("Test panel")
        .confirmationDialog("Remove the test shoppers and their checks?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if TestShoppers.isTestPerson(container.activePersonID) { container.activePersonID = nil }
                TestShoppers.remove(modelContext)
            }
        }
        .alert("Couldn't create them", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func shopper(_ persona: TestShoppers.Persona) -> some View {
        let body = profiles.of(persona.id).first?.profile
        let checks = analyses.filter { $0.personID == persona.id }
        let active = container.activePersonID == persona.id
        return Section {
            Button {
                container.activePersonID = persona.id
            } label: {
                HStack {
                    Label(active ? String(localized: "Using this shopper") : String(localized: "Switch to this shopper"),
                          systemImage: active ? "checkmark.circle.fill" : "arrow.left.arrow.right.circle")
                    Spacer()
                }
            }
            .disabled(active)
            if let body {
                LabeledContent("Height and weight",
                               value: "\(Int(body[.height]?.cm ?? 0)) cm · \(Int(body.weightKg ?? 0)) kg")
                ForEach([BodyDimension.chest, .waist, .hip, .inseam], id: \.self) { d in
                    if let v = body[d] { LabeledContent(d.title, value: v.formatted) }
                }
            }
            NavigationLink {
                List(checks) { saved in
                    NavigationLink { FitResultView(saved: saved) } label: { ScanHistoryRow(saved: saved) }
                }
                .navigationTitle(persona.name)
            } label: {
                LabeledContent("Checked products", value: "\(checks.count)")
            }
        } header: {
            Text(persona.name)
        }
    }
}
