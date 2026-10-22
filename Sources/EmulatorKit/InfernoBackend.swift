import Foundation
import IPSWKit

/// Machines from QEMUAppleSilicon, the maintained successor of qemu-t8030, built with the patches in
/// qemu/patches/inferno (a derivative build: upstream's name and artwork are not used).
///
/// Inferno loads IM4P kernelcaches, device trees and trust caches itself and patches the kernel
/// at boot, so the files are passed straight from the IPSW. SEP emulation is optional and needs
/// both the SEP ROM (not in any IPSW) and a decrypted SEP firmware.
public struct InfernoBackend: EmulatorBackend {
    public struct Machine {
        let name: String                 // QEMU -M value
        let soc: String
        let productTypes: Set<String>
        let referenceProduct: String     // the board whose device tree the model was built against
        let supportedMajors: ClosedRange<Int>
        let extraMajors: Set<Int>         // major versions the machine accepts outside the range
        let wellTestedMajor: Int?
        let maxCPUs: Int
    }

    public let machine: Machine

    public init(machine: Machine) { self.machine = machine }

    public var id: String { "inferno-\(machine.name)" }
    public var displayName: String { "Apple \(machine.name.uppercased()) machine" }
    public let upstream = "https://github.com/ChefKissInc/QEMUAppleSilicon"
    public let defaultMemoryMB = 4096
    public var defaultCPUCount: Int { min(4, machine.maxCPUs) }

    public let externalAssets: [ExternalAsset] = [
        ExternalAsset(id: "apticket", title: "AP ticket (root_ticket.der) — optional",
                      help: "Needed for restore with idevicerestore; create it with qemu-t8030-tools' create_apticket.py."),
        ExternalAsset(id: "seprom", title: "SEP ROM — optional",
                      help: "Enables SEP emulation together with a decrypted SEP firmware. Not shipped in IPSWs."),
        ExternalAsset(id: "sepfw", title: "Decrypted SEP firmware — optional",
                      help: "The IPSW's sep-firmware.*.im4p is encrypted; supply a decrypted copy to enable SEP."),
    ]

    public func compatibility(device: DeviceInfo, version: String, build: String) -> Compatibility {
        guard machine.productTypes.contains(device.productType) else {
            return .unsupported("\(displayName) only models \(machine.productTypes.sorted().joined(separator: ", "))")
        }
        let major = IPSW.versionTriple(version).0
        guard machine.supportedMajors.contains(major) || machine.extraMajors.contains(major) else {
            return .unsupported("the \(machine.name) kernel loader does not handle iOS \(major)")
        }
        if device.productType != machine.referenceProduct {
            return .experimental("the machine models \(machine.referenceProduct)'s board; this device tree may not match")
        }
        if major == machine.wellTestedMajor { return .supported }
        return .experimental("iOS \(major) is accepted by the machine model; how far it boots depends on the build")
    }

    public func prepare(_ ctx: PrepareContext) throws -> MachineConfiguration {
        let fm = FileManager.default
        let dir = ctx.workDirectory
        let fwDir = dir.appendingPathComponent("firmware")
        try fm.createDirectory(at: fwDir, withIntermediateDirectories: true)

        let seprom = ctx.externalAssets["seprom"].flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
        let sepfw = ctx.externalAssets["sepfw"].flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
        if (seprom == nil) != (sepfw == nil) {
            throw BackendError.incompatible("SEP emulation needs both the SEP ROM and the decrypted SEP firmware")
        }
        let ticket = ctx.externalAssets["apticket"].flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }

        // Restore components boot the ramdisk; Inferno falls back to the disk once NVRAM says the restore
        // finished. Direct mode boots the installed system instead, so it needs the OS trust cache.
        let identity = ctx.identity
        let direct = ctx.bootMode == .direct
        var components = ["DeviceTree"]
        let trustcache: String
        if direct {
            trustcache = "StaticTrustCache"
        } else {
            components.append("RestoreRamDisk")
            trustcache = identity.path("RestoreTrustCache") != nil ? "RestoreTrustCache" : "StaticTrustCache"
        }
        components.append(trustcache)
        let files = try ctx.ipsw.extract(components: components, identity: identity, to: fwDir, progress: ctx.progress)

        let kernelPath = ctx.ipsw.researchKernelPath(for: identity) ?? identity.path("KernelCache")
        guard let kernelPath else { throw IPSWError.missingComponent("KernelCache") }
        ctx.progress("KernelCache", 0)
        let kernel = try ctx.ipsw.extract(path: kernelPath, to: fwDir)
        ctx.progress("KernelCache", 1)

