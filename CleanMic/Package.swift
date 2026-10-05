// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CleanMic",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "cleanmic-cli", targets: ["CleanMicCLI"]),
        .executable(name: "CleanMicApp", targets: ["CleanMicApp"]),
        .library(name: "CleanMicCore", targets: ["CleanMicCore"]),
    ],
    targets: [
        .target(
            name: "CleanMicCore",
            path: "Sources/CleanMicCore",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("../Vendor/rnnoise/include"),
                .headerSearchPath("../Vendor/rnnoise/src"),
                .unsafeFlags(["-DRNNOISE_BUILD"]),
            ],
            linkerSettings: [
                .linkedLibrary("rnnoise"),
                .unsafeFlags(["-L", "\(Context.packageDirectory)/Vendor/rnnoise"]),
            ]
        ),
        .executableTarget(
            name: "CleanMicCLI",
            dependencies: ["CleanMicCore"],
            path: "Sources/CleanMicCLI"
        ),
        .executableTarget(
            name: "CleanMicApp",
            dependencies: ["CleanMicCore"],
            path: "Sources/CleanMicApp"
        ),
        .testTarget(
            name: "CleanMicTests",
            dependencies: ["CleanMicCore"],
            path: "Tests/CleanMicTests"
        ),
    ]
)
