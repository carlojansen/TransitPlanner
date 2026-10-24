// swift-tools-version: 6.2
import PackageDescription

// Core-Engine ohne UI: API-Modelle, Netzwerk/Security, Location/Suche, Routing, Scheduling, SwiftData.
// macOS ist nur als Plattform eingetragen, damit `swift test` offline auf dem Mac laeuft.
let package = Package(
    name: "TransitCore",
    defaultLocalization: "de",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "TransitCore", targets: ["TransitCore"]),
    ],
    targets: [
        .target(name: "TransitCore", resources: [.process("Resources")]),
        .testTarget(
            name: "TransitCoreTests",
            dependencies: ["TransitCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