        // NVMe namespaces as laid out by the iPhone's ANS controller (wiki "Creating NVMe namespaces").
        let namespaces: [(file: String, nsid: Int, type: Int, size: UInt64, device: String)] = [
            ("nvme.1", 1, 1, 32 << 30, "nvme-ns"),     // system + data container
            ("nvme.2", 2, 2, 8 << 20, "nvme-ns"),      // firmware
            ("nvme.3", 3, 3, 128 << 10, "nvme-ns"),    // syscfg
            ("nvme.4", 4, 4, 8 << 10, "nvme-ns"),      // control bits
            ("nvram", 5, 5, 8 << 10, "apple-nvram"),   // NVRAM (holds auto-boot)
            ("nvme.6", 6, 6, 4 << 10, "nvme-ns"),      // effaceable storage
            ("nvme.7", 7, 8, 1 << 20, "nvme-ns"),      // panic log
        ]
        var rootDevice: String?
        var deviceTree = files["DeviceTree"]!
        if direct {
            rootDevice = try installRootFilesystem(ctx, disk: dir.appendingPathComponent("nvme.1"), size: namespaces[0].size)
            deviceTree = try directDeviceTree(from: deviceTree)
        }
        for ns in namespaces { try ensureDisk(dir.appendingPathComponent(ns.file), sizeBytes: ns.size) }

        var props = ["\(machine.name)", "trustcache=\(files[trustcache]!.path)", "kaslr-off=true",
                     "boot-mode=\(ctx.bootMode.machineBootMode)"]
        if let ticket { props.append("ticket=\(ticket.path)") }
        if let seprom, let sepfw { props += ["sep-rom=\(seprom.path)", "sep-fw=\(sepfw.path)"] }

        // With SEP emulated, one of the -smp CPUs becomes the SEP core.
        let cpus = min(ctx.cpuCount, machine.maxCPUs) + (seprom != nil ? 1 : 0)

        let vncPort: UInt16 = 5901
        let monitorPort: UInt16 = 1235
        var args = [
            "-M", props.joined(separator: ","),
            "-cpu", "max", "-smp", "\(cpus)", "-m", "\(ctx.memoryMB)M",
            "-kernel", kernel.path,
            "-dtb", deviceTree.path,
            "-append", "debug=0x14e kextlog=0xffff serial=3 -v wdt=-1" + (rootDevice.map { " rd=\($0)" } ?? ""),
            "-serial", "file:\(dir.appendingPathComponent("serial.log").path)",
            "-monitor", "telnet:127.0.0.1:\(monitorPort),server,nowait",
            "-vnc", "127.0.0.1:\(vncPort - 5900)",
        ]
        if let ramdisk = files["RestoreRamDisk"] { args += ["-initrd", ramdisk.path] }
        for ns in namespaces {
            let drive = "drive.\(ns.nsid)"
            let idSuffix = ns.device == "apple-nvram" ? ",id=nvram" : ""
            args += ["-drive", "file=\(dir.appendingPathComponent(ns.file).path),format=raw,if=none,id=\(drive)",
                     "-device", "\(ns.device),drive=\(drive),bus=nvme-bus.0,nsid=\(ns.nsid),nstype=\(ns.type)\(idSuffix),"
                        + "logical_block_size=4096,physical_block_size=4096"]
        }

