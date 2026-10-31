// swift-tools-version: 6.0
import PackageDescription

// Platform-independent engines for WearIQ. Everything here is pure Swift + Foundation
// so it can be built and tested on macOS, Linux and Windows CI as well as on iOS.
// BodyScanVision is the exception: it wraps Apple Vision and is empty elsewhere.
let package = Package(
    name: "WearIQKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WearIQCore", targets: ["WearIQCore"]),
        .library(name: "FitEngine", targets: ["FitEngine"]),
        .library(name: "BodyMeasurementEngine", targets: ["BodyMeasurementEngine"]),
        .library(name: "BodyScanVision", targets: ["BodyScanVision"]),
        .library(name: "ProductMeasurementParser", targets: ["ProductMeasurementParser"]),
        .library(name: "ScanQuota", targets: ["ScanQuota"]),
        .library(name: "OutfitRecommendationEngine", targets: ["OutfitRecommendationEngine"]),
        .library(name: "AvatarEngine", targets: ["AvatarEngine"]),
    ],
    targets: [
        .target(name: "WearIQCore"),
        .target(name: "FitEngine", dependencies: ["WearIQCore"]),
        .target(name: "BodyMeasurementEngine", dependencies: ["WearIQCore"]),
        // Apple Vision glue; compiles to nothing on platforms without Vision.
        .target(name: "BodyScanVision", dependencies: ["BodyMeasurementEngine"]),
        .target(name: "ProductMeasurementParser", dependencies: ["WearIQCore"]),
        .target(name: "ScanQuota"),
        .target(name: "OutfitRecommendationEngine"),
        // 3D avatar from measurements, with garments drawn on it from the fit analysis.
        // Its body shape model is NVIDIA SOMA-X's (Apache-2.0), see scripts/build_soma_body.py.
        .target(name: "AvatarEngine", dependencies: ["WearIQCore"],
                resources: [.copy("Resources/SomaBody.bin"), .copy("Resources/SOMA-X-LICENSE.txt")]),
        .testTarget(name: "FitEngineTests", dependencies: ["FitEngine"]),
        .testTarget(name: "BodyMeasurementEngineTests", dependencies: ["BodyMeasurementEngine"]),
        .testTarget(name: "VisionIntegrationTests", dependencies: ["BodyScanVision", "BodyMeasurementEngine", "ProductMeasurementParser"],
                    resources: [.copy("Resources")]),
        .testTarget(name: "ProductMeasurementParserTests", dependencies: ["ProductMeasurementParser"]),
        .testTarget(name: "ScanQuotaTests", dependencies: ["ScanQuota"]),
        .testTarget(name: "OutfitRecommendationEngineTests", dependencies: ["OutfitRecommendationEngine"]),
        .testTarget(name: "AvatarEngineTests", dependencies: ["AvatarEngine"]),
    ]
)
