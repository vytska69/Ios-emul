import Foundation
import IPSWKit

/// iPod touch 1st/2nd generation machines from `devos50/qemu-ios`.
///
/// Each generation lives on its own branch and both register the machine as `iPod-Touch`, so they
/// are separate QEMU builds (`qemu-system-arm-1g` and `qemu-system-arm`). The 1G model boots
/// iPhoneOS 1.0–2.1 to SpringBoard; the 2G model targets iPhoneOS 2.1.1. Both start from the real
/// boot ROM, which no IPSW contains, and from NOR/NAND images built with qemu-ios' tooling.
public struct IPodTouchBackend: EmulatorBackend {
    public init() {}

    public let id = "qemu-ios"
    public let displayName = "QEMU iPod touch (S5L8900/S5L8720)"
    public let upstream = "https://github.com/devos50/qemu-ios"
    public let defaultMemoryMB = 1024
    public let defaultCPUCount = 1

    public let externalAssets: [ExternalAsset] = [
        ExternalAsset(id: "bootrom", title: "Boot ROM dump (bootrom_s5l8900 / bootrom_s5l8720)",
                      help: "The SecureROM is burned into the SoC; dump it from your own iPod touch."),
        ExternalAsset(id: "nor", title: "NOR flash image",
                      help: "Built from the IPSW's LLB, iBoot and device tree with qemu-ios' NOR generator."),
        ExternalAsset(id: "nand", title: "NAND directory",
                      help: "Built from the root filesystem DMG with qemu-ios' NAND generator."),
        ExternalAsset(id: "iboot", title: "Decrypted iBoot (1st gen only)",
                      help: "The 1G machine loads iBoot directly; the IPSW copy is an encrypted IMG3."),
    ]

    private struct Model { let binary: String; let firstGen: Bool }

    private static let models: [String: Model] = [
        "iPod1,1": Model(binary: "qemu-system-arm-1g", firstGen: true),
        "iPod2,1": Model(binary: "qemu-system-arm", firstGen: false),
    ]

    public func compatibility(device: DeviceInfo, ipsw: IPSW) -> Compatibility {
        guard Self.models[device.productType] != nil else {
            return .unsupported("only iPod touch 1G/2G machines are modelled")
        }
        let (major, minor, patch) = ipsw.versionTriple
        if major > 2 { return .unsupported("iPhoneOS \(major) is not bootable on this machine yet") }
        if device.productType == "iPod2,1" && (major, minor, patch) != (2, 1, 1) {
            return .experimental("only iPhoneOS 2.1.1 is targeted by the 2G model")
        }
        return .supported
    }

    public func prepare(_ ctx: PrepareContext) throws -> MachineConfiguration {
        guard let model = Self.models[ctx.device.productType] else {
            throw BackendError.incompatible("\(ctx.device.name) is not an iPod touch 1G/2G")
        }
        try FileManager.default.createDirectory(at: ctx.workDirectory, withIntermediateDirectories: true)
        let bootrom = try requireAsset("bootrom", in: ctx)
        let nor = try requireAsset("nor", in: ctx)
        let nand = try requireAsset("nand", in: ctx)

        var machine = "iPod-Touch,bootrom=\(bootrom.path),nand=\(nand.path)"
        var args: [String] = []
        if model.firstGen {
            machine += ",iboot=\(try requireAsset("iboot", in: ctx).path)"
            args += ["-pflash", nor.path]
        } else {
            machine += ",nor=\(nor.path)"
        }

        let vncPort: UInt16 = 5901
        let monitorPort: UInt16 = 1234
        args = ["-M", machine, "-cpu", "max", "-m", "\(ctx.memoryMB)M"] + args + [
            "-serial", "file:\(ctx.workDirectory.appendingPathComponent("serial.log").path)",
            "-monitor", "telnet:127.0.0.1:\(monitorPort),server,nowait",
            "-vnc", "127.0.0.1:\(vncPort - 5900)",
        ]
        return MachineConfiguration(backendID: id, qemuBinary: model.binary, arguments: args,
                                    workingDirectory: ctx.workDirectory, vncPort: vncPort, monitorPort: monitorPort)
    }
}
