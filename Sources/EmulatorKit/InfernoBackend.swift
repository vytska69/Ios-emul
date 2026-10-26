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
        /// The S8000 model only builds with exactly 2 GiB of RAM ("Specified RAM size must be 2 GiB").
        var memoryRangeMB: ClosedRange<Int> = 1024...8192
    }

    public let machine: Machine

    public init(machine: Machine) { self.machine = machine }

    public var id: String { "inferno-\(machine.name)" }
    public var displayName: String { "Apple \(machine.name.uppercased()) machine" }
    public let upstream = "https://github.com/ChefKissInc/QEMUAppleSilicon"
    public var defaultMemoryMB: Int { min(max(4096, machine.memoryRangeMB.lowerBound), machine.memoryRangeMB.upperBound) }
    public var memoryRangeMB: ClosedRange<Int> { machine.memoryRangeMB }
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
        var kernel = try ctx.ipsw.extract(path: kernelPath, to: fwDir)
        // Kernel instruction patches (KernelPatches): booted from a raw copy, the IPSW's stays as is.
        let patchedKernel = fwDir.appendingPathComponent(kernel.lastPathComponent + ".patched")
        try? FileManager.default.removeItem(at: patchedKernel)
        let kernelReport: [String]?
        do { kernelReport = try KernelPatches.apply(build: ctx.ipsw.build, kernel: kernel, output: patchedKernel) }
        catch { kernelReport = ["not patched: \(error)"] }
        if let kernelReport {
            try? (kernelReport.joined(separator: "\n") + "\n").write(
                to: fwDir.appendingPathComponent("kernel-patches.txt"), atomically: true, encoding: .utf8)
        }
        if FileManager.default.fileExists(atPath: patchedKernel.path) { kernel = patchedKernel }
        ctx.progress("KernelCache", 1)

        // NVMe namespaces as laid out by the iPhone's ANS controller (wiki "Creating NVMe namespaces").
        let namespaces: [(file: String, nsid: Int, type: Int, size: UInt64, device: String)] = [
            ("nvme.1", 1, 1, 32 << 30, "nvme-ns"),     // system + data container
            ("nvme.2", 2, 2, 8 << 20, "nvme-ns"),      // firmware
            ("nvme.3", 3, 3, 128 << 10, "nvme-ns"),    // syscfg
            ("nvme.4", 4, 4, 8 << 10, "nvme-ns"),      // control bits
            ("nvram", 5, 5, 8 << 10, "apple-nvram"),   // NVRAM (holds auto-boot)
            ("nvme.6", 6, 6, 256 << 10, "nvme-ns"),    // effaceable storage (one 4 KiB block is too small to write)
            ("nvme.7", 7, 8, 1 << 20, "nvme-ns"),      // panic log
        ]
        var rootDevice: String?
        var deviceTree = files["DeviceTree"]!
        var firstBoot = false
        if direct {
            rootDevice = try installRootFilesystem(ctx, disk: dir.appendingPathComponent("nvme.1"), size: namespaces[0].size)
            let marker = dir.appendingPathComponent(Self.firstBootMarker)
            // A first boot that was cut short (the app closed or the machine was stopped before
            // the erase ran) used up the marker but left no system keybag, and every later boot
            // then ends in "Can't load the keybag... Time to die" and reboots in a loop. So the
            // erase is due again whenever the keybag is missing.
            firstBoot = fm.fileExists(atPath: marker.path)
                || Self.systemKeybagMissing(disk: dir.appendingPathComponent("nvme.1"), size: namespaces[0].size)
            try? fm.removeItem(at: marker)
            deviceTree = try directDeviceTree(from: deviceTree, dataInFirstMountPhase: firstBoot && ctx.firstBootErase)
        }
        for ns in namespaces { try ensureDisk(dir.appendingPathComponent(ns.file), sizeBytes: ns.size) }

        var props = ["\(machine.name)", "trustcache=\(files[trustcache]!.path)", "kaslr-off=true",
                     "boot-mode=\(ctx.bootMode.machineBootMode)"]
        if let ticket { props.append("ticket=\(ticket.path)") }
        if let seprom, let sepfw { props += ["sep-rom=\(seprom.path)", "sep-fw=\(sepfw.path)"] }
        // A restore leaves the system keybag (and the effaceable key that encrypts it) behind; a
        // direct install has neither, and the keybag boot task then reboots into recovery. The first
        // boot instead resumes an "Erase All Content": with oblit-inprogress set, finish-obliteration
        // (mobile_obliterator --init) reformats Data, creates the system keybag and clears the flag.
        // Needs qemu/patches/inferno/0009 (nvram-vars), which only the T8030 machine has; an unknown
        // machine property makes QEMU exit, and in-process on iOS that ends the app.
        if firstBoot && ctx.firstBootErase && machine.name == "t8030" { props.append("nvram-vars=oblit-inprogress=1") }
        // The simulated SEP starts in its ROM's bootstrap state; with sepfw-loaded set in the
        // DeviceTree (directDeviceTree) the kernel boots the firmware iBoot would have preloaded.
        // (qemu/patches/inferno/0006 also offers sep-preloaded=true, starting SEPOS directly, but
        // the kernel then panics with "SEP Boot Failure: unexpected status 1:2".)

        // With SEP emulated, one of the -smp CPUs becomes the SEP core.
        let cpus = min(ctx.cpuCount, machine.maxCPUs) + (seprom != nil ? 1 : 0)

        let vncPort: UInt16 = 5901
        let monitorPort: UInt16 = 1235
        var bootArgs = "debug=0x14e kextlog=0xffff serial=3"
        if ctx.verboseBoot { bootArgs += " -v" }
        bootArgs += " wdt=-1"
        // Spinlocks time out after 0.1 s by default; under emulation a lock holder on another
        // vCPU can take longer than that ("Ticket spinlock timeout" panics once userland runs).
        // 100 s, which still fits XNU's 32-bit LockTimeOut at the 24 MHz timebase.
        bootArgs += " slto_us=100000000"
        // AppleSEPKeyStore normally reads the device lock state from memory the SEP keeps up to
        // date, which the simulated SEP does not; with the cache off it asks the SEP each time
        // (qemu/patches/inferno/0023 answers). Without it iOS never sees the device as unlocked
        // since boot, and daemons that wait for that (assetsd, during data migration) hang.
        bootArgs += " aks-cache-device-state=0"
        if let rootDevice { bootArgs += " rd=\(rootDevice)" }
        let extra = ctx.extraBootArgs.trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty { bootArgs += " " + extra }
        let memory = min(max(ctx.memoryMB, memoryRangeMB.lowerBound), memoryRangeMB.upperBound)
        var args: [String] = [
            "-M", props.joined(separator: ","),
            "-cpu", "max", "-smp", "\(cpus)", "-m", "\(memory)M",
            "-kernel", kernel.path,
            "-dtb", deviceTree.path,
            "-append", bootArgs,
            "-serial", "file:\(dir.appendingPathComponent("serial.log").path)",
            "-monitor", "telnet:127.0.0.1:\(monitorPort),server,nowait",
            "-vnc", "127.0.0.1:\(vncPort - 5900)",
        ]
        #if os(iOS)
        // In-process on iOS the translation cache counts against the app's memory limit, next to
        // guest RAM; QEMU's 1 GiB default can get the app killed. See PrepareContext.translationCacheMB.
        // split-wx: QEMU's default code buffer is a MAP_JIT mapping, which iOS refuses (EPERM) to
        // apps without Apple's dynamic-codesigning entitlement, even with a debugger attached. JIT
        // enablers instead allow a writable mapping plus an executable alias of it (mach_vm_remap).
        // A JIT region prepared at launch (TXM devices) has a fixed size; the cache must fit in it.
        let cacheMB = QEMURunner.needsJIT && QEMURunner.preparedJITMB > 0 ? QEMURunner.preparedJITMB : ctx.translationCacheMB
        args += ["-accel", "tcg,tb-size=\(cacheMB)" + (QEMURunner.needsJIT ? ",split-wx=on" : "")]
        #endif
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

    /// Volumes a direct install provides: the IPSW's System volume and the Preboot, xART and Data
    /// volumes it adds (`APFSContainer.addVolume`). A restore also creates Hardware, Update and
    /// Baseband volumes; their fstab entries are dropped so launchd's mount phases do not fail
    /// looking for them.
    static let directInstallVolumes: Set<String> = ["system-vol", "preboot-vol", "xart-vol", "data-vol"]

    /// Written by a direct install; the next boot asks iOS to finish an obliteration (see prepare).
    static let firstBootMarker = "first-boot"

    /// Whether the installed system's Data volume lacks the system keybag that the first boot's
    /// erase creates. Unreadable disks count as not missing, so nothing is erased by mistake.
    static func systemKeybagMissing(disk: URL, size: UInt64) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: disk) else { return false }
        defer { try? handle.close() }
        let layout = GPT.layout(diskSize: size, blockSize: nvmeBlockSize)
        guard let container = try? APFSContainer(handle: handle, offset: layout.partitionOffset),
              let data = (try? container.volumes())?.first(where: { $0.role == APFSContainer.Role.data.rawValue })
        else { return false }
        return (try? container.fileExtents(volume: data.oid, path: "keybags/systembag.kb")) == nil
    }

    /// The gigalocker init_data_protection looks for on the emulated iPhone 11 (from its boot log).
    static let gigalockerName = "81879F33-B0F2-573A-AE12-6B517C322E33.gl"
    /// seputil creates a missing gigalocker as a preallocated, zero-filled file of this size and
    /// refuses (EEXIST) an existing one smaller than 6 MiB.
    static let gigalockerSize = 0x600000

    /// The Data volume a direct install starts with: the directories that must exist, with the
    /// owners and permissions iOS expects, before the daemons that populate /private/var run.
    static let dataVolumeTree: APFSContainer.Tree = {
        let mobile = APFSContainer.Attributes(uid: 501, gid: 501, mode: 0o755)
        let sticky = APFSContainer.Attributes(uid: 0, gid: 0, mode: 0o1777)
        return APFSContainer.Tree(
            directories: ["mobile/Library/Preferences", "mobile/Media", "mobile/Documents", "root/Library/Preferences",
                          "db", "logs", "log", "tmp", "run", "empty", "preferences", "containers", "keybags",
                          // mount-phase-2 bind-mounts this over /System/Library/Caches; on a
                          // restored device it is on the Hardware volume.
                          "hardware/FactoryData/System/Library/Caches/com.apple.factorydata",
                          "networkd", "wireless", "folders", "MobileSoftwareUpdate", "MobileAsset",
                          "installd", "staged_system_apps", "vm"],
            attributes: ["mobile": mobile, "mobile/Library": mobile, "mobile/Library/Preferences": mobile,
                         "mobile/Media": mobile, "mobile/Documents": mobile, "tmp": sticky,
                         "root": APFSContainer.Attributes(uid: 0, gid: 0, mode: 0o750)])
    }()

    /// The Data volume with the preference files for `tweaks` (see GuestTweaks).
    ///
    /// It also records data migration as done for `build` (`lastBuildVersion`). After the first-boot
    /// obliteration datamigrator still runs every DataClassMigrator ("erase" context) before
    /// SpringBoard starts; under emulation that hangs in CoreLocationMigrator.
    /// The IPSW's Multitouch payload as mtmergeprops reads it. The payload maps each personality
    /// (mt-merge-personality, e.g. "C1FC2,2") to the controller's boot sequence, an array of steps
    /// (payloads to load, register writes, the HIDSPI and interface configuration). mtmergeprops
    /// merges a dictionary per personality into the touch bootloader, which takes the sequence as
    /// "Constructed Firmware" (with a "Constructed Firmware Version") and rejects anything else.
    static func mtprops(fromMultitouch payload: Data) -> Data? {
        var xml = payload
        if payload.range(of: Data("<plist".utf8)) == nil {
            xml = Data(#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0">"#.utf8) + payload
                + Data("</plist>".utf8)
        }
        guard let root = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any]
        else { return nil }
        var personalities: [String: Any] = [:]
        for (name, value) in root {
            if let steps = value as? [Any] {
                personalities[name] = ["Constructed Firmware": steps, "Constructed Firmware Version": name]
            } else {
                personalities[name] = value
            }
        }
        return try? PropertyListSerialization.data(fromPropertyList: personalities, format: .xml, options: 0)
    }

    static func dataVolumeTree(tweaks: GuestTweaks, build: String, multitouch: Data? = nil) -> APFSContainer.Tree {
        var tree = dataVolumeTree
        // The touch controller's firmware and settings ("Multitouch" in the BuildManifest, a plist
        // keyed by the DeviceTree's mt-merge-personality). A restore installs it where
        // mtmergeprops finds it; mtmergeprops then hands it to the touch driver, which loads it
        // into the controller and only then powers the controller on. Without it every touch is
        // ignored.
        if let multitouch {
            let mobile = APFSContainer.Attributes(uid: 501, gid: 501, mode: 0o755)
            let dir = "mobile/Library/Application Support/Multitouch"
            tree.directories += ["mobile/Library/Application Support", dir]
            tree.attributes["mobile/Library/Application Support"] = mobile
            tree.attributes[dir] = mobile
            tree.files[dir + "/Multitouch.mtprops"] = mtprops(fromMultitouch: multitouch) ?? multitouch
            tree.attributes[dir + "/Multitouch.mtprops"] = APFSContainer.Attributes(uid: 501, gid: 501, mode: 0o644)
        }
        // CommCenter (the cellular service) aborts every few seconds without a modem, and
        // locationd's synchronous CoreTelephony calls to it never return, so the post-erase data
        // migration hangs in CoreLocationMigrator. Disabled in launchd's overrides, the service
        // is not started and those calls fail at once.
        // datamigrator runs every DataClassMigrator after the first-boot erase while backboardd
        // and SpringBoard wait; under emulation that takes most of the first start (10+ minutes
        // in CI). A fresh install has nothing to migrate: with the service off, the clients'
        // migration requests fail at once and they go on.
        if let disabled = try? PropertyListSerialization.data(fromPropertyList: ["com.apple.CommCenter": true, "com.apple.datamigrator": true],
                                                              format: .xml, options: 0) {
            tree.files["db/com.apple.xpc.launchd/disabled.plist"] = disabled
            tree.attributes["db/com.apple.xpc.launchd/disabled.plist"] = APFSContainer.Attributes(uid: 0, gid: 0, mode: 0o644)
        }
        let migrated: [String: Any] = [
            "lastBuildVersion": build, "LastSystemVersion": build,
            "DMUserDataDisposition": ["SyntheticDidUpgrade": false, "buildVersion": build],
        ]
        if let migration = try? PropertyListSerialization.data(fromPropertyList: migrated, format: .binary, options: 0) {
            tree.files["mobile/Library/Preferences/com.apple.migration.plist"] = migration
            tree.attributes["mobile/Library/Preferences/com.apple.migration.plist"] =
                APFSContainer.Attributes(uid: 501, gid: 501, mode: 0o600)
        }
        // Under emulation SpringBoard and the apps it launches start many times slower than on a
        // device; backboardd's watchdogs would kill them before they finish launching.
        let springboard = "mobile/Library/Preferences/com.apple.springboard.plist"
        if let data = try? PropertyListSerialization.data(fromPropertyList: ["BKNoWatchdogs": true], format: .binary, options: 0) {
            tree.files[springboard] = data
            tree.attributes[springboard] = APFSContainer.Attributes(uid: 501, gid: 501, mode: 0o600)
        }
        for (path, file) in tweaks.files() {
            tree.files[path] = file.data
            tree.attributes[path] = file.attributes
        }
        return tree
    }

    /// Writes a copy of the DeviceTree whose fstab describes the disk a direct install produces.
    ///
    /// With `dataInFirstMountPhase` the Data volume is mounted with System, Preboot and xART
    /// (fs_passno 1) instead of in mount-phase-2. The first-boot obliteration then finds it mounted
    /// on /private/var: it cannot delete and recreate it (newfs_apfs would need a media key the
    /// simulated SEP cannot wrap), so it keeps it and writes the system keybag there.
    func directDeviceTree(from file: URL, dataInFirstMountPhase: Bool = false) throws -> URL {
        let tree = try DeviceTree.parse(Data(contentsOf: file))
        let pruned = DeviceTree.serialize(tree) { node in
            // iBoot records that it loaded the SEP firmware; the kernel then asks the SEP ROM to
            // boot it, and seputil skips loading it again.
            if node.name == "sep", node.parent?.name == "arm-io" {
                var props = node.properties
                props["sepfw-loaded"] = Data([1, 0, 0, 0])
                return DeviceTreeNode(properties: props, placeholders: node.placeholders.subtracting(["sepfw-loaded"]),
                                      children: node.children)
            }
            // The emulated machine has no cellular modem. With the baseband node and chipset in the
            // DeviceTree iOS treats it as present: CommCenter aborts every few seconds (an uncaught
            // exception in its DesenseController) and locationd waits forever on CoreTelephony
            // calls to it, so the post-erase data migration never ends and SpringBoard never
            // starts. Without them iOS runs as on a Wi-Fi-only device.
            if node.path == "/baseband" { return nil }
            // AppleGenericMultitouchDecider (iOS 14) launches the DeviceTree's agm-primary driver,
            // AppleHIDTransportDeviceSPI, only when the authentication coprocessor vouches for the
            // touch controller; the emulated machine has none, so it launches agm-secondary,
            // AppleGenericMultitouchHIDSPI, which fails to start against Inferno's multitouch
            // model, and the screen ignores every touch. Name the primary driver in both.
            // That driver expects iBoot to have loaded the controller's firmware; without it the
            // HBPP bootloader takes it from the firmware personality that mtmergeprops merges
            // (KernelPatches). The bootloader first reads the chip's serial number from OTP, which
            // the model cannot answer ("Couldn't talk to chip"); an `otp-sn` of size 0 skips that.
            if node.name == "multi-touch", let primary = node.properties["agm-primary"],
               node.properties["agm-secondary"] != nil {
                var props = node.properties
                props["agm-secondary"] = primary
                props["otp-sn"] = Data(count: 8)
                return DeviceTreeNode(properties: props, placeholders: node.placeholders.subtracting(["agm-secondary"]),
                                      children: node.children)
            }
            if node.path == "/product", node.properties["baseband-chipset"] != nil {
                var props = node.properties
                props["baseband-chipset"] = nil
                return DeviceTreeNode(properties: props, placeholders: node.placeholders.subtracting(["baseband-chipset"]),
                                      children: node.children)
            }
            guard node.parent?.name == "fstab", node.parent?.parent?.name == "filesystems" else { return node }
            guard Self.directInstallVolumes.contains(node.name) else { return nil }
            if dataInFirstMountPhase, node.name == "data-vol" {
                var props = node.properties
                props["vol.fs_passno"] = Data([1, 0, 0, 0])
                return DeviceTreeNode(properties: props, placeholders: node.placeholders, children: node.children)
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
        let build = "\(ctx.ipsw.build) \(ctx.identity.deviceClass) data-slot1+premigrated+nocommcenter+preboot+xart6m+data2+oblit+sepfw+nowatchdog+swrender+nodm"
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
                let container = try APFSContainer(handle: handle, offset: layout.partitionOffset)
                // Without a GPU iOS draws with QuartzCore's CPU renderer only after these patches
                // (SharedCachePatches). The outcome goes next to the disk; a failure leaves the
                // system as the IPSW has it.
                let report: [String]
                do { report = try SharedCachePatches.apply(build: ctx.ipsw.build, container: container,
                                                                    skipSetup: ctx.guestTweaks.skipSetupAssistant) }
                catch { report = ["not patched: \(error)"] }
                try? (report.joined(separator: "\n") + "\n").write(
                    to: disk.deletingLastPathComponent().appendingPathComponent("shared-cache-patches.txt"),
                    atomically: true, encoding: .utf8)
                // mount-phase-2 mounts the Data volume (found by its role) on /private/var. It goes
                // in the slot after System, as on a restored iPhone: the first-boot obliteration
                // deletes it and newfs_apfs recreates and remounts it there (disk0s1s2, as the
                // rootfs fstab says), which fails while another volume holds that slot.
                try container.addVolume(name: "Data", role: .data, tree: Self.dataVolumeTree(tweaks: ctx.guestTweaks, build: ctx.ipsw.build,
                                                                                  multitouch: try? ctx.ipsw.decodedComponent("Multitouch", identity: ctx.identity)))
                // launchd's first mount phase needs a Preboot volume holding the firmware folder
                // for the boot manifest hash (all zeros on the emulated machine, which has no
                // personalised manifest); a restore would have created it.
                // The firmware folder also holds the SEP firmware: at boot init_data_protection
                // (seputil) loads /usr/standalone/firmware/sep-firmware.img4 into the SEP before it
                // sets up the gigalocker. A restore writes it personalised; here it is the IPSW's
                // payload, with the AP ticket as manifest when one was provided.
                let firmware = String(repeating: "0", count: 96) + "/usr/standalone/firmware"
                var prebootFiles: [String: Data] = [:]
                if let sep = try? ctx.ipsw.rawComponent("SEP", identity: ctx.identity) {
                    let ticket = ctx.externalAssets["apticket"].flatMap { try? Data(contentsOf: $0) }
                    prebootFiles[firmware + "/sep-firmware.img4"] = IMG4.wrap(payload: sep, manifest: ticket)
                }
                try container.addVolume(name: "Preboot", role: .preboot, tree: APFSContainer.Tree(
                    directories: [firmware], files: prebootFiles))
                // data-protection then needs the xART volume with the device's gigalocker, which a
                // restore asks the SEP to create. Lay it out the way seputil creates one: zeros,
                // the SEP fills it in.
                try container.addVolume(name: "xART", role: .xart, tree: APFSContainer.Tree(
                    directories: [], files: [Self.gigalockerName: Data(count: Self.gigalockerSize)]))
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
        FileManager.default.createFile(atPath: dir.appendingPathComponent(Self.firstBootMarker).path, contents: nil)
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
                                      supportedMajors: 9...15, extraMajors: [], wellTestedMajor: nil, maxCPUs: 2,
                                      memoryRangeMB: 2048...2048)
}
