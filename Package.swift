// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TimeMachine",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TimeMachine", targets: ["TimeMachine"])
    ],
    targets: [
        .executableTarget(
            name: "TimeMachine",
            path: "Sources/TimeMachine",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation")
            ]
        )
    ]
)
