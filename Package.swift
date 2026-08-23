// swift-tools-version:6.0
import PackageDescription

let bundledAthan = Context.packageDirectory + "/Resources/Athan/Adhan.m4a"

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
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Keep the default recording in the Mach-O itself. A plain
                // `swift build` binary can then play the adhan without a
                // neighbouring resource bundle or the handcrafted .app.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__DATA",
                    "-Xlinker", "__adhan",
                    "-Xlinker", bundledAthan,
                ])
            ]
        ),
        .testTarget(
            name: "BarakahTests",
            dependencies: ["Barakah"],
            path: "Tests/BarakahTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
