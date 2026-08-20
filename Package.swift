// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Barakah",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Barakah", targets: ["Barakah"])
    ],
    dependencies: [
        .package(url: "https://github.com/batoulapps/adhan-swift.git", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "Barakah",
            dependencies: [.product(name: "Adhan", package: "adhan-swift")],
            path: "Sources/Barakah",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BarakahTests",
            dependencies: ["Barakah"],
            path: "Tests/BarakahTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
