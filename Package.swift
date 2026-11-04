// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "Roundtrip",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RoundtripCore", targets: ["RoundtripCore"]),
        .library(name: "RoundtripMedia", targets: ["RoundtripMedia"]),
        .executable(name: "roundtrip-server", targets: ["RoundtripServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(name: "RoundtripCore", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
        .target(name: "RoundtripMedia", dependencies: ["RoundtripCore"]),
        .executableTarget(
            name: "RoundtripServer",
            dependencies: ["RoundtripCore", "RoundtripMedia", .product(name: "Hummingbird", package: "hummingbird")],
            exclude: ["LICENSE"]),
        .testTarget(name: "RoundtripCoreTests", dependencies: ["RoundtripCore"]),
        .testTarget(name: "RoundtripMediaTests", dependencies: ["RoundtripMedia"]),
    ]
)
