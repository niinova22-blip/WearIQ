import PhotosUI
import ProductMeasurementParser
import SwiftUI
import WearIQCore

/// Entry point for identifying a garment: product link, barcode, size chart photo
/// or manual entry. Every route ends in a `GarmentDraft` the user can complete.
struct ScanEntryView: View {
    @State private var linkText = ""
    @State private var loadingLink = false
    @State private var linkError: String?
    @State private var failedLinkURL: URL?
    @State private var showBarcode = false
    @State private var barcodeError: String?
    @State private var lookingUpBarcode = false
    @State private var photoItem: PhotosPickerItem?
    @State private var readingPhoto = false
    @State private var photoError: String?
    @State private var route: DraftRoute?

    private let productService: ProductDataServicing = ProductDataService()
    private let barcodeLookup: BarcodeLookupServicing = UPCItemDBLookup()

    struct DraftRoute: Hashable, Identifiable {
        let id = UUID()
        let draft: GarmentDraft
        var autoAnalyze = false
        static func == (a: Self, b: Self) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.m) {
                linkCard
                HStack(spacing: Theme.Spacing.m) {
                    barcodeTile
                    photoTile
                }
                statusMessages
                Button("Enter a size chart manually") { open(GarmentDraft()) }
                    .font(.subheadline)
                    .padding(.top, Theme.Spacing.s)
            }
            .padding(Theme.Spacing.m)
        }
        .background(Theme.screenBackground)
        .navigationTitle("Scan a garment")
        .navigationDestination(item: $route) { GarmentDraftView(draft: $0.draft, autoAnalyze: $0.autoAnalyze) }
        .fullScreenCover(isPresented: $showBarcode) { barcodeSheet }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await readPhoto(item) }
        }
    }

    // MARK: Cards

    private var linkCard: some View {
        Card {
            Label("Paste a product link", systemImage: "link").font(.headline)
            HStack {
                TextField("https://…", text: $linkText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await loadLink() } }
                PasteButton(payloadType: String.self) { strings in
                    if let s = strings.first {
                        linkText = s
                        Task { await loadLink() }
                    }
                }
                .labelStyle(.iconOnly)
            }
            Button {
                Task { await loadLink() }
            } label: {
                if loadingLink {
                    HStack { ProgressView().tint(.white); Text("Reading the product…") }
                } else {
                    Text("Check the fit")
                }
            }
            .buttonStyle(.primary)
            .disabled(linkText.isEmpty || loadingLink)
            if let linkError {
                Label(linkError, systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.orange)
                Button("Continue with this link") {
                    var info = ProductInfo()
                    info.pageURL = failedLinkURL
                    open(GarmentDraft(info: info))
                }
                .font(.subheadline)
                .disabled(failedLinkURL == nil)
            }
        }
    }

    private func tile(_ title: LocalizedStringKey, symbol: String, busy: Bool) -> some View {
        VStack(spacing: Theme.Spacing.s) {
            if busy { ProgressView() } else { Image(systemName: symbol).font(.title2) }
            Text(title).font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 88)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var barcodeTile: some View {
        if BarcodeScannerView.isSupported {
            Button {
                Task {
                    if await BarcodeScannerView.requestAccess() {
                        showBarcode = true
                    } else {
                        barcodeError = String(localized: "Camera access is off. Allow it in Settings to scan barcodes.")
                    }
                }
            } label: {
                tile("Scan a barcode", symbol: "barcode.viewfinder", busy: lookingUpBarcode)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
    }

    private var photoTile: some View {
        PhotosPicker(selection: $photoItem, matching: .images) {
            tile("Size chart photo", symbol: "text.viewfinder", busy: readingPhoto)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .disabled(readingPhoto)
    }

    @ViewBuilder
    private var statusMessages: some View {
        ForEach([barcodeError, photoError].compactMap { $0 }, id: \.self) { message in
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline).foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var barcodeSheet: some View {
        NavigationStack {
            BarcodeScannerView { code in
                showBarcode = false
                Task { await openBarcode(code) }
            }
            .ignoresSafeArea()
            .navigationTitle("Scan a barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showBarcode = false } }
            }
        }
    }

    // MARK: Actions

    /// With `autoAnalyze` the fit analysis runs as soon as the chart is complete, so a
    /// pasted link goes straight to the result; the draft stays one tap back for edits.
    private func open(_ draft: GarmentDraft, autoAnalyze: Bool = false) {
        route = DraftRoute(draft: draft, autoAnalyze: autoAnalyze)
    }

    private var profileAudience: GarmentAudience? {
        switch BodySex(rawValue: UserDefaults.standard.string(forKey: "bodySex") ?? "") {
        case .male: .men
        case .female: .women
        case nil: nil
        }
    }

    private func loadLink() async {
        linkError = nil
        failedLinkURL = nil
        guard let url = ProductDataService.normalizedURL(from: linkText) else {
            linkError = ProductDataError.invalidURL.localizedDescription
            return
        }
        loadingLink = true
        defer { loadingLink = false }
        do {
            let lookup = try await productService.product(at: url)
            let draft = GarmentDraft(info: lookup.info)
            if let chart = lookup.chart {
                draft.apply(chart)
            } else if !draft.fillStandardChart(fallbackAudience: profileAudience) {
                // Unknown size labels: start the table with them so only numbers are missing.
                lookup.info.availableSizes.forEach { draft.addSize(label: $0) }
            }
            open(draft, autoAnalyze: true)
            linkText = ""
        } catch {
            failedLinkURL = url
            linkError = error.localizedDescription
        }
    }

    private func openBarcode(_ code: String) async {
        barcodeError = nil
        lookingUpBarcode = true
        defer { lookingUpBarcode = false }
        var info = ProductInfo()
        info.gtin = code
        if case let .found(name, brand, imageURL) = await barcodeLookup.product(forGTIN: code) {
            info.name = name
            info.brand = brand
            info.imageURL = imageURL
            info.category = name.flatMap(GarmentClassifier.category(from:))
            info.fitStyle = name.flatMap(GarmentClassifier.fitStyle(from:))
        }
        open(GarmentDraft(info: info))
    }

    private func readPhoto(_ item: PhotosPickerItem) async {
        photoError = nil
        readingPhoto = true
        defer { readingPhoto = false; photoItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                throw OCRError.unreadableImage
            }
            let draft = GarmentDraft()
            draft.apply(try await OCRService().readSections(from: image, fit: nil), source: .photo)
            open(draft)
        } catch {
            photoError = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack { ScanEntryView() }
        .environment(AppContainer.preview())
}
