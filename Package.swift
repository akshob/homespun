// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "Homespun",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HomespunCore", targets: ["HomespunCore"]),
        .library(name: "HomespunMedia", targets: ["HomespunMedia"]),
        // Synthetic media for tests in this package and the iOS app. Not for product code.
        .library(name: "HomespunTestSupport", targets: ["HomespunTestSupport"]),
        .executable(name: "homespun-server", targets: ["HomespunServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(name: "HomespunCore", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
        .target(name: "HomespunMedia", dependencies: ["HomespunCore"]),
        .target(name: "HomespunTestSupport"),
        .executableTarget(
            name: "HomespunServer",
            dependencies: ["HomespunCore", "HomespunMedia", .product(name: "Hummingbird", package: "hummingbird")],
            exclude: ["LICENSE"]),
        .testTarget(name: "HomespunCoreTests", dependencies: ["HomespunCore"]),
        .testTarget(name: "HomespunMediaTests", dependencies: ["HomespunMedia", "HomespunTestSupport"]),
    ]
)