        return MachineConfiguration(backendID: id, qemuBinary: "qemu-system-aarch64", arguments: args,
                                    workingDirectory: dir, vncPort: vncPort, monitorPort: monitorPort)
    }

    /// Volumes a direct install provides: the IPSW's System volume and the Preboot volume it adds
    /// (`APFSContainer.addVolume`). A restore also creates xART, Hardware, Update, Baseband and Data
    /// volumes; their fstab entries are dropped so launchd's mount phase does not fail looking for
    /// them, except Data, which is swapped for an ephemeral one (below).
    static let directInstallVolumes: Set<String> = ["system-vol", "preboot-vol", "data-vol"]

    /// Writes a copy of the DeviceTree whose fstab describes the disk a direct install produces.
    ///
    /// The tree already carries fstab variants for diagnostic/recovery environments in which
    /// /private/var is an ephemeral volume created at boot from the system volume's template.
    /// Using that definition for the normal environment gives the OS a writable /private/var
    /// without a restore having created a Data volume.
    func directDeviceTree(from file: URL) throws -> URL {
        let tree = try DeviceTree.parse(Data(contentsOf: file))
        let ephemeral = tree.child("filesystems")?.children
            .first { $0.name.hasPrefix("fstab-ephemeral-diag") }?
            .children.first { $0.properties["vol.fs_ephemeral"] != nil }
        let pruned = DeviceTree.serialize(tree) { node in
            guard node.parent?.name == "fstab", node.parent?.parent?.name == "filesystems" else { return node }
            guard Self.directInstallVolumes.contains(node.name) else { return nil }
            if node.name == "data-vol", let ephemeral {
                var props = ephemeral.properties
                props["name"] = Data("data-vol".utf8) + Data([0])
                props["AAPL,phandle"] = node.properties["AAPL,phandle"]   // keep phandles unique
                return DeviceTreeNode(properties: props, placeholders: ephemeral.placeholders)
            }
            return node
        }
        let out = file.deletingLastPathComponent().appendingPathComponent("DeviceTree.direct.raw")
        try pruned.write(to: out)
        return out
    }

    /// Logical block size of the emulated NVMe namespaces (`logical_block_size` below).
    static let nvmeBlockSize: UInt64 = 4096

    /// Puts the IPSW's root filesystem on NVMe namespace 1 and returns the BSD root device name.
    ///
    /// The `OS` component is a UDIF disk image (LZFSE-compressed chunks around an APFS container,
    /// usually behind a GPT). Expanded onto the namespace, the container is disk0s1 and its system
    /// volume disk0s1s1, the same names a restored iPhone uses. A plain APFS image is written as is.
    /// A marker records which build is installed so the multi-GiB expansion happens once.
    func installRootFilesystem(_ ctx: PrepareContext, disk: URL, size: UInt64) throws -> String {
        let dir = disk.deletingLastPathComponent()
        let marker = dir.appendingPathComponent("installed-build")
        let build = "\(ctx.ipsw.build) \(ctx.identity.deviceClass) preboot"
        if let installed = try? String(contentsOf: marker, encoding: .utf8),
           installed.hasPrefix(build + " "), let root = installed.split(separator: " ").last {
            return String(root)
        }
        guard let path = ctx.identity.path("OS"), let entry = ctx.ipsw.archive.entry(path) else {
            throw IPSWError.missingComponent("OS")
        }
        guard !path.hasSuffix(".aea") else {
            throw BackendError.incompatible("the root filesystem is AEA-encrypted; direct install needs its key")
        }

        // Read the DMG in place when the IPSW stores it uncompressed (the usual case); otherwise
        // inflate it next to the disk first.
        let source: RandomAccessSource
        var temporary: URL?
        if let range = try ctx.ipsw.archive.storedRange(of: entry) {
            source = try FileSource(url: ctx.ipsw.url, offset: range.offset, size: range.size)
        } else {
            let tmp = dir.appendingPathComponent("rootfs.dmg")
            try ctx.ipsw.archive.extract(entry, to: tmp) { ctx.progress("OS", $0 / 2) }
            source = try FileSource(url: tmp)
            temporary = tmp
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }

        let root: String
        if UDIFImage.isUDIF(source) {
            let image = try UDIFImage(source: source)
            if let apfs = image.apfsPartition {
                // The DMG's own GPT is for 512-byte sectors; the namespace uses 4096-byte blocks.
                // Write a GPT for the real block size and put the APFS container behind it, as a
                // restore would: disk0s1 is the container, disk0s1s1 its system volume.
                FileManager.default.createFile(atPath: disk.path, contents: nil)
                let handle = try FileHandle(forUpdating: disk)
                defer { try? handle.close() }
                try handle.truncate(atOffset: size)
                let layout = GPT.layout(diskSize: size, blockSize: Self.nvmeBlockSize)
                try GPT.write(to: handle, layout: layout)
                try image.expand(apfs, into: handle, at: layout.partitionOffset) { ctx.progress("OS", $0) }
                // launchd's first mount phase needs a Preboot volume holding the firmware folder
                // for the boot manifest hash (all zeros on the emulated machine, which has no
                // personalised manifest); a restore would have created it.
                let container = try APFSContainer(handle: handle, offset: layout.partitionOffset)
                try container.addVolume(name: "Preboot", role: .preboot, tree: APFSContainer.Tree(
                    directories: [String(repeating: "0", count: 96) + "/usr/standalone/firmware"]))
                root = "disk0s1s1"
            } else {
                try image.expand(to: disk) { ctx.progress("OS", $0) }
                root = "disk0s1"
            }
        } else {
            try ctx.ipsw.archive.extract(entry, to: disk) { ctx.progress("OS", $0) }
            root = "disk0s1"
        }
        let handle = try FileHandle(forWritingTo: disk)
        defer { try? handle.close() }
        if try handle.seekToEnd() < size { try handle.truncate(atOffset: size) }
        try "\(build) \(root)".write(to: marker, atomically: true, encoding: .utf8)
        return root
    }
}

extension InfernoBackend.Machine {
    /// iPhone 11 family. The kernel loader accepts iOS 13–18 and 26 (`t8030_init`); 14 is the most exercised.
    public static let t8030 = Self(name: "t8030", soc: "T8030",
                                      productTypes: ["iPhone12,1", "iPhone12,3", "iPhone12,5", "iPhone12,8"],
                                      referenceProduct: "iPhone12,1",
                                      supportedMajors: 13...18, extraMajors: [26], wellTestedMajor: 14, maxCPUs: 6)

    /// iPhone 6s / 6s Plus (A9, S8000). The machine has no version gate, so every release the A9
    /// shipped with is offered as experimental.
    public static let s8000 = Self(name: "s8000", soc: "S8000",
                                      productTypes: ["iPhone8,1", "iPhone8,2"], referenceProduct: "iPhone8,2",
                                      supportedMajors: 9...15, extraMajors: [], wellTestedMajor: nil, maxCPUs: 2)
}
