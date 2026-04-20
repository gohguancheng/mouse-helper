// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift Package Manager
// needed to build this package.

import PackageDescription

let package = Package(
    name: "MouseHelper",
    // We target macOS 13+ (Ventura) which gives us modern Swift concurrency
    // and the latest AppKit/CoreGraphics APIs.
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "MouseHelper",
            path: "Sources/MouseHelper"
        )
    ]
)
