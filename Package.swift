// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Parchment",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Parchment", targets: ["Parchment"]), .executable(name: "ParchmentMCP", targets: ["ParchmentMCP"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.7.0")],
    targets: [
        .target(name: "ParchmentCore", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "ParchmentIntegration", dependencies: ["ParchmentCore", "CSQLite"]),
        .executableTarget(name: "ParchmentMCP", dependencies: ["ParchmentIntegration"]),
        .executableTarget(name: "Parchment", dependencies: ["ParchmentCore", "ParchmentIntegration"], path: ".",
            exclude: ["docs", "skills", "Tests", "Sources/ParchmentCore", "Sources/CSQLite", "Sources/ParchmentIntegration", "Sources/ParchmentMCP", "scripts", "README.md", "examples", "dist"],
            sources: ["Sources/Parchment"], resources: [.copy("themes")]),
        .executableTarget(name: "ParchmentChecks", dependencies: ["ParchmentCore"], path: "Tests/ParchmentCoreTests")
    ]
)
