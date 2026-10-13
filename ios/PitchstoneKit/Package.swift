// swift-tools-version: 6.0
import PackageDescription

// Logica dell'app separata dal progetto Xcode: PitchstoneSync è Foundation
// pura e si testa anche su Linux (CI economica); PitchstoneStore usa SwiftData,
// Network e Security e si compila solo sulle piattaforme Apple.
let package = Package(
    name: "PitchstoneKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PitchstoneSync", targets: ["PitchstoneSync"]),
        .library(name: "PitchstoneStore", targets: ["PitchstoneStore"]),
    ],
    targets: [
        .target(name: "PitchstoneSync"),
        .target(name: "PitchstoneStore", dependencies: ["PitchstoneSync"]),
        .testTarget(name: "PitchstoneSyncTests", dependencies: ["PitchstoneSync"]),
        .testTarget(name: "PitchstoneStoreTests", dependencies: ["PitchstoneStore", "PitchstoneSync"]),
    ]
)
