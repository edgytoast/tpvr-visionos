// swift-tools-version:5.9
// TrevorbiltKit: the launcher pieces every Trevorbilt Vision Pro port shares (brand, header, mode cards,
// inputs, controller callouts, Ports, About). Vendored into each port as a local package; see README.md.
import PackageDescription

let package = Package(
    name: "TrevorbiltKit",
    platforms: [.visionOS("26.0")],
    products: [.library(name: "TrevorbiltKit", targets: ["TrevorbiltKit"])],
    targets: [
        .target(name: "TrevorbiltKit", resources: [.copy("Resources/Fonts"), .copy("Resources/Brand"),
                                                   .process("Resources/Hands.xcassets")]),
    ]
)
