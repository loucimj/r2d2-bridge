// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "R2Menu",
  platforms: [.macOS(.v13)],
  targets: [.executableTarget(name: "R2Menu", path: "Sources/R2Menu")]
)
