import FitEngine
import OutfitRecommendationEngine
import PhotosUI
import SwiftData
import SwiftUI
import WearIQCore

/// Adds or edits a wardrobe item. Pass `existing` to edit.
struct WardrobeItemEditor: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let existing: WardrobeEntry?
    @State private var name: String
    @State private var brand: String
    @State private var size: String
    @State private var category: WardrobeCategory
    @State private var color: ColorFamily
    @State private var fitStyle: FitStyle?
    @State private var seasons: Set<Season>
    @State private var styles: Set<StyleTag>
    @State private var photo: Data?
    private let prefillImageURL: URL?
    @State private var photoItem: PhotosPickerItem?
    /// Typed measurements of the garment, keyed by dimension.
    @State private var measurementText: [GarmentDimension: String]
    private let fitScore: Double?

    init(existing: WardrobeEntry? = nil, prefill: Prefill? = nil) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? prefill?.name ?? "")
        _brand = State(initialValue: existing?.brand ?? prefill?.brand ?? "")
        _size = State(initialValue: existing?.size ?? prefill?.size ?? "")
        _category = State(initialValue: existing?.category ?? prefill?.category ?? .top)
        _color = State(initialValue: existing?.color ?? .black)
        _fitStyle = State(initialValue: existing?.fitStyle ?? prefill?.fitStyle)
        _seasons = State(initialValue: existing?.seasons ?? Set(Season.allCases))
        _styles = State(initialValue: existing?.styles ?? [.casual])
        _photo = State(initialValue: existing?.photo)
        fitScore = existing?.fitScore ?? prefill?.fitScore
        prefillImageURL = existing == nil ? prefill?.imageURL : nil
        let known = existing?.measurements ?? prefill?.measurements ?? [:]
        _measurementText = State(initialValue: known.mapValues { String(format: "%.0f", $0) })
    }

    /// Values carried over from a fit analysis ("Add to wardrobe").
    struct Prefill {
        var name: String?
        var brand: String?
        var size: String?
        var category: WardrobeCategory?
        var fitStyle: FitStyle?
        var fitScore: Double?
        /// Product photo from the store page; downloaded as the item's photo.
        var imageURL: URL?
        /// The size's garment measurements, when the store's chart lists them.
        var measurements: [GarmentDimension: Double]?
    }

    /// The measurements that matter for comparing garments of this kind.
    private var measurable: [GarmentDimension] {
        switch category {
        case .bottom: [.waist, .hip, .inseam, .outseam]
        default: [.chest, .shoulderWidth, .bodyLength, .sleeveLength]
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        if let photo, let image = UIImage(data: photo) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Add photo", systemImage: "camera")
                        }
                    }
                    TextField("Name", text: $name)
                    TextField("Brand", text: $brand)
                    TextField("Size", text: $size)
                }
                Section {
                    Picker("Category", selection: $category) {
                        ForEach(WardrobeCategory.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Colour", selection: $color) {
                        ForEach(ColorFamily.allCases, id: \.self) { c in
                            Label { Text(c.title) } icon: { Circle().fill(c.swatch).frame(width: 14, height: 14) }.tag(c)
                        }
                    }
                    Picker("Fit", selection: $fitStyle) {
                        Text("Not specified").tag(FitStyle?.none)
                        ForEach(FitStyle.allCases, id: \.self) { Text($0.title).tag(FitStyle?.some($0)) }
                    }
                }
                Section {
                    ForEach(measurable, id: \.self) { d in
                        HStack {
                            Text(d.title)
                            Spacer()
                            TextField("cm", text: Binding(get: { measurementText[d] ?? "" }, set: { measurementText[d] = $0 }))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                        }
                    }
                } header: {
                    Text("Its measurements (optional)")
                } footer: {
                    Text("Lay it flat and measure. Chest, waist and hip: double the flat width. New products are compared with clothes you like.")
                }
                Section("Seasons") {
                    ForEach(Season.allCases, id: \.self) { s in
                        Toggle(s.title, isOn: binding(for: s, in: $seasons))
                    }
                }
                Section("Style") {
                    ForEach(StyleTag.allCases, id: \.self) { s in
                        Toggle(s.title, isOn: binding(for: s, in: $styles))
                    }
                }
            }
            .navigationTitle(existing == nil ? Text("Add item") : Text("Edit item"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || seasons.isEmpty || styles.isEmpty)
                }
            }
            .onChange(of: photoItem) { _, item in
                Task { photo = try? await item?.loadTransferable(type: Data.self).flatMap(Self.downscaled) }
            }
            .task {
                // Use the store's product photo so the wardrobe shows the real garment.
                guard photo == nil, let url = prefillImageURL,
                      let (data, _) = try? await URLSession.shared.data(from: url) else { return }
                photo = Self.downscaled(data)
            }
        }
    }

    private func binding<T: Hashable>(for value: T, in set: Binding<Set<T>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(value) },
                set: { on in if on { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) } })
    }

    private func save() {
        let entry = existing ?? WardrobeEntry(name: name, category: category, color: color, fitScore: fitScore)
        entry.name = name.trimmingCharacters(in: .whitespaces)
        entry.brand = brand.isEmpty ? nil : brand
        entry.size = size.isEmpty ? nil : size
        entry.category = category
        entry.color = color
        entry.fitStyle = fitStyle
        entry.seasons = seasons
        entry.styles = styles
        entry.photo = photo
        entry.measurements = measurementText.compactMapValues { text in
            Double(text.replacingOccurrences(of: ",", with: ".")).flatMap { $0 > 0 ? $0 : nil }
        }
        if existing == nil { modelContext.insert(entry) }
        try? modelContext.save()
        dismiss()
    }

    /// Wardrobe photos don't need full camera resolution.
    private static func downscaled(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1024
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: 0.8)
    }
}
