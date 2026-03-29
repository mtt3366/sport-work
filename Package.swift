// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SportWork",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SportWork", targets: ["SportWork"])
    ],
    targets: [
        .executableTarget(
            name: "SportWork",
            path: "Sources"
        )
    ]
)
