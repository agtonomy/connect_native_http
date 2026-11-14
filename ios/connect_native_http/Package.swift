// swift-tools-version: 6.0

import PackageDescription

// Flutter builds this package next to the FlutterFramework package it generates for the app. The Flutter-free core
// and its tests also build on their own, without it, on macOS or Linux:
//   CONNECT_NATIVE_HTTP_CORE_ONLY=1 swift test
//
// swift-nio-http3 and swift-nio-quic need Swift 6.4 and, on Apple platforms, iOS or macOS 27.
let coreOnly = Context.environment["CONNECT_NATIVE_HTTP_CORE_ONLY"] != nil

let core = Target.target(
    name: "ConnectNativeHttpCore",
    dependencies: [
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "HTTP3", package: "swift-nio-http3"),
        .product(name: "NIOHTTP3", package: "swift-nio-http3"),
        .product(name: "NIOQUIC", package: "swift-nio-quic"),
        .product(name: "NIOQUICHelpers", package: "swift-nio-quic-helpers"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
        .product(name: "NIOHTTPTypes", package: "swift-nio-extras"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "X509", package: "swift-certificates"),
    ],
    swiftSettings: [.enableExperimentalFeature("AnyAppleOSAvailability")]
)
let coreTests = Target.testTarget(
    name: "ConnectNativeHttpCoreTests",
    dependencies: [
        "ConnectNativeHttpCore",
        .product(name: "X509", package: "swift-certificates"),
    ]
)
let plugin = Target.target(
    name: "connect_native_http",
    dependencies: [
        "ConnectNativeHttpCore",
        .product(name: "FlutterFramework", package: "FlutterFramework"),
    ]
)

let package = Package(
    name: "connect_native_http",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0"),
    ],
    products: coreOnly ? [] : [
        .library(name: "connect-native-http", targets: ["connect_native_http"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
        // swift-nio-http3 has no release yet, so it is pinned to a commit.
        .package(url: "https://github.com/apple/swift-nio-http3.git", revision: "58ba11baee89b43ca1adeafe6bb976f17c9a86f3"),
        .package(url: "https://github.com/apple/swift-nio-quic.git", .upToNextMinor(from: "0.6.0")),
        .package(url: "https://github.com/apple/swift-nio-quic-helpers.git", .upToNextMinor(from: "0.1.2")),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.8.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.22.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.12.1"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.21.0"),
    ] + (coreOnly ? [] : [.package(name: "FlutterFramework", path: "../FlutterFramework")]),
    targets: coreOnly ? [core, coreTests] : [core, plugin, coreTests],
    swiftLanguageModes: [.v5]
)
