import FitEngine
import PhotosUI
import ProductMeasurementParser
import SwiftUI
import WearIQCore

struct GarmentDraftView: View {
    @Environment(AppContainer.self) private var container
    @Bindable var draft: GarmentDraft
    var autoAnalyze = false
    @AppStorage("fitPreference") private var preference: FitPreference = .asDesigned
    @State private var didAutoAnalyze = false
    @State private var showTable = false

    @State private var photoItem: PhotosPickerItem?
    @State private var readingPhoto = false
    @State private var errorMessage: String?
    @State private var newSizeLabel = ""
    @State private var result: ResultRoute?
    @State private var showQuotaLimit = false
    @State private var showNeedsProfile = false

    struct ResultRoute: Hashable, Identifiable {
        let id = UUID()
        let analysis: FitAnalysis
        let saved: Bool
    }

    var body: some View {
        Form {
            productSection
            if draft.chartSource != nil && draft.spec != nil && !showTable {
                // The chart was found automatically: show what was found, keep the table one tap away.
                chartSummarySection
            } else {
                garmentSection
                chartSection
                if draft.category != nil { sizeSections }
                addSizeSection
                issuesSection
            }
        }
        .task {
            guard autoAnalyze, !didAutoAnalyze, draft.spec != nil else { return }
            didAutoAnalyze = true
            analyze()
        }
        .navigationTitle("Garment details")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { analyzeBar }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await readChart(from: item) }
        }
        .navigationDestination(item: $result) { route in
            FitResultView(productName: draft.info.name, brand: draft.info.brand, imageURL: draft.info.imageURL,
                          pageURL: draft.info.pageURL, analysis: route.analysis, isSaved: route.saved,
                          category: draft.category, fitStyle: draft.fitStyle, chartNote: chartNote)
                // Ads only ever appear after a result, never before a scan.
                .onDisappear { container.ads.showInterstitialIfDue(isPremium: container.isPremium) }
        }
        .sheet(isPresented: $showQuotaLimit) {
            PaywallView(reason: "You've used today's free scans. They renew tomorrow, or go unlimited with Premium.")
        }
        .alert("Body profile needed", isPresented: $showNeedsProfile) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Scan your body or enter your measurements in the Profile tab first.")
        }
        .alert("Something went wrong", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Sections

    /// Shown with the result so the user knows what the advice is based on.
    private var chartNote: String? {
        switch draft.chartSource {
        case .store: String(localized: "Based on the store's size chart.")
        case .photo: String(localized: "Based on the size chart from your photo.")
        case .standard:
            if let size = draft.chartWarnings.lazy.compactMap({ w -> String? in
                if case let .anchoredToModel(size) = w { return size } else { return nil }
            }).first {
                String(localized: "The store publishes no size chart. Typical measurements were matched to the model, who wears \(size).")
            } else {
                String(localized: "The store publishes no size chart, so this uses typical measurements for these sizes. Brands vary, so treat it as a guide.")
            }
        case nil: nil
        }
    }

    private var chartSummarySection: some View {
        Section {
            if let category = draft.category { LabeledContent("Category", value: category.title) }
            LabeledContent("Fit", value: draft.fitStyle.title)
            LabeledContent("Sizes", value: draft.sizes.map(\.label).joined(separator: ", "))
            if let note = chartNote {
                Label(note, systemImage: draft.chartSource == .standard ? "info.circle" : "checkmark.seal")
                    .font(.footnote)
                    .foregroundStyle(draft.chartSource == .standard ? .orange : .secondary)
            }
            Button("Show and edit the size chart") { showTable = true }
        } header: {
            Text("Size chart found")
        }
    }

    private var productSection: some View {
        Section("Product") {
            TextField("Product name", text: Binding(get: { draft.info.name ?? "" }, set: { draft.info.name = $0.isEmpty ? nil : $0 }))
            TextField("Brand", text: Binding(get: { draft.info.brand ?? "" }, set: { draft.info.brand = $0.isEmpty ? nil : $0 }))
            if let gtin = draft.info.gtin {
                LabeledContent("Barcode", value: gtin)
            }
        }
    }

    private var garmentSection: some View {
        Section {
            Picker("Category", selection: $draft.category) {
                Text("Choose").tag(GarmentCategory?.none)
                ForEach(GarmentCategory.allCases, id: \.self) { Text($0.title).tag(GarmentCategory?.some($0)) }
            }
            Picker("Fit", selection: $draft.fitStyle) {
                ForEach(FitStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Stretch", selection: $draft.stretch) {
                ForEach(FabricStretch.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Fabric thickness", selection: $draft.thickness) {
                ForEach(FabricThickness.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Garment")
        }
    }

    private var chartSection: some View {
        Section {
            Picker("The size chart shows", selection: $draft.chartKind) {
                Text("Choose").tag(SizeChartKind?.none)
                Text("Body measurements").tag(SizeChartKind?.some(.body))
                Text("Garment measurements").tag(SizeChartKind?.some(.garment))
            }
            if draft.chartSections.count > 1 {
                Picker("Table", selection: Binding(get: { draft.selectedSection ?? 0 }, set: { draft.selectSection($0) })) {
                    ForEach(Array(draft.chartSections.enumerated()), id: \.offset) { i, section in
                        Text(section.title ?? String(localized: "Table \(i + 1)")).tag(i)
                    }
                }
            }
            PhotosPicker(selection: $photoItem, matching: .images) {
                if readingPhoto {
                    HStack { ProgressView(); Text("Reading size chart…") }
                } else {
                    Label("Read size chart from a photo", systemImage: "text.viewfinder")
                }
            }
            .disabled(readingPhoto)
            ForEach(Array(draft.chartWarnings.enumerated()), id: \.offset) { _, warning in
                if let text = warning.message {
                    Label(text, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Size chart")
        }
    }

    @ViewBuilder
    private var sizeSections: some View {
        if let category = draft.category {
            ForEach(Array(draft.sizes.enumerated()), id: \.element.label) { index, size in
                Section {
                    ForEach(GarmentDraft.dimensions(for: category), id: \.self) { dim in
                        HStack {
                            Text(dim.title)
                            Spacer()
                            TextField("—", value: Binding<Double?>(
                                get: { draft.sizes.indices.contains(index) ? draft.sizes[index].values[dim]?.cm : nil },
                                set: { draft.setValue($0, size: index, dimension: dim) }
                            ), format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 90)
                            Text("cm").foregroundStyle(.secondary)
                        }
                    }
                    Button("Remove size \(size.label)", role: .destructive) { draft.removeSize(at: index) }
                } header: {
                    Text("Size \(size.label)")
                }
            }
        }
    }

    private var addSizeSection: some View {
        Section {
            HStack {
                TextField("New size, e.g. M or 32", text: $newSizeLabel)
                    .textInputAutocapitalization(.characters)
                Button("Add") {
                    draft.addSize(label: newSizeLabel)
                    newSizeLabel = ""
                }
                .disabled(newSizeLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } footer: {
            if draft.sizes.isEmpty, !draft.info.availableSizes.isEmpty {
                Button("Add sizes from the product page") {
                    draft.info.availableSizes.forEach { draft.addSize(label: $0) }
                }
            }
        }
    }

    @ViewBuilder
    private var issuesSection: some View {
        let issues = draft.issues
        if !issues.isEmpty {
            Section("Still needed") {
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    Label(issue.message, systemImage: "circle.dashed")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var analyzeBar: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Button("Analyze fit", action: analyze)
                .buttonStyle(.primary)
                .disabled(draft.spec == nil)
            if !container.isPremium {
                Text("\(container.quota.remaining()) free scans left today")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Spacing.m)
        .background(.bar)
    }

    // MARK: Actions

    private func readChart(from item: PhotosPickerItem) async {
        readingPhoto = true
        defer { readingPhoto = false; photoItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                throw OCRError.unreadableImage
            }
            draft.apply(try await OCRService().readSections(from: image, fit: draft.info.fitStyle))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func analyze() {
        do {
            switch try container.analysisCoordinator().run(draft, preference: preference) {
            case let .analyzed(saved):
                container.ads.analysisCompleted()
                if let analysis = saved.analysis { result = ResultRoute(analysis: analysis, saved: true) }
            case let .insufficientData(analysis):
                result = ResultRoute(analysis: analysis, saved: false)
            case .needsBodyProfile:
                showNeedsProfile = true
            case .quotaExhausted:
                showQuotaLimit = true
            case .invalidDraft:
                break // button is disabled in this state
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Display names

extension GarmentCategory {
    var title: String {
        switch self {
        case .shirt: String(localized: "Shirt")
        case .tshirt: String(localized: "T-shirt")
        case .jacket: String(localized: "Jacket")
        case .pants: String(localized: "Trousers")
        }
    }
}

extension FitStyle {
    var title: String {
        switch self {
        case .slim: String(localized: "Slim fit")
        case .regular: String(localized: "Regular fit")
        case .relaxed: String(localized: "Relaxed fit")
        case .oversized: String(localized: "Oversized")
        }
    }
}

extension FabricStretch {
    var title: String {
        switch self {
        case .none: String(localized: "No stretch")
        case .low: String(localized: "A little stretch")
        case .medium: String(localized: "Stretchy")
        case .high: String(localized: "Very stretchy")
        }
    }
}

extension FabricThickness {
    var title: String {
        switch self {
        case .thin: String(localized: "Thin")
        case .medium: String(localized: "Medium")
        case .thick: String(localized: "Thick")
        }
    }
}

extension GarmentDimension {
    var title: String {
        switch self {
        case .shoulderWidth: String(localized: "Shoulder width")
        case .sleeveLength: String(localized: "Sleeve length")
        case .chest: String(localized: "Chest")
        case .waist: String(localized: "Waist")
        case .hip: String(localized: "Hip")
        case .thigh: String(localized: "Thigh")
        case .bodyLength: String(localized: "Length")
        case .inseam: String(localized: "Inseam")
        case .outseam: String(localized: "Outseam")
        }
    }
}

extension GarmentDraft.Issue {
    var message: String {
        switch self {
        case .missingCategory: String(localized: "Choose the garment category.")
        case .missingChartKind: String(localized: "Say whether the chart shows body or garment measurements.")
        case .noSizes: String(localized: "Add at least one size with its measurements.")
        case let .missingCriticalMeasurement(dim): String(localized: "Add the \(dim.title.lowercased()) measurement for at least one size.")
        }
    }
}

extension ParsedSizeChart.Warning {
    var message: String? {
        switch self {
        case .unitAssumedCentimetres: String(localized: "No unit was found; values were read as centimetres.")
        case .chartKindUnknown: nil // covered by the "size chart shows" picker
        case let .halfMeasurementsDoubled(dim): String(localized: "\(dim.title) was given as a half (flat) measurement and has been doubled.")
        case let .rowValueCountMismatch(label): String(localized: "Couldn't read the row \"\(label)\". Please enter it manually.")
        case let .unrecognisedRow(label): String(localized: "Ignored the row \"\(label)\".")
        case .standardChartUsed, .anchoredToModel: nil // explained by the chart note
        case .chartKindGuessed: nil  // the picker above shows the choice
        case let .implausibleColumnDropped(dim): String(localized: "The chart's \"\(dim.title.lowercased())\" values can't be that measurement, so they were left out.")
        }
    }
}
