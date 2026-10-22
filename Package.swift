// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IOSEmul",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "IPSWKit", targets: ["IPSWKit"]),
        .library(name: "EmulatorKit", targets: ["EmulatorKit"]),
        .executable(name: "ipsw-emu", targets: ["ipsw-emu"]),
    ],
    targets: [
        .target(name: "IPSWKit", resources: [.process("Resources")]),
        .target(name: "EmulatorKit", dependencies: ["IPSWKit"], resources: [.process("Resources")]),
        .executableTarget(name: "ipsw-emu", dependencies: ["IPSWKit", "EmulatorKit"]),
        .testTarget(name: "IPSWKitTests", dependencies: ["IPSWKit", "EmulatorKit"], resources: [.copy("Fixtures")]),
    ]
)
