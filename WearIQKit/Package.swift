// swift-tools-version: 6.0
import PackageDescription

// Platform-independent engines for WearIQ. Everything here is pure Swift + Foundation
// so it can be built and tested on macOS, Linux and Windows CI as well as on iOS.
let package = Package(
    name: "WearIQKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WearIQCore", targets: ["WearIQCore"]),
        .library(name: "FitEngine", targets: ["FitEngine"]),
        .library(name: "BodyMeasurementEngine", targets: ["BodyMeasurementEngine"]),
        .library(name: "ProductMeasurementParser", targets: ["ProductMeasurementParser"]),
        .library(name: "ScanQuota", targets: ["ScanQuota"]),
    ],
    targets: [
        .target(name: "WearIQCore"),
        .target(name: "FitEngine", dependencies: ["WearIQCore"]),
        .target(name: "BodyMeasurementEngine", dependencies: ["WearIQCore"]),
        .target(name: "ProductMeasurementParser", dependencies: ["WearIQCore"]),
        .target(name: "ScanQuota"),
        .testTarget(name: "FitEngineTests", dependencies: ["FitEngine"]),
        .testTarget(name: "BodyMeasurementEngineTests", dependencies: ["BodyMeasurementEngine"]),
        .testTarget(name: "ProductMeasurementParserTests", dependencies: ["ProductMeasurementParser"]),
        .testTarget(name: "ScanQuotaTests", dependencies: ["ScanQuota"]),
    ]
)
