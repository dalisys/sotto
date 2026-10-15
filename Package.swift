// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sotto",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Sotto", targets: ["Sotto"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: [])
    ],
    targets: [
        .executableTarget(name: "Sotto", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        .testTarget(name: "SottoTests", dependencies: ["Sotto"])
    ],
    swiftLanguageModes: [.v5]
)
