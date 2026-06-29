// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SonarDictate",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sonar-dictate", targets: ["SonarDictate"]),
    ],
    targets: [
        .executableTarget(
            name: "SonarDictate",
            resources: [
                // ECAPA voiceprint model + exact Fbank constants + golden fixture,
                // loaded via Bundle.module (tier 2).
                .copy("Resources/voiceprint"),
            ]
        ),
    ]
)
