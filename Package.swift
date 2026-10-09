// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleTVRemote",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AppleTVKit", targets: ["AppleTVKit"]),
        .executable(name: "RemoteApp", targets: ["RemoteApp"]),
        .executable(name: "atvctl", targets: ["atvctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/adam-fowler/swift-srp", from: "2.4.0"),
    ],
    targets: [
        .target(
            name: "AppleTVKit",
            dependencies: [
                .product(name: "SRP", package: "swift-srp"),
            ]
        ),
        .executableTarget(
            name: "RemoteApp",
            dependencies: ["AppleTVKit"],
            linkerSettings: [
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(
            name: "atvctl",
            dependencies: ["AppleTVKit"]
        ),
        .testTarget(
            name: "AppleTVKitTests",
            dependencies: ["AppleTVKit"]
        ),
    ]
)
