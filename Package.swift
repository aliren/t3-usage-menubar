// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "T3Usage", platforms: [.macOS(.v13)], products: [
    .executable(name: "T3Usage", targets: ["T3Usage"])
], targets: [
    .target(name: "T3UsageCore"),
    .executableTarget(name: "T3Usage", dependencies: ["T3UsageCore"]),
    .executableTarget(name: "CoreChecks", dependencies: ["T3UsageCore"], path: "Tests/T3UsageCoreTests")
], swiftLanguageModes: [.v5])
