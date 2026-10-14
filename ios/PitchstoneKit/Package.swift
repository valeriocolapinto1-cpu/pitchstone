// swift-tools-version: 6.0
import PackageDescription

// Logica dell'app separata dal progetto Xcode. PitchstoneSync, PitchstoneNotes,
// PitchstoneGraph, PitchstoneImport, PitchstoneAI e PitchstoneStudy sono Foundation pura e si testano anche su
// Linux (CI economica); PitchstoneStore usa SwiftData, Network e Security e si
// compila solo sulle piattaforme Apple.
let package = Package(
    name: "PitchstoneKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PitchstoneSync", targets: ["PitchstoneSync"]),
        .library(name: "PitchstoneStore", targets: ["PitchstoneStore"]),
        .library(name: "PitchstoneNotes", targets: ["PitchstoneNotes"]),
        .library(name: "PitchstoneGraph", targets: ["PitchstoneGraph"]),
        .library(name: "PitchstoneImport", targets: ["PitchstoneImport"]),
        .library(name: "PitchstoneAI", targets: ["PitchstoneAI"]),
        .library(name: "PitchstoneStudy", targets: ["PitchstoneStudy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
    ],
    targets: [
        .target(name: "PitchstoneSync"),
        .target(name: "PitchstoneStore", dependencies: ["PitchstoneSync", "PitchstoneNotes", "PitchstoneStudy"]),
        .target(name: "PitchstoneNotes", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
        .target(name: "PitchstoneGraph", dependencies: ["PitchstoneSync"]),
        .target(
            name: "PitchstoneImport",
            dependencies: ["PitchstoneSync", .product(name: "Markdown", package: "swift-markdown")]),
        .target(name: "PitchstoneAI", dependencies: ["PitchstoneSync", "PitchstoneNotes"]),
        .target(name: "PitchstoneStudy", dependencies: ["PitchstoneAI", "PitchstoneSync", "PitchstoneNotes"]),
        .testTarget(name: "PitchstoneSyncTests", dependencies: ["PitchstoneSync"]),
        .testTarget(name: "PitchstoneStoreTests", dependencies: ["PitchstoneStore", "PitchstoneSync", "PitchstoneNotes"]),
        .testTarget(name: "PitchstoneNotesTests", dependencies: ["PitchstoneNotes"]),
        .testTarget(name: "PitchstoneGraphTests", dependencies: ["PitchstoneGraph", "PitchstoneSync"]),
        .testTarget(
            name: "PitchstoneImportTests", dependencies: ["PitchstoneImport", "PitchstoneSync"],
            resources: [.copy("VaultDiEsempio")]),
        .testTarget(name: "PitchstoneAITests", dependencies: ["PitchstoneAI", "PitchstoneSync", "PitchstoneNotes"]),
        .testTarget(
            name: "PitchstoneStudyTests",
            dependencies: ["PitchstoneStudy", "PitchstoneAI", "PitchstoneSync", "PitchstoneImport", "PitchstoneNotes"]),
    ]
)
