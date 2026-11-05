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
    @State private var showQuickCheck = false
    @State private var quickCheckBarcode: String?
    /// A link is on the clipboard (from the share sheet's fallback, or copied in a store
    /// app): offered with the system paste button, which reads it without a prompt.
    @State private var clipboardHasLink = false
    @Environment(\.scenePhase) private var scenePhase

    @Environment(AppContainer.self) private var container
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
            VStack(spacing: Theme.Spacing.l) {
                linkCard
                HStack(alignment: .top, spacing: Theme.Spacing.m) {
                    barcodeTile
                    photoTile
                    quickTile
                }
                statusMessages
                safariTip
            }
            .padding(Theme.Spacing.m)
        }
        .background(Theme.screenBackground)
        .navigationTitle("Scan a garment")
        .navigationDestination(item: $route) { GarmentDraftView(draft: $0.draft, autoAnalyze: $0.autoAnalyze) }
        .fullScreenCover(isPresented: $showBarcode) { barcodeSheet }
        .sheet(isPresented: $showQuickCheck) {
            QuickCheckSheet(barcode: quickCheckBarcode) { draft in
                draft.fillStandardChart(fallbackAudience: profileAudience)
                open(draft, autoAnalyze: true)
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await readPhoto(item) }
        }
        // Not `.task(id:)`: clearing the pending link changes the id, which would cancel
        // the very load it started (the shared link then showed a "cancelled" warning).
        .onAppear {
            checkSharedLink()
            clipboardHasLink = UIPasteboard.general.hasURLs
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { clipboardHasLink = UIPasteboard.general.hasURLs }
        }
        .onChange(of: container.pendingProductLink) { _, _ in checkSharedLink() }
    }

    // MARK: Cards

    /// The one place to start: paste or type a link; a copied link is a single tap.
    private var linkCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Will it fit you?")
                .font(.system(.title2, design: .rounded, weight: .bold))
            Text("Paste the link of any garment from any store.")
                .font(.subheadline)
                .opacity(0.85)
            if clipboardHasLink, linkText.isEmpty, !loadingLink {
                PasteButton(payloadType: String.self) { strings in
                    guard let s = strings.first else { return }
                    clipboardHasLink = false
                    linkText = s
                    Task { await loadLink() }
                }
                .buttonBorderShape(.capsule)
                .tint(.white)
                .foregroundStyle(Theme.plum)
            }
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("https://…", text: $linkText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await loadLink() } }
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button {
                Task { await loadLink() }
            } label: {
                Group {
                    if loadingLink {
                        HStack { ProgressView().tint(Theme.plum); Text("Reading the product…") }
                    } else {
                        Text("Check the fit")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(Theme.plum)
                .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(linkText.isEmpty || loadingLink)
            .opacity(linkText.isEmpty ? 0.75 : 1)
            if let linkError {
                Label(linkError, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                Button("Continue with this link") {
                    var info = ProductInfo()
                    info.pageURL = failedLinkURL
                    open(GarmentDraft(info: info))
                }
                .font(.subheadline.weight(.semibold))
                .disabled(failedLinkURL == nil)
            }
        }
        .foregroundStyle(.white)
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Theme.berry.opacity(0.3), radius: 18, y: 10)
    }

    private var quickTile: some View {
        Button {
            quickCheckBarcode = nil
            showQuickCheck = true
        } label: {
            tile("Quick check", symbol: "bolt.fill", busy: false)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }

    /// Even simpler: the Safari extension sizes garments while browsing.
    private var safariTip: some View {
        NavigationLink {
            ShoppingMemoryView()
        } label: {
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: "safari.fill").font(.title2).foregroundStyle(Theme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No pasting with Safari").font(.subheadline.weight(.semibold))
                    Text("Turn on the WearIQ extension and your size shows on every clothing page.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(Theme.Spacing.m)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// A round option under the link card.
    private func tile(_ title: LocalizedStringKey, symbol: String, busy: Bool) -> some View {
        VStack(spacing: Theme.Spacing.s) {
            ZStack {
                Circle().fill(Theme.cardBackground).frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
                if busy { ProgressView() } else { Image(systemName: symbol).font(.title2) }
            }
            Text(title).font(.footnote.weight(.medium)).multilineTextAlignment(.center).foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
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
                tile("Barcode", symbol: "barcode.viewfinder", busy: lookingUpBarcode)
            }
            .buttonStyle(.pressable)
            .foregroundStyle(.tint)
        }
    }

    private var photoTile: some View {
        PhotosPicker(selection: $photoItem, matching: .images) {
            tile("Chart photo", symbol: "text.viewfinder", busy: readingPhoto)
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

    /// A link shared from a store app: checked like a pasted one, straight away.
    private func checkSharedLink() {
        guard let link = container.pendingProductLink, !loadingLink else { return }
        container.pendingProductLink = nil
        route = nil
        linkText = link.absoluteString
        Task { await loadLink(retries: 1) }
    }

    /// `retries`: a shared link arrives while the app is still waking up, when the first
    /// request can fail on a network that isn't up yet; it is tried again before warning.
    private func loadLink(retries: Int = 0) async {
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
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            if retries > 0 {
                try? await Task.sleep(for: .seconds(1.5))
                loadingLink = false
                return await loadLink(retries: retries - 1)
            }
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
            info.audience = name.flatMap(GarmentClassifier.audience(from:))
        }
        guard info.category != nil else {
            // Unknown product: ask only what's on the tag instead of showing an empty form.
            quickCheckBarcode = code
            showQuickCheck = true
            return
        }
        let draft = GarmentDraft(info: info)
        draft.fillStandardChart(fallbackAudience: profileAudience)
        open(draft, autoAnalyze: true)
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
