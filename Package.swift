// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SonarDictate",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sonar-dictate", targets: ["SonarDictate"]),
    ],
    targets: [
        .executableTarget(name: "SonarDictate"),
    ]
)
