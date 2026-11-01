// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "omemo-interop",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../Packages/WardCrypto")
    ],
    targets: [
        .executableTarget(
            name: "omemo-interop",
            dependencies: [.product(name: "WardCrypto", package: "WardCrypto")]
        )
    ]
)
