// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OpenTouch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "OpenTouch", targets: ["OpenTouch"]),
    ],
    targets: [
        // Pure logic: HID descriptor parsing, report decoding, gesture recognition.
        // No AppKit / IOKit, so it can be unit tested in isolation.
        .target(name: "OpenTouchCore"),
        .executableTarget(
            name: "OpenTouch",
            dependencies: ["OpenTouchCore"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "OpenTouchCoreTests", dependencies: ["OpenTouchCore"]),
    ]
)
