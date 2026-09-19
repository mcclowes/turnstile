// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "turnstile",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "turnstile", targets: ["turnstile"]),
        .executable(name: "TurnstileBar", targets: ["TurnstileBar"]),
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
        // The menu bar app. `scripts/package.sh` wraps it in Turnstile.app.
        .executableTarget(
            name: "TurnstileBar",
            dependencies: ["TurnstileCore"]
        ),
        .testTarget(
            name: "TurnstileCoreTests",
            dependencies: ["TurnstileCore"]
        ),
        // Drives the daemon and the shim's supervisor, which live in the executable.
        .testTarget(
            name: "TurnstileTests",
            dependencies: ["turnstile", "TurnstileCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
