// swift-tools-version: 6.0
import PackageDescription

// The portability seam (docs/DESIGN.md): everything below PondsideUI must
// build and test on Linux. CI builds these targets on Linux on every push,
// and scripts/check-seam.sh rejects Apple-only imports in them.

var products: [Product] = [
    .executable(name: "pondside", targets: ["PondsideCLI"]),
    .library(name: "PondsideCore", targets: ["PondsideCore"]),
    .library(name: "PondsideEngrave", targets: ["PondsideEngrave"]),
    .library(name: "PondsideTiming", targets: ["PondsideTiming"]),
    .library(name: "PondsideLexicon", targets: ["PondsideLexicon"]),
    .library(name: "PondsideBridge", targets: ["PondsideBridge"]),
]

var targets: [Target] = [
    // Portable — no AppKit, no SwiftUI, no Apple-only Foundation.
    .target(name: "PondsideCore"),
    .target(name: "PondsideEngrave", dependencies: ["PondsideCore"]),
    .target(name: "PondsideTiming", dependencies: ["PondsideCore"]),
    .target(name: "PondsideLexicon", dependencies: ["PondsideCore"]),
    .target(name: "PondsideBridge", dependencies: ["PondsideCore", "PondsideEngrave", "PondsideTiming", "PondsideLexicon"]),
    .executableTarget(name: "PondsideCLI", dependencies: ["PondsideCore", "PondsideEngrave", "PondsideBridge"]),

    .testTarget(name: "PondsideCoreTests", dependencies: ["PondsideCore"], resources: [.copy("Fixtures")]),
    .testTarget(name: "PondsideEngraveTests", dependencies: ["PondsideEngrave"], resources: [.copy("Fixtures")]),
]

#if os(macOS)
// ─────────────────────────── seam ───────────────────────────
// macOS only. Treated as disposable: a port replaces these two targets.
products.append(.executable(name: "PondsideApp", targets: ["PondsideApp"]))
targets += [
    .target(name: "PondsideUI", dependencies: ["PondsideCore", "PondsideEngrave"]),
    .executableTarget(name: "PondsideApp", dependencies: ["PondsideUI"]),
]
#endif

let package = Package(
    name: "Pondside",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
