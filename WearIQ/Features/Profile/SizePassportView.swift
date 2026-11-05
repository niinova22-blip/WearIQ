import ShoppingAssistant
import SwiftData
import SwiftUI
import WearIQCore

/// The size passport: the user's sizes in the usual systems, their style, and brand
/// against brand, in one place and as text to share.
struct SizePassportView: View {
    @Environment(AppContainer.self) private var container
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]
    @Query(sort: \SavedAnalysis.createdAt, order: .reverse) private var analyses: [SavedAnalysis]
    @Query(sort: \PurchaseRecord.createdAt, order: .reverse) private var purchases: [PurchaseRecord]
    @AppStorage(LearnedStyle.key) private var storedStyle: Data?

    private var body_: BodyProfile? { profiles.of(container.activePersonID).first?.profile }

    private var brandRows: [(category: GarmentCategory?, brands: [SizePassport.BrandSize])] {
        let person = container.activePersonID
        var sizes: [SizePassport.BrandSize] = []
        for p in purchases where p.personID == person && !p.isPending && p.feel == .right && p.returned != true {
            sizes.append(.init(brand: p.brand, category: p.category, size: p.size, confirmed: true))
        }
        for a in analyses where a.personID == person {
            if let brand = a.brand, let size = a.analysis?.recommendedSize?.label {
                sizes.append(.init(brand: brand, category: a.spec?.category, size: size, confirmed: false))
            }
        }
        return SizePassport.compare(sizes)
    }

    var body: some View {
        List {
            if let body = body_ {
                Section("Measurements") {
                    ForEach([BodyDimension.height, .chest, .waist, .hip, .inseam], id: \.self) { d in
                        if let v = body[d] { LabeledContent(d.title, value: "\(Int(v.cm.rounded())) cm") }
                    }
                }
                Section {
                    ForEach(Array(SizePassport.lines(for: body).enumerated()), id: \.offset) { _, line in
                        LabeledContent(line.label, value: line.otherSize.map { "\(line.size)–\($0)" } ?? line.size)
                    }
                } header: {
                    Text("Your sizes")
                } footer: {
                    Text("From typical size charts; a store's own chart can differ, which is what each check is for.")
                }
                if container.activePersonID == nil,
                   let learned = storedStyle.flatMap({ try? JSONDecoder().decode(LearnedStyle.self, from: $0) }), learned.style.confirmed {
                    Section("Your style") { Text(learned.summary) }
                }
                let rows = brandRows
                if !rows.isEmpty {
                    Section {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.category?.title ?? String(localized: "Garment")).font(.subheadline.weight(.semibold))
                                Text(row.brands.map { "\($0.brand) \($0.size)" + ($0.confirmed ? " ✓" : "") }.joined(separator: " · "))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Brand by brand")
                    } footer: {
                        Text("✓ a purchase you said fit right; the rest are WearIQ's checks.")
                    }
                }
                Section {
                    ShareLink(item: passportText(body)) { Label("Share my size passport", systemImage: "square.and.arrow.up") }
                }
            } else {
                ContentUnavailableView("No measurements yet", systemImage: "ruler",
                                       description: Text("Scan or enter your measurements to get your size passport."))
            }
        }
        .navigationTitle("Size passport")
    }

    private func passportText(_ body: BodyProfile) -> String {
        var lines = [String(localized: "My WearIQ size passport")]
        for d in [BodyDimension.height, .chest, .waist, .hip, .inseam] {
            if let v = body[d] { lines.append("\(d.title): \(Int(v.cm.rounded())) cm") }
        }
        for line in SizePassport.lines(for: body) {
            lines.append("\(line.label): " + (line.otherSize.map { "\(line.size)–\($0)" } ?? line.size))
        }
        for row in brandRows {
            lines.append((row.category?.title ?? "") + ": " + row.brands.map { "\($0.brand) \($0.size)" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}

extension SizePassport.Line {
    var label: String {
        switch system {
        case .letters: category.title
        case .european: String(localized: "\(category.title) (EU)")
        case .waistInches: String(localized: "\(category.title) (waist)")
        }
    }
}
