import PhotosUI
import ProductMeasurementParser
import SwiftUI
import Vision
import WearIQCore

/// Measures a garment the user owns from one photo: laid flat on the floor or a table,
/// collar or waistband towards the top of the photo, with a sheet of A4 paper beside it
/// for scale. The paper's corners give the scale and undo the camera's angle; the
/// garment's outline comes from Vision's foreground mask. Everything runs on the phone.
struct FlatLayMeasureView: View {
    let category: GarmentCategory
    let onMeasured: ([GarmentDimension: Double]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var item: PhotosPickerItem?
    @State private var showCamera = false
    @State private var working = false
    @State private var result: [GarmentDimension: Double]?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Lay it flat, smoothed out, collar or waistband towards the top of the photo.", systemImage: "tshirt")
                    Label("Put a sheet of A4 paper next to it, not touching.", systemImage: "doc")
                    Label("Take the photo from above, the whole garment and the paper in it.", systemImage: "camera")
                } header: {
                    Text("How to")
                }
                Section {
                    Button { showCamera = true } label: { Label("Take a photo", systemImage: "camera.fill") }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    PhotosPicker(selection: $item, matching: .images) {
                        Label("Choose a photo", systemImage: "photo.on.rectangle")
                    }
                }
                if working {
                    Section { HStack { ProgressView(); Text("Measuring…") } }
                }
                if let failure {
                    Section { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                if let result {
                    Section {
                        ForEach(GarmentDimension.allCases.filter { result[$0] != nil }, id: \.self) { d in
                            LabeledContent(d.title, value: "\(Int(result[d]!.rounded())) cm")
                        }
                        Button("Use these measurements") {
                            onMeasured(result)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    } header: {
                        Text("Measured")
                    } footer: {
                        Text("Girths are double the flat width, like size charts. Check them; you can still edit each one.")
                    }
                }
            }
            .navigationTitle("Measure from a photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: item) { _, item in
                Task {
                    guard let data = try? await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
                    await measure(image)
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { image in Task { await measure(image) } }
                    .ignoresSafeArea()
            }
        }
    }

    private func measure(_ image: UIImage) async {
        working = true
        failure = nil
        result = nil
        let category = category
        let outcome = await Task.detached(priority: .userInitiated) { FlatLayReader.read(image, category: category) }.value
        working = false
        switch outcome {
        case let .success(values): result = values
        case let .failure(problem): failure = problem.message
        }
    }
}

/// The Vision side of a flat-lay measurement: the paper's corners and the garment's mask.
enum FlatLayReader {
    enum Problem: Error {
        case noPaper, noGarment, notMeasurable

        var message: String {
            switch self {
            case .noPaper: String(localized: "Couldn't find the A4 sheet. Put it flat beside the garment, all four corners in the photo.")
            case .noGarment: String(localized: "Couldn't make out the garment. A plain floor or table that differs in colour helps.")
            case .notMeasurable: String(localized: "The outline doesn't look like this kind of garment laid flat. Smooth it out, collar or waistband at the top.")
            }
        }
    }

    static func read(_ image: UIImage, category: GarmentCategory) -> Result<[GarmentDimension: Double], Problem> {
        guard let cg = image.normalizedCGImage else { return .failure(.noGarment) }
        let width = Double(cg.width), height = Double(cg.height)
        // The paper: the largest rectangle of A4's proportions.
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 8
        rectangles.minimumAspectRatio = 0.55
        rectangles.maximumAspectRatio = 0.85
        rectangles.minimumSize = 0.08
        rectangles.quadratureTolerance = 25
        let handler = VNImageRequestHandler(cgImage: cg)
        try? handler.perform([rectangles])
        guard let paper = (rectangles.results ?? []).max(by: { area($0) < area($1) }) else { return .failure(.noPaper) }
        // Vision's points are normalised with the origin at the bottom left.
        func px(_ p: CGPoint) -> FlatLay.Point { FlatLay.Point(Double(p.x) * width, (1 - Double(p.y)) * height) }
        let corners = [px(paper.topLeft), px(paper.topRight), px(paper.bottomRight), px(paper.bottomLeft)]

        // The garment: every foreground instance (the paper is dropped by the measuring).
        let foreground = VNGenerateForegroundInstanceMaskRequest()
        try? handler.perform([foreground])
        guard let observation = foreground.results?.first,
              let buffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        else { return .failure(.noGarment) }
        guard let mask = Self.mask(buffer) else { return .failure(.noGarment) }
        let sx = Double(mask.width) / width, sy = Double(mask.height) / height
        let maskCorners = corners.map { FlatLay.Point($0.x * sx, $0.y * sy) }
        guard let map = FlatLay.tableMap(paperCorners: maskCorners, imageWidth: Double(mask.width), imageHeight: Double(mask.height)),
              let grid = FlatLay.rectify(mask, map: map, paperCorners: maskCorners) else { return .failure(.noGarment) }
        let values = FlatLay.measure(grid, cellCm: 0.5, category: category)
        return values.isEmpty ? .failure(.notMeasurable) : .success(values)
    }

    private static func area(_ r: VNRectangleObservation) -> CGFloat { r.boundingBox.width * r.boundingBox.height }

    /// A one-channel float mask as booleans, halved in size for speed.
    private static func mask(_ buffer: CVPixelBuffer) -> FlatLay.Mask? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let step = 2
        let ow = w / step, oh = h / step
        var pixels = [Bool](repeating: false, count: ow * oh)
        for y in 0..<oh {
            let line = base.advanced(by: y * step * row)
            for x in 0..<ow {
                let value: Float = format == kCVPixelFormatType_OneComponent8
                    ? Float(line.load(fromByteOffset: x * step, as: UInt8.self)) / 255
                    : line.load(fromByteOffset: x * step * 4, as: Float32.self)
                pixels[y * ow + x] = value > 0.5
            }
        }
        return FlatLay.Mask(width: ow, height: oh, pixels: pixels)
    }
}

extension UIImage {
    /// The image drawn upright, so pixel rows match what the user saw.
    var normalizedCGImage: CGImage? {
        if imageOrientation == .up, let cgImage { return cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw(in: CGRect(origin: .zero, size: size)) }.cgImage
    }
}

/// The system camera, for one photo.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
