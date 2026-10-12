// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TyporaNative",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TyporaNative", targets: ["TyporaNative"])],
    targets: [
        .target(name: "MarkdownCore"),
        .executableTarget(name: "TyporaNative", dependencies: ["MarkdownCore"], path: "Sources/DesktopHost"),
        .testTarget(name: "MarkdownCoreTests", dependencies: ["MarkdownCore"])
    ]
)
