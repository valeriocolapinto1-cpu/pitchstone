// swift-tools-version: 6.0
import PackageDescription

// Logica dell'app separata dal progetto Xcode. PitchstoneSync, PitchstoneNotes e
// PitchstoneGraph sono Foundation pura e si testano anche su Linux (CI economica);
// PitchstoneStore usa SwiftData, Network e Security e si compila solo sulle
// piattaforme Apple.
let package = Package(
    name: "PitchstoneKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PitchstoneSync", targets: ["PitchstoneSync"]),
        .library(name: "PitchstoneStore", targets: ["PitchstoneStore"]),
        .library(name: "PitchstoneNotes", targets: ["PitchstoneNotes"]),
        .library(name: "PitchstoneGraph", targets: ["PitchstoneGraph"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
    ],
    targets: [
        .target(name: "PitchstoneSync"),
        .target(name: "PitchstoneStore", dependencies: ["PitchstoneSync"]),
        .target(name: "PitchstoneNotes", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
        .target(name: "PitchstoneGraph", dependencies: ["PitchstoneSync"]),
        .testTarget(name: "PitchstoneSyncTests", dependencies: ["PitchstoneSync"]),
        .testTarget(name: "PitchstoneStoreTests", dependencies: ["PitchstoneStore", "PitchstoneSync"]),
        .testTarget(name: "PitchstoneNotesTests", dependencies: ["PitchstoneNotes"]),
        .testTarget(name: "PitchstoneGraphTests", dependencies: ["PitchstoneGraph", "PitchstoneSync"]),
    ]
)
