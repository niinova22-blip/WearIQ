import PhotosUI
import ProductMeasurementParser
import SwiftUI

/// Entry point for identifying a garment: product link, barcode, size chart photo
/// or manual entry. Every route ends in a `GarmentDraft` the user can complete.
struct ScanEntryView: View {
    @State private var linkText = ""
    @State private var loadingLink = false
    @State private var linkError: String?
    @State private var failedLinkURL: URL?
    @State private var showBarcode = false
    @State private var photoItem: PhotosPickerItem?
    @State private var readingPhoto = false
    @State private var photoError: String?
    @State private var route: DraftRoute?

    private let productService: ProductDataServicing = ProductDataService()
    private let barcodeLookup: BarcodeLookupServicing = NoCatalogBarcodeLookup()

    struct DraftRoute: Hashable, Identifiable {
        let id = UUID()
        let draft: GarmentDraft
        static func == (a: Self, b: Self) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.m) {
                linkCard
                barcodeCard
                photoCard
                Button("Enter a size chart manually") { open(GarmentDraft()) }
                    .padding(.top, Theme.Spacing.s)
            }
            .padding(Theme.Spacing.m)
        }
        .background(Theme.screenBackground)
        .navigationTitle("Scan a garment")
        .navigationDestination(item: $route) { GarmentDraftView(draft: $0.draft) }
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
            Text("Reads the product name, sizes and size chart where the store publishes them.")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                TextField("https://…", text: $linkText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                PasteButton(payloadType: String.self) { strings in
                    if let s = strings.first { linkText = s }
                }
                .labelStyle(.iconOnly)
            }
            Button {
                Task { await loadLink() }
            } label: {
                if loadingLink { ProgressView().tint(.white) } else { Text("Read product") }
            }
            .buttonStyle(.primary)
            .disabled(linkText.isEmpty || loadingLink)
            if let linkError {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Label(linkError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("You can still continue: add a screenshot of the store's size chart or type the measurements.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Continue with this link") {
                        var info = ProductInfo()
                        info.pageURL = failedLinkURL
                        open(GarmentDraft(info: info))
                    }
                    .disabled(failedLinkURL == nil)
                }
                .font(.subheadline)
            }
        }
    }

    private var barcodeCard: some View {
        Card {
            Label("Scan a barcode", systemImage: "barcode.viewfinder").font(.headline)
            Text("Identifies the product from its EAN/UPC code. A barcode alone has no measurements.")
                .font(.subheadline).foregroundStyle(.secondary)
            if BarcodeScannerView.isAvailable {
                Button("Open barcode scanner") { showBarcode = true }
            } else {
                Text("Barcode scanning isn't available on this device or camera access is off.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var photoCard: some View {
        Card {
            Label("Read a size chart photo", systemImage: "text.viewfinder").font(.headline)
            Text("Extracts measurements from a size chart screenshot or garment label on your device.")
                .font(.subheadline).foregroundStyle(.secondary)
            PhotosPicker(selection: $photoItem, matching: .images) {
                if readingPhoto {
                    HStack { ProgressView(); Text("Reading size chart…") }
                } else {
                    Text("Choose a photo")
                }
            }
            .disabled(readingPhoto)
            if let photoError {
                Label(photoError, systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.orange)
            }
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

    private func open(_ draft: GarmentDraft) {
        route = DraftRoute(draft: draft)
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
            open(GarmentDraft(info: try await productService.product(at: url)))
            linkText = ""
        } catch {
            failedLinkURL = url
            linkError = error.localizedDescription
        }
    }

    private func openBarcode(_ code: String) async {
        var info = ProductInfo()
        info.gtin = code
        if case let .found(name, brand, imageURL) = await barcodeLookup.product(forGTIN: code) {
            info.name = name
            info.brand = brand
            info.imageURL = imageURL
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
            let chart = try await OCRService().readSizeChart(from: image)
            let draft = GarmentDraft()
            draft.apply(chart)
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
