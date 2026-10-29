// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "MomentCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "MomentCore", targets: ["MomentCore"]),
    ],
    targets: [
        .target(name: "MomentCore"),
        // Scenario checks shared by XCTest (in Xcode) and a CLI runner (`swift run momentcore-check`),
        // so the logic can be verified on machines without Xcode.
        .target(name: "MomentCoreScenarios", dependencies: ["MomentCore"]),
        .executableTarget(name: "momentcore-check", dependencies: ["MomentCoreScenarios"]),
        .testTarget(name: "MomentCoreTests", dependencies: ["MomentCoreScenarios"]),
    ]
)
