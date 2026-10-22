// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IOSEmul",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "IPSWKit", targets: ["IPSWKit"]),
        .library(name: "EmulatorKit", targets: ["EmulatorKit"]),
    ],
    targets: [
        .target(name: "IPSWKit", resources: [.process("Resources")]),
        .target(name: "EmulatorKit", dependencies: ["IPSWKit"], resources: [.process("Resources")]),
        .testTarget(name: "IPSWKitTests", dependencies: ["IPSWKit", "EmulatorKit"]),
    ]
)
