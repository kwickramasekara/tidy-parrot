// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TidyParrot",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "TidyParrot", targets: ["TidyParrot"])
    ],
    targets: [
        // All app logic lives here so tests can import it; the executable only starts NSApplication.
        .target(name: "TidyParrotCore"),
        .executableTarget(name: "TidyParrot", dependencies: ["TidyParrotCore"]),
        .testTarget(name: "TidyParrotCoreTests", dependencies: ["TidyParrotCore"]),
    ]
)
