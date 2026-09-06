// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Barky",
    defaultLocalization: "en",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "Barky", targets: ["Barky"])],
    targets: [
        .target(name: "Barky", resources: [.process("Resources")]),
        .testTarget(name: "BarkyTests", dependencies: ["Barky"]),
    ]
)
