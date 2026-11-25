// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mtu-probe",
    platforms: [.macOS(.v13), .iOS(.v13)],
    products: [
        .library(name: "MTUProbeCore", targets: ["MTUProbeCore"]),
        .executable(name: "mtu-probe", targets: ["MTUProbe"])
    ],
    targets: [
        .target(name: "MTUProbeCore", path: "Sources/MTUProbeCore"),
        .executableTarget(
            name: "MTUProbe",
            dependencies: ["MTUProbeCore"],
            path: "Sources/MTUProbe"
        )
    ]
)
