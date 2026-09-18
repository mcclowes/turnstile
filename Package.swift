// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "turnstile",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "turnstile", targets: ["turnstile"]),
    ],
    targets: [
        .target(
            name: "TurnstileCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "turnstile",
            dependencies: ["TurnstileCore"]
        ),
        .testTarget(
            name: "TurnstileCoreTests",
            dependencies: ["TurnstileCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
