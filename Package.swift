// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MegaBass",
    platforms: [.macOS("14.4")],
    targets: [
        // Exclusivity checks cost ~10 % of the per-pixel planet and audio loops; the code keeps to one
        // writer per object, so release builds skip the runtime check.
        .target(name: "MegaBassCore", swiftSettings: [.unsafeFlags(["-enforce-exclusivity=unchecked"])],
                linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AVFoundation")]),
        .executableTarget(name: "MegaBass", dependencies: ["MegaBassCore"], swiftSettings: [.unsafeFlags(["-enforce-exclusivity=unchecked"])]),
        .executableTarget(name: "mbcheck", dependencies: ["MegaBassCore"]),
    ]
)
