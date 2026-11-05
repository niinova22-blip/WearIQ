import AvatarEngine
import RealityKit
import SceneKit
import SwiftUI
import UIKit
import Vision

/// Holds the scene's view so the screen can take a picture of it (SceneKit or RealityKit).
final class AvatarSnapshotter {
    weak var view: SCNView?
    weak var arView: ARView?

    @MainActor func image() async -> UIImage? {
        if let arView {
            return await withCheckedContinuation { done in arView.snapshot(saveToHDR: false) { done.resume(returning: $0) } }
        }
        return view?.snapshot()
    }
}

struct ShareableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// The system share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A card to share the look: the avatar as seen, the garment's name and the size's
/// verdict. No measurement goes on it.
enum AvatarShareCard {
    @MainActor
    static func render(avatar: UIImage, productName: String?, size: String, headline: String) -> UIImage {
        let card = VStack(alignment: .leading, spacing: 12) {
            Image(uiImage: avatar)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(height: 520)
                .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            if let productName {
                Text(productName).font(.title3.weight(.semibold)).lineLimit(2)
            }
            Text(headline).font(.title2.bold())
            HStack {
                Image(systemName: "tshirt.fill")
                Text(verbatim: "WearIQ").font(.headline)
                Spacer()
                Text("Checked on my 3D avatar").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Color(uiColor: .systemBackground))
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        return renderer.uiImage ?? avatar
    }
}

/// The garment's main colour from its product photo: pixels of the model's torso (a top)
/// or legs (trousers, skirts) found with Vision's body pose; the middle of the photo when
/// no one is in it (a flat product shot).
enum GarmentColorReader {
    static func color(of image: UIImage, bottom: Bool) -> UIColor? {
        guard let cg = image.normalizedCGImage, let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data), cg.bitsPerPixel == 32 else { return nil }
        let width = cg.width, height = cg.height, row = cg.bytesPerRow
        let region = sampleRegion(cg, bottom: bottom)
            ?? CGRect(x: 0.35, y: bottom ? 0.55 : 0.3, width: 0.3, height: 0.25)
        var pixels: [GarmentColor.RGB] = []
        let x0 = Int(region.minX * CGFloat(width)), x1 = Int(region.maxX * CGFloat(width))
        let y0 = Int(region.minY * CGFloat(height)), y1 = Int(region.maxY * CGFloat(height))
        let stepX = max(1, (x1 - x0) / 60), stepY = max(1, (y1 - y0) / 60)
        let little = cg.bitmapInfo.contains(.byteOrder32Little)
        let alphaFirst = [.premultipliedFirst, .first, .noneSkipFirst].contains(cg.alphaInfo)
        for y in stride(from: max(0, y0), to: min(height, y1), by: stepY) {
            for x in stride(from: max(0, x0), to: min(width, x1), by: stepX) {
                let p = bytes + y * row + x * 4
                // Byte order in memory: BGRA/BGRX (little endian, alpha first), RGBA/RGBX, or ARGB.
                let (r, g, b) = little ? (alphaFirst ? (p[2], p[1], p[0]) : (p[3], p[2], p[1]))
                    : alphaFirst ? (p[1], p[2], p[3]) : (p[0], p[1], p[2])
                pixels.append(GarmentColor.RGB(Double(r) / 255, Double(g) / 255, Double(b) / 255))
            }
        }
        guard let result = GarmentColor.dominant(pixels) else { return nil }
        return UIColor(red: result.color.r, green: result.color.g, blue: result.color.b, alpha: 1)
    }

    /// Between the shoulders and hips (a top) or the hips and knees (a bottom), in
    /// top-left normalised coordinates, from the first person's pose.
    private static func sampleRegion(_ cg: CGImage, bottom: Bool) -> CGRect? {
        let request = VNDetectHumanBodyPoseRequest()
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        guard let pose = request.results?.first, let points = try? pose.recognizedPoints(.all) else { return nil }
        func p(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let point = points[name], point.confidence > 0.3 else { return nil }
            return CGPoint(x: point.location.x, y: 1 - point.location.y)
        }
        let joints: [CGPoint?] = bottom
            ? [p(.leftHip), p(.rightHip), p(.leftKnee), p(.rightKnee)]
            : [p(.leftShoulder), p(.rightShoulder), p(.leftHip), p(.rightHip)]
        let found = joints.compactMap { $0 }
        guard found.count == 4 else { return nil }
        let xs = found.map(\.x), ys = found.map(\.y)
        // The inner part, away from arms and background.
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        return box.insetBy(dx: box.width * 0.2, dy: box.height * 0.15)
    }
}
