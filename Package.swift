// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Droplet",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Droplet", targets: ["Droplet"])],
    targets: [
        .target(name: "DropletKit"),
        .executableTarget(name: "Droplet", dependencies: ["DropletKit"]),
        // Foundation-only checks also run on Apple's Command Line Tools,
        // which do not ship XCTest/Swift Testing. Never included in the app.
        .executableTarget(name: "DropletChecks", dependencies: ["DropletKit"], path: "Tests/DropletKitTests"),
    ],
    swiftLanguageVersions: [.v5]
)
