// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Heartware",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Heartware",
            path: "Sources/Heartware",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
