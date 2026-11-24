// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MegaBass",
    platforms: [.macOS("14.4")],
    targets: [
        .target(name: "MegaBassCore", linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AVFoundation")]),
        .executableTarget(name: "MegaBass", dependencies: ["MegaBassCore"]),
        .executableTarget(name: "mbcheck", dependencies: ["MegaBassCore"]),
    ]
)
