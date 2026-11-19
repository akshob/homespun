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
        // The server as a library, for server binaries that add their own connectors.
        .library(name: "HomespunServerKit", targets: ["HomespunServerKit"]),
        .executable(name: "homespun-server", targets: ["HomespunServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.9.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.20.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.28.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/fwcd/swift-qrcode-generator.git", from: "2.0.0"),
    ],
    targets: [
        .target(name: "HomespunCore", dependencies: [
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto", condition: .when(platforms: [.linux])),
        ]),
        .target(name: "HomespunMedia", dependencies: [
            "HomespunCore",
            .target(name: "CHomespunVips", condition: .when(platforms: [.linux])),
        ]),
        // libvips (Linux photo backend). Install with: apt install libvips-dev
        .systemLibrary(name: "CLibVips", pkgConfig: "vips", providers: [.apt(["libvips-dev"])]),
        .target(name: "CHomespunVips", dependencies: [
            .target(name: "CLibVips", condition: .when(platforms: [.linux])),
        ]),
        .target(name: "HomespunTestSupport"),
        // System SQLite for the server catalog (Linux: apt install libsqlite3-dev).
        .systemLibrary(name: "CSQLite", providers: [.apt(["libsqlite3-dev"])]),
        .target(
            name: "HomespunServerKit",
            dependencies: [
                "HomespunCore", "HomespunMedia", "CSQLite",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "QRCodeGenerator", package: "swift-qrcode-generator"),
            ],
            exclude: ["LICENSE"]),
        .executableTarget(name: "HomespunServer", dependencies: ["HomespunServerKit"], exclude: ["LICENSE"]),
        .testTarget(name: "HomespunCoreTests", dependencies: ["HomespunCore"]),
        .testTarget(name: "HomespunServerTests", dependencies: [
            "HomespunServerKit",
            "HomespunTestSupport",
            .product(name: "HummingbirdTesting", package: "hummingbird"),
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "X509", package: "swift-certificates"),
        ], resources: [.copy("Fixtures")]),
        .testTarget(name: "HomespunMediaTests", dependencies: ["HomespunMedia", "HomespunTestSupport"],
                    resources: [.copy("Fixtures")]),
    ]
)
