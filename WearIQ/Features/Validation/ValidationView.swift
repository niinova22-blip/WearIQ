import BodyMeasurementEngine
import SwiftUI
import WearIQCore

/// Measurement validation: scans made in validation mode, measured by both engines,
/// next to what a tape measure says. For finding out, on real people, whether the
/// experimental silhouette-fit engine measures better than the current one. The app's
/// own measurements never change because of anything here.
struct ValidationView: View {
    @State private var store = ValidationStore.shared
    @State private var enabled = ValidationStore.isEnabled
    @State private var csvURL: URL?
    @State private var jsonURL: URL?

    var body: some View {
        List {
            Section {
                Toggle("Validation mode", isOn: $enabled)
                    .onChange(of: enabled) { _, on in ValidationStore.isEnabled = on }
            } footer: {
                Text("Each body scan is also measured by the experimental engine (B) and kept here. Measure the same person with a tape right after, and enter the values. Your saved measurements always come from the current engine (A).")
            }

            Section("How to measure") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Same clothes as in the scan, standing relaxed, breathing out.")
                    Text("Chest at the nipples, waist at the navel, hips at the widest point of the seat, thigh just below the crotch, neck at its base, upper arm halfway to the elbow.")
                    Text("At least 20–30 people; scanning someone twice shows how repeatable each engine is.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Scans") {
                if store.records.isEmpty {
                    Text("No scans yet. Turn validation mode on and do a body scan.").foregroundStyle(.secondary)
                }
                ForEach(store.records) { record in
                    NavigationLink {
                        ValidationRecordView(record: record)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.participant).font(.headline)
                                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened) + " · " + record.device)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            let taped = ValidationReport.dimensions.filter { record.tape($0) != nil }.count
                            Text(taped == 0 ? String(localized: "No tape yet") : String(localized: "\(taped) taped"))
                                .font(.caption)
                                .foregroundStyle(taped == 0 ? .orange : .secondary)
                        }
                    }
                }
                .onDelete { offsets in store.delete(Set(offsets.map { store.records[$0].id })) }
            }

            ValidationResultsSection(records: store.records)

            Section("Export") {
                if let csvURL { ShareLink("Share as CSV", item: csvURL) }
                if let jsonURL { ShareLink("Share as JSON (with stop profiles)", item: jsonURL) }
            }
        }
        .navigationTitle("Measurement validation")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.records) {
            csvURL = store.records.isEmpty ? nil : store.export(csv: true)
            jsonURL = store.records.isEmpty ? nil : store.export(csv: false)
        }
    }
}

/// The comparison: per measurement each engine's mean absolute error against the
/// tape, its bias and which engine the evidence so far points to.
private struct ValidationResultsSection: View {
    let records: [ValidationRecord]

