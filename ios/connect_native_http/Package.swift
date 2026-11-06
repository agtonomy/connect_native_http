// swift-tools-version: 5.9

import PackageDescription

// Flutter builds this package next to the FlutterFramework package it generates for the app. The Flutter-free core
// and its tests also build on their own, without it:
//   CONNECT_NATIVE_HTTP_CORE_ONLY=1 swift test
let coreOnly = Context.environment["CONNECT_NATIVE_HTTP_CORE_ONLY"] != nil

let core = Target.target(name: "ConnectNativeHttpCore")
let coreTests = Target.testTarget(name: "ConnectNativeHttpCoreTests", dependencies: ["ConnectNativeHttpCore"])
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
        .iOS("15.0"),
        .macOS("12.0"),
    ],
    products: coreOnly ? [] : [
        .library(name: "connect-native-http", targets: ["connect_native_http"])
    ],
    dependencies: coreOnly ? [] : [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: coreOnly ? [core, coreTests] : [core, plugin, coreTests]
)
