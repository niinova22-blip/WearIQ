import SwiftData
import SwiftUI
import WearIQCore

struct MeasurementReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var model: MeasurementReviewModel
    @State private var editing: BodyDimension?
    @State private var saveError: String?
    let onSaved: () -> Void

    init(profile: BodyProfile, onSaved: @escaping () -> Void) {
        _model = State(initialValue: MeasurementReviewModel(profile: profile))
        self.onSaved = onSaved
    }

    var body: some View {
        List {
            if !model.estimated.isEmpty {
                Section {
                    Label(model.scanned.isEmpty
                          ? String(localized: "These values are estimated from your height and weight, not measured. Check the ones that matter most (chest, waist, hip) with a tape measure.")
                          : String(localized: "\(model.scanned.count) values come from your photos and \(model.estimated.count) are estimated from your height and weight. Check the estimated ones with a tape measure."),
                          systemImage: "info.circle")
                        .font(.subheadline)
                }
            }
            if !model.lowConfidence.isEmpty {
                Section {
                    Label("Values marked low confidence are rough estimates from photos. For better size advice, measure them with a tape and tap to correct.",
                          systemImage: "ruler")
                        .font(.subheadline)
                }
            }
            Section {
                ForEach(MeasurementReviewModel.order, id: \.self) { d in
                    Button { editing = d } label: { row(d) }
                        .foregroundStyle(.primary)
                }
            } footer: {
                Text("Photo-based values are estimates. Tap any value to replace it with your own measurement.")
            }
        }
        .navigationTitle("Your measurements")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Theme.Spacing.s) {
                if !model.missingEssentials.isEmpty {
                    Text("Without chest and waist we can't recommend sizes yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Save measurements", action: save)
                    .buttonStyle(.primary)
                    .disabled(!model.canSave)
            }
            .padding(Theme.Spacing.m)
            .background(.bar)
        }
        .sheet(item: $editing) { d in
            NavigationStack {
                MeasurementEditor(dimension: d, current: model.value(d)) { cm in
                    try model.setManual(d, cm: cm)
                } onClear: {
                    model.clear(d)
                }
            }
            .presentationDetents([.medium])
        }
        .alert("Couldn't save", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private func row(_ d: BodyDimension) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.title)
                if let v = model.value(d) {
                    Text(v.source == .scan ? v.confidence.title : v.source.title)
                        .font(.caption)
                        .foregroundStyle((v.confidence == .low && v.source == .scan) || v.source == .estimated ? .orange : .secondary)
                }
            }
            Spacer()
            if let v = model.value(d) {
                Text(v.formatted)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("Add")
                    .foregroundStyle(.tint)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func save() {
        do {
            modelContext.insert(try StoredBodyProfile(profile: model.finalizedProfile()))
            try modelContext.save()
            onSaved()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

extension BodyDimension: Identifiable {
    public var id: String { rawValue }
}

extension MeasuredValue {
    /// "98 cm" for measured values, "98 ± 4 cm" for estimates.
    var formatted: String {
        let value = cm.formatted(.number.precision(.fractionLength(0...1)))
        if source == .scan || source == .estimated, uncertaintyCm >= 0.5 {
            let u = uncertaintyCm.formatted(.number.precision(.fractionLength(0)))
            return "\(value) ± \(u) cm"
        }
        return "\(value) cm"
    }
}

private struct MeasurementEditor: View {
    let dimension: BodyDimension
    let current: MeasuredValue?
    let onSave: (Double) throws -> Void
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Value", text: $text)
                        .keyboardType(.decimalPad)
                        .focused($focused)
                    Text("cm").foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text(dimension.howToMeasure)
            }
            if current != nil, dimension != .height {
                Button("Remove value", role: .destructive) {
                    onClear()
                    dismiss()
                }
            }
        }
        .navigationTitle(dimension.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
        }
        .onAppear {
            if let current { text = current.cm.formatted(.number.precision(.fractionLength(0...1))) }
            focused = true
        }
    }

    private func save() {
        guard let cm = Double(text.replacingOccurrences(of: ",", with: ".")) else {
            error = String(localized: "Enter a number.")
            return
        }
        do {
            try onSave(cm)
            dismiss()
        } catch let MeasurementReviewModel.EditError.outOfRange(range) {
            error = String(localized: "Enter a value between \(Int(range.lowerBound)) and \(Int(range.upperBound)) cm.")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