    var body: some View {
        let report = ValidationReport(records)
        let decisions = EngineSelection.decisions(records)
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(report.records) scans of \(report.participants) people with tape values compared.")
                if report.syntheticLeftOut > 0 {
                    Text("\(report.syntheticLeftOut) synthetic record(s) left out.").foregroundStyle(.orange)
                }
                if report.participants < EngineSelection.minimumParticipants {
                    Text("No engine is chosen before \(EngineSelection.minimumParticipants) people; until then the current engine stays.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text(verbatim: "n")
                    Text("A error")
                    Text("B error")
                    Text("Better")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(ValidationReport.dimensions, id: \.self) { d in
                    let a = report.stats[.current]?[d], b = report.stats[.silhouetteFit]?[d]
                    if a != nil || b != nil {
                        GridRow {
                            Text(d.title).gridColumnAlignment(.leading)
                            Text("\(max(a?.n ?? 0, b?.n ?? 0))")
                            Text(Self.cm(a))
                            Text(Self.cm(b))
                            Text(Self.verdict(decisions[d], a: a, b: b)).foregroundStyle(.secondary)
                        }
                        .font(.footnote.monospacedDigit())
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(MeasurementEngineID.allCases, id: \.self) { e in
                    let parts = [
                        report.overallMAE(e).map { String(format: "MAE %.1f cm", $0) },
                        report.failureRate[e].map { String(localized: "\(Int(($0 * 100).rounded()))% failed") },
                        report.meanProcessingMs[e].map { String(format: "%.0f ms", $0) },
                        report.meanMemoryMB[e].map { String(format: "%.0f MB", $0) },
                    ].compactMap { $0 }
                    if !parts.isEmpty { Text("\(e.rawValue): " + parts.joined(separator: " · ")) }
                }
                if let ar = report.arHeight {
                    Text(String(format: String(localized: "ARKit height: MAE %.1f cm (%+.1f), n %d"), ar.meanAbsoluteError, ar.bias, ar.n))
                }
                if let typed = report.typedHeight {
                    Text(String(format: String(localized: "Typed height: MAE %.1f cm (%+.1f), n %d"), typed.meanAbsoluteError, typed.bias, typed.n))
                }
                if let s = report.meanScanSeconds { Text("Average scan time: \(Int(s.rounded())) s (the same turn for both engines)") }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        } header: {
            Text("Results")
        } footer: {
            Text("Error: mean absolute difference from the tape (bias in brackets: + reads large). Better: decided only with \(EngineSelection.minimumParticipants)+ people and a clear, consistent difference; otherwise the current engine stays.")
        }
    }

    static func cm(_ s: ValidationReport.Stats?) -> String {
        guard let s else { return "–" }
        return String(format: "%.1f (%+.1f)", s.meanAbsoluteError, s.bias)
    }

    static func verdict(_ d: EngineDecision?, a: ValidationReport.Stats?, b: ValidationReport.Stats?) -> String {
        switch d {
        case .useSilhouetteFit?: return "B"
        case .keepCurrent?: return "A"
        default:
            guard let a, let b else { return "–" }
            // So far, not decided: the leaning, in brackets.
            return a.meanAbsoluteError <= b.meanAbsoluteError ? "(A)" : "(B)"
        }
    }
}

/// One scan: the participant code, what they wore, the tape values, and both engines'
/// values with their errors.
struct ValidationRecordView: View {
    @State var record: ValidationRecord
    @State private var store = ValidationStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    private static let clothingOptions: [(String, LocalizedStringKey)] = [
        ("underwear", "Underwear"), ("fitted", "Fitted clothes"), ("everyday", "Everyday clothes"), ("loose", "Loose clothes"),
    ]

    var body: some View {
        Form {
            Section {
                TextField("Participant code", text: $record.participant)
                    .textInputAutocapitalization(.characters)
                Picker("Clothing", selection: $record.clothing) {
                    ForEach(Self.clothingOptions, id: \.0) { Text($0.1).tag($0.0) }
                    if !Self.clothingOptions.contains(where: { $0.0 == record.clothing }) {
                        Text(record.clothing).tag(record.clothing)
                    }
                }
                LabeledContent("Device", value: record.device + (record.hasLiDAR ? " · LiDAR" : ""))
                if let s = record.scanSeconds { LabeledContent("Scan time", value: String(format: "%.0f s", s)) }
            } footer: {
                Text("Use a code, not a name. The same code for the same person makes their scans count as repeats.")
            }

            Section {
                ForEach(ValidationReport.dimensions, id: \.self) { d in
                    row(d)
                }
            } header: {
                Text("Tape (cm) · A · B")
            } footer: {
                Text("A: current engine. B: silhouette fit. ◆ seen by the camera, ◇ from the body model, ○ from height and weight. The error is against your tape value.")
            }

            Section {
                if let ar = record.arScale {
                    LabeledContent("ARKit height", value: String(format: "%.1f ± %.1f cm", ar.statureCm, ar.sdCm))
                    LabeledContent("Distance", value: String(format: "%.2f m", ar.distanceM)
                                   + (ar.lidarDistanceM.map { String(format: " · LiDAR %.2f m", $0) } ?? ""))
                    if let tape = record.tape(.height) {
                        LabeledContent("Against the tape", value: String(format: String(localized: "%+.1f cm (typed %+.1f cm)"),
                                                                         ar.statureCm - tape, record.heightCm - tape))
                    }
                }
                NavigationLink(record.arScale == nil ? LocalizedStringKey("Measure height with ARKit") : LocalizedStringKey("Measure height with ARKit again")) {
                    ARHeightCheckView(record: $record)
                }
            } header: {
                Text("Real-world scale")
            } footer: {
                Text("Checks whether ARKit's floor and camera give the true height without the typed one. One person holds the phone, the other stands. Enter the tape height above to compare.")
            }

            if let notes = record.notes {
                Section("Engine B details") { Text(notes).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }

            Section {
                Button("Delete this scan", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(record.participant)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: record) { _, new in store.upsert(new) }
        .confirmationDialog("Delete this scan?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete([record.id])
                dismiss()
            }
        }
    }

    private func row(_ d: BodyDimension) -> some View {
        let a = record.value(.current, d), b = record.value(.silhouetteFit, d)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(d.title)
                Spacer()
                TextField("tape", value: Binding(get: { record.tape(d) }, set: { record.setTape(d, $0) }),
                          format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
            }
            HStack(spacing: 12) {
                Text("A " + Self.text(a, error: record.error(.current, d)))
                Text("B " + Self.text(b, error: record.error(.silhouetteFit, d)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    static func text(_ v: EngineMeasurement?, error: Double?) -> String {
        guard let v else { return "–" }
        let mark = switch v.provenance {
        case .observed: "◆"
        case .model: "◇"
        case .prior: "○"
        case .tape: "▲"
        }
        var s = String(format: "%.1f±%.1f %@", v.cm, v.sdCm, mark)
        if let error { s += String(format: " (%+.1f)", error) }
        return s
    }
}
