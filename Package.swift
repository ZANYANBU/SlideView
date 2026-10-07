// swift-tools-version:5.9
import PackageDescription

// The app itself is built by build.sh. This package exists so `swift test` can
// compile everything except the AppKit entry point and run the tests against it.
let package = Package(
    name: "SlideView",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SlideViewCore", path: "Sources", exclude: ["main.swift"]),
        .testTarget(name: "SlideViewTests", dependencies: ["SlideViewCore"], path: "Tests"),
    ]
)
