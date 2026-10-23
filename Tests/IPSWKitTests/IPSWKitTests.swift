import XCTest
import Compression
import CryptoKit
@testable import IPSWKit
@testable import EmulatorKit

final class IPSWKitTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: ZIP

    func testStoredAndDeflatedEntries() throws {
        let text = Data(String(repeating: "hello ipsw ", count: 5000).utf8)
        let url = tmp.appendingPathComponent("a.zip")
        try TestZip.write(to: url, entries: [("plain.txt", text, false), ("dir/packed.txt", text, true)])

        let zip = try ZipArchive(url: url)
        XCTAssertEqual(zip.entries.count, 2)
        XCTAssertEqual(try zip.data(for: "plain.txt"), text)
        XCTAssertEqual(try zip.data(for: "dir/packed.txt"), text)
        XCTAssertEqual(zip.entry(named: "PACKED.TXT")?.path, "dir/packed.txt")
        XCTAssertEqual(try zip.head(of: zip.entry("dir/packed.txt")!, count: 5), Data("hello".utf8))

        let out = tmp.appendingPathComponent("out/packed.txt")
        try zip.extract(zip.entry("dir/packed.txt")!, to: out)
        XCTAssertEqual(try Data(contentsOf: out), text)
    }

    /// Written by Python's zipfile (zlib), like real IPSWs; Apple's decoder once reported
    /// OK instead of END on such a final chunk.
    func testZlibDeflatedEntryFromAnotherEncoder() throws {
        let url = Bundle.module.url(forResource: "zlib-deflate", withExtension: "zip", subdirectory: "Fixtures")!
        let zip = try ZipArchive(url: url)
        let data = try zip.data(for: "BuildManifest.plist")
        XCTAssertEqual(data.count, 573_728)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "082c6f1ba69e6889a8d695ee6a91671c56c2b87122f84f91498d2f79438b4329")
    }

    func testRejectsNonZip() throws {
        let url = tmp.appendingPathComponent("junk.ipsw")
        try Data(repeating: 7, count: 1000).write(to: url)
        XCTAssertThrowsError(try ZipArchive(url: url))
    }

    // MARK: IMG4 / compression

    func testIM4PParsingAndLZFSE() throws {
        let kernel = Data((0..<20000).map { UInt8($0 % 251) })
        let compressed = try TestZip.lzfse(kernel)
        let im4p = DER.seq([DER.ia5("IM4P"), DER.ia5("krnl"), DER.ia5("KernelCacheBuilder"), DER.octets(compressed),
                            DER.seq([DER.int(1), DER.int(kernel.count)])])
        let parsed = try IM4P(im4p)
        XCTAssertEqual(parsed.type, "krnl")
        XCTAssertFalse(parsed.isEncrypted)
        XCTAssertEqual(parsed.uncompressedSize, kernel.count)
        XCTAssertEqual(try parsed.decodedPayload(), kernel)

        let wrapped = DER.seq([DER.ia5("IMG4"), im4p])
        XCTAssertEqual(try IM4P(wrapped).type, "krnl")
        XCTAssertTrue(IM4P.looksLikeIMG4(wrapped))
    }

    func testEncryptedIM4PIsRefused() throws {
        let im4p = DER.seq([DER.ia5("IM4P"), DER.ia5("ibot"), DER.ia5("iBoot"), DER.octets(Data([1, 2, 3])),
                            DER.octets(Data([9, 9]))])
        XCTAssertThrowsError(try IM4P(im4p).decodedPayload())
    }

    func testLZSSLiteralsAndBackReference() {
        // "abcabcabc": flag bits 1,1,1,0 = three literals then one back-reference.
        // The window starts at N-F = 4078, so "abc" lives at 4078...4080; length nibble 3 copies 3 + 3 bytes.
        let pos = 4078
        let src = Data([0b0000_0111, 0x61, 0x62, 0x63, UInt8(pos & 0xFF), UInt8(((pos >> 4) & 0xF0) | 3)])
        XCTAssertEqual(Decompressor.lzss(src, expectedSize: 9), Data("abcabcabc".utf8))
    }

    // MARK: UDIF

    func testUDIFExpandsRawZeroAndLZFSEChunks() throws {
        let sector = 512
        let rawPart = Data(repeating: 0xAB, count: sector * 2)                       // sectors 0-1
        let apfs = Data("NXSB".utf8) + Data((0..<(sector * 4 - 4)).map { UInt8($0 % 13) }) // sectors 3-6
        let lz = try TestZip.lzfse(apfs)
        let image = try TestUDIF.build(sectors: 8, partitions: [
            ("GUID Partition Table : 1", [(1, 0, 2, rawPart)]),
            ("Apple_APFS : 2", [(0, 2, 1, Data()), (0x8000_0007, 3, 4, lz), (0xFFFF_FFFF, 7, 0, Data())]),
        ])
        let url = tmp.appendingPathComponent("os.dmg")
        try image.write(to: url)

        let source = try FileSource(url: url)
        XCTAssertTrue(UDIFImage.isUDIF(source))
        let udif = try UDIFImage(source: source)
        XCTAssertEqual(udif.size, 8 * 512)
        XCTAssertTrue(udif.hasPartitionMap)
        let out = tmp.appendingPathComponent("disk")
        try udif.expand(to: out)
        let disk = try Data(contentsOf: out)
        XCTAssertEqual(disk.count, 8 * 512)
        XCTAssertEqual(disk.prefix(sector * 2), rawPart)
        XCTAssertEqual(disk.subdata(in: (sector * 2)..<(sector * 3)), Data(count: sector))
        XCTAssertEqual(disk.subdata(in: (sector * 3)..<(sector * 7)), apfs)
    }

    func testGPTFor4KBlocksAndAPFSPartitionPlacement() throws {
        let size: UInt64 = 64 << 20
        let url = tmp.appendingPathComponent("disk4k")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        let layout = GPT.layout(diskSize: size, blockSize: 4096)
        XCTAssertEqual(layout.firstUsable, 256, "1 MiB aligned on 4 KiB blocks")
        try GPT.write(to: handle, layout: layout)

        // Put the APFS chunk of a UDIF image behind the table.
        let apfs = Data("NXSB".utf8) + Data(repeating: 7, count: 2044)
        let dmg = try TestUDIF.build(sectors: 6, partitions: [
            ("GUID Partition Table : 1", [(1, 0, 2, Data(repeating: 0xAB, count: 1024))]),
            ("Apple_APFS : 2", [(1, 2, 4, apfs)]),
        ])
        let dmgURL = tmp.appendingPathComponent("p.dmg"); try dmg.write(to: dmgURL)
        let image = try UDIFImage(source: try FileSource(url: dmgURL))
        try image.expand(try XCTUnwrap(image.apfsPartition), into: handle, at: layout.partitionOffset)
        try handle.close()

        let disk = try FileHandle(forReadingFrom: url)
        func block(_ lba: UInt64, _ n: Int = 4096) throws -> Data { try disk.seek(toOffset: lba * 4096); return disk.readData(ofLength: n) }
        let mbr = try block(0)
        XCTAssertEqual(mbr[450], 0xEE); XCTAssertEqual(mbr[510], 0x55); XCTAssertEqual(mbr[511], 0xAA)

        for (lba, isPrimary) in [(UInt64(1), true), (layout.diskBlocks - 1, false)] {
            var header = try block(lba, 92)
            XCTAssertEqual(header.prefix(8), Data("EFI PART".utf8))
            let stored = header.subdata(in: 16..<20).withUnsafeBytes { $0.load(as: UInt32.self) }
            header.replaceSubrange(16..<20, with: Data(count: 4))
            var crc = CRC32(); crc.update(header)
            XCTAssertEqual(crc.value, UInt32(littleEndian: stored), isPrimary ? "primary" : "backup")
        }
        let entry = try block(2, 128)
        XCTAssertEqual(Array(entry.prefix(16)), GPT.apfsType)
        XCTAssertEqual(entry.subdata(in: 32..<40).withUnsafeBytes { $0.load(as: UInt64.self) }, 256)
        XCTAssertEqual(try block(layout.firstUsable, apfs.count), apfs)
    }

    func testStoredZipMemberIsReadInPlace() throws {
        let payload = Data((0..<10_000).map { UInt8($0 % 251) })
        let url = tmp.appendingPathComponent("s.zip")
        try TestZip.write(to: url, entries: [("a.bin", payload, false), ("b.bin", payload, true)])
        let zip = try ZipArchive(url: url)
        let range = try XCTUnwrap(try zip.storedRange(of: zip.entry("a.bin")!))
        XCTAssertEqual(try FileSource(url: url, offset: range.offset, size: range.size).read(at: 100, count: 10),
                       payload.subdata(in: 100..<110))
        XCTAssertNil(try zip.storedRange(of: zip.entry("b.bin")!), "deflated members need inflating first")
    }

    // MARK: DeviceTree + coverage

    func testDeviceTreeParsing() throws {
        let tree = try DeviceTree.parse(Self.sampleTree())
        XCTAssertEqual(tree.name, "device-tree")
        XCTAssertEqual(tree.node(at: "arm-io/uart0")?.compatible, ["uart-1,samsung"])
        XCTAssertEqual(tree.node(at: "arm-io/uart0")?.path, "/arm-io/uart0")
        XCTAssertEqual(tree.node(at: "arm-io/aic")?.u32("#main-cpus"), 6)
        XCTAssertTrue(tree.node(at: "arm-io")!.placeholders.contains("ranges"))
        // Also accepted wrapped in an IM4P, as it ships in the IPSW.
        let wrapped = DER.seq([DER.ia5("IM4P"), DER.ia5("dtre"), DER.ia5(""), DER.octets(Self.sampleTree())])
        XCTAssertEqual(try DeviceTree.parse(wrapped).children.count, 2)
    }

    func testDeviceTreeRoundTripsAndRemovesNodes() throws {
        let tree = try DeviceTree.parse(Self.sampleTree())
        let same = try DeviceTree.parse(DeviceTree.serialize(tree))
        XCTAssertEqual(same.node(at: "arm-io/uart0")?.compatible, ["uart-1,samsung"])
        XCTAssertTrue(same.node(at: "arm-io")!.placeholders.contains("ranges"))
        XCTAssertEqual(same.node(at: "arm-io/aic")?.u32("#main-cpus"), 6)

        let pruned = try DeviceTree.parse(DeviceTree.serialize(tree) { $0.name == "pmgr" })
        XCTAssertNil(pruned.node(at: "arm-io/pmgr"))
        XCTAssertNotNil(pruned.node(at: "arm-io/aic"))
        XCTAssertTrue(DeviceTree.describe(pruned).contains { $0.contains("compatible = uart-1,samsung") })
    }

    func testDeviceTreeRejectsGarbage() {
        XCTAssertThrowsError(try DeviceTree.parse(Data([0xFF, 0xFF, 0xFF, 0xFF, 1, 0, 0, 0])))
    }

    func testCoverageRanksMachinesAndFlagsMissingCriticalHardware() throws {
        let tree = try DeviceTree.parse(Self.sampleTree())
        let known: [String: Set<String>] = ["a": ["uart0", "aic"], "b": ["uart0"]]
        let report = HardwareCoverage.analyze(tree, machines: known)
        XCTAssertEqual(report.map(\.machine), ["a", "b"])
        XCTAssertEqual(report[0].peripherals.count, 3)
        XCTAssertEqual(report[0].emulatedCount, 2)
        XCTAssertEqual(report[1].missingBootCritical.map(\.name), ["aic", "pmgr"])
        XCTAssertFalse(HardwareCoverage.knownNodes["t8030"]?.isEmpty ?? true, "bundled Inferno node list loads")
    }

    /// device-tree { filesystems { fstab { system-vol, data-vol, preboot-vol, xart-vol } } }
    static func fstabTree() -> Data {
        func prop(_ name: String, _ value: Data) -> Data {
            var out = Data(name.utf8) + Data(count: 32 - name.utf8.count)
            out.append(contentsOf: withUnsafeBytes(of: UInt32(value.count).littleEndian, Array.init))
            return out + value + Data(count: (4 - value.count % 4) % 4)
        }
        func node(_ name: String, _ children: [Data]) -> Data {
            var out = Data(withUnsafeBytes(of: UInt32(1).littleEndian, Array.init))
            out.append(contentsOf: withUnsafeBytes(of: UInt32(children.count).littleEndian, Array.init))
            return out + prop("name", Data(name.utf8) + Data([0])) + children.reduce(Data(), +)
        }
        let fstab = node("fstab", ["system-vol", "data-vol", "preboot-vol", "xart-vol"].map { node($0, []) })
        // An ephemeral variant: node with name + vol.fs_ephemeral.
        var eph = Data(withUnsafeBytes(of: UInt32(2).littleEndian, Array.init))
        eph.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian, Array.init))
        eph += prop("name", Data("ephemeral-diag-data-vol".utf8) + Data([0])) + prop("vol.fs_ephemeral", Data())
        let diag = node("fstab-ephemeral-diag-data", [eph])
        return node("device-tree", [node("filesystems", [fstab, diag])])
    }

    /// device-tree { arm-io { aic, uart0, pmgr }, cpus } in Apple's binary format.
    static func sampleTree() -> Data {
        func prop(_ name: String, _ value: Data, placeholder: Bool = false) -> Data {
            var out = Data(name.utf8) + Data(count: 32 - name.utf8.count)
            let len = UInt32(value.count) | (placeholder ? 0x8000_0000 : 0)
            out.append(contentsOf: withUnsafeBytes(of: len.littleEndian, Array.init))
            out.append(value)
            out.append(Data(count: (4 - value.count % 4) % 4))
            return out
        }
        func str(_ s: String) -> Data { Data(s.utf8) + Data([0]) }
        func u32(_ v: UInt32) -> Data { Data(withUnsafeBytes(of: v.littleEndian, Array.init)) }
        func node(_ props: [Data], _ children: [Data]) -> Data {
            u32(UInt32(props.count)) + u32(UInt32(children.count)) + props.reduce(Data(), +) + children.reduce(Data(), +)
        }
        let reg = Data(count: 16)
        let aic = node([prop("name", str("aic")), prop("reg", reg), prop("#main-cpus", u32(6))], [])
        let uart = node([prop("name", str("uart0")), prop("compatible", str("uart-1,samsung")), prop("reg", reg)], [])
        let pmgr = node([prop("name", str("pmgr")), prop("reg", reg)], [])
        let armIO = node([prop("name", str("arm-io")), prop("ranges", Data(count: 8), placeholder: true)], [aic, uart, pmgr])
        let cpus = node([prop("name", str("cpus"))], [])
        return node([prop("name", str("device-tree"))], [armIO, cpus])
    }

    func testBootMilestones() {
        let log = "iBoot\nDarwin Kernel Version 20.0.0\nBSD root: md0, major 2\npanic(cpu 0 caller 0x1): AIC\n"
        XCTAssertEqual(BootMilestone.furthest(in: log), .rootMounted)
        XCTAssertEqual(BootMilestone.panic(in: log), "panic(cpu 0 caller 0x1): AIC")
        XCTAssertNil(BootMilestone.furthest(in: "nothing here"))
    }

    // MARK: Firmware catalog

    func testCatalogPrefersExactSupportedVersion() throws {
        let json = """
        {"firmwares":[
         {"identifier":"iPhone12,1","version":"17.5","buildid":"21F79","url":"https://x/17.5.ipsw"},
         {"identifier":"iPhone12,1","version":"17.4","buildid":"21E219","url":"https://x/17.4.ipsw"},
         {"identifier":"iPhone12,1","version":"14.0","buildid":"18A373","url":"https://x/14.0.ipsw"},
         {"identifier":"iPhone12,1","version":"12.4","buildid":"16G77","url":"https://x/12.4.ipsw"}]}
        """
        struct Device: Decodable { let firmwares: [FirmwareCatalog.Firmware] }
        let list = try JSONDecoder().decode(Device.self, from: Data(json.utf8)).firmwares
        let iphone11 = DeviceDatabase.shared.device("iPhone12,1")

        let exact = FirmwareCatalog.best(FirmwareCatalog.rank(list, version: "17.4", device: iphone11,
                                                              registry: .shared))
        XCTAssertEqual(exact?.firmware.buildid, "21E219")
        XCTAssertEqual(exact?.exactVersion, true)
        XCTAssertEqual(exact?.backendID, "inferno-t8030")

        // No 17.2 listed: newest build of the same major release.
        let sameMajor = FirmwareCatalog.best(FirmwareCatalog.rank(list, version: "17.2", device: iphone11,
                                                                  registry: .shared))
        XCTAssertEqual(sameMajor?.firmware.version, "17.5")
        XCTAssertEqual(sameMajor?.exactVersion, false)

        // iOS 14 is the fully supported release, and iOS 12 is not runnable at all.
        XCTAssertEqual(FirmwareCatalog.best(FirmwareCatalog.rank(list, version: "14.0", device: iphone11,
                                                                 registry: .shared))?.compatibility, .supported)
        XCTAssertNil(FirmwareCatalog.best(FirmwareCatalog.rank(list, version: "12.4", device: iphone11,
                                                               registry: .shared)))
    }

    // MARK: Manifest + compatibility

    func testManifestAndCompatibility() throws {
        let url = tmp.appendingPathComponent("iPhone11.ipsw")
        try TestZip.write(to: url, entries: [
            ("BuildManifest.plist", try Self.manifest(version: "14.0", build: "18A5351d", types: ["iPhone12,1"],
                                                      board: "n104ap"), true),
            ("kernelcache.release.iphone12b", Self.im4p("krnl"), false),
        ])
        let ipsw = try IPSW(url: url)
        XCTAssertEqual(ipsw.version, "14.0")
        XCTAssertEqual(ipsw.devices.first?.name, "iPhone 11")
        XCTAssertEqual(ipsw.devices.first?.soc?.id, "T8030")
        XCTAssertEqual(ipsw.manifest.identity(for: "n104ap")?.isErase, true)
        XCTAssertEqual(ipsw.imageFormat, "IMG4")

        let report = BackendRegistry.shared.report(for: ipsw)
        XCTAssertEqual(report.best?.backend?.id, "inferno-t8030")
        XCTAssertEqual(report.best?.compatibility, .supported)
    }

    func testNewerIOSIsExperimentalAndUnknownMajorUnsupported() throws {
        for (version, expectRunnable) in [("17.4", true), ("12.4", false)] {
            let url = tmp.appendingPathComponent("v\(version).ipsw")
            try TestZip.write(to: url, entries: [
                ("BuildManifest.plist", try Self.manifest(version: version, build: "X", types: ["iPhone12,1"],
                                                          board: "n104ap"), false),
            ])
            let row = BackendRegistry.shared.report(for: try IPSW(url: url)).rows[0]
            XCTAssertEqual(row.compatibility.isRunnable, expectRunnable, version)
        }
    }

    func testUnsupportedSoCExplainsWhy() throws {
        let url = tmp.appendingPathComponent("iPhone15.ipsw")
        try TestZip.write(to: url, entries: [
            ("BuildManifest.plist", try Self.manifest(version: "18.0", build: "22A3354", types: ["iPhone16,1"],
                                                      board: "d83ap"), false),
        ])
        let report = BackendRegistry.shared.report(for: try IPSW(url: url))
        XCTAssertNil(report.best)
        guard case .unsupported(let why) = report.rows[0].compatibility else { return XCTFail() }
        XCTAssertTrue(why.contains("A17 Pro"), why)
    }

    func testInfernoPrepareBuildsQEMUArguments() throws {
        let ipsw = try IPSW(url: try fullIPSW())
        let vm = tmp.appendingPathComponent("vm")
        let config = try InfernoBackend(machine: .t8030).prepare(context(ipsw, vm: vm, assets: [:]))
        let args = config.arguments
        func value(after flag: String) -> String { args[args.firstIndex(of: flag)! + 1] }

        XCTAssertEqual(value(after: "-m"), "2048M")
        XCTAssertEqual(value(after: "-smp"), "2")
        XCTAssertTrue(value(after: "-M").hasPrefix("t8030,trustcache="), value(after: "-M"))
        XCTAssertTrue(value(after: "-M").contains("boot-mode=auto"))
        XCTAssertFalse(value(after: "-M").contains("sep-rom"))
        XCTAssertTrue(value(after: "-kernel").hasSuffix("kernelcache.research.iphone12b"), "research kernel preferred")
        XCTAssertTrue(value(after: "-initrd").hasSuffix("038-44135-124.dmg"))
        XCTAssertTrue(args.contains { $0.hasPrefix("apple-nvram,drive=drive.5,bus=nvme-bus.0,nsid=5") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: vm.appendingPathComponent("nvme.1").path))
    }

    func testInfernoSEPAddsCoreAndNeedsBothFiles() throws {
        let ipsw = try IPSW(url: try fullIPSW())
        let seprom = tmp.appendingPathComponent("seprom"), sepfw = tmp.appendingPathComponent("sepfw")
        try Data([0]).write(to: seprom); try Data([0]).write(to: sepfw)

        XCTAssertThrowsError(try InfernoBackend(machine: .t8030)
            .prepare(context(ipsw, vm: tmp.appendingPathComponent("a"), assets: ["seprom": seprom])))

        let config = try InfernoBackend(machine: .t8030)
            .prepare(context(ipsw, vm: tmp.appendingPathComponent("b"), assets: ["seprom": seprom, "sepfw": sepfw]))
        let args = config.arguments
        XCTAssertEqual(args[args.firstIndex(of: "-smp")! + 1], "3")
        XCTAssertTrue(args[args.firstIndex(of: "-M")! + 1].contains("sep-fw="))
    }

    func testInfernoDirectInstallWritesRootFilesystemOnce() throws {
        let ipsw = try IPSW(url: try fullIPSW())
        let vm = tmp.appendingPathComponent("direct")
        var ctx = context(ipsw, vm: vm, assets: [:])
        ctx = PrepareContext(ipsw: ipsw, identity: ctx.identity, device: ctx.device, workDirectory: vm,
                             externalAssets: [:], bootMode: .direct, memoryMB: 2048, cpuCount: 2)
        let args = try InfernoBackend(machine: .t8030).prepare(ctx).arguments
        XCTAssertFalse(args.contains("-initrd"), "direct boot does not use the restore ramdisk")
        let machine = args[args.firstIndex(of: "-M")! + 1]
        XCTAssertTrue(machine.contains("boot-mode=exit_recovery"), machine)
        XCTAssertTrue(machine.contains("038-44087-125.dmg.trustcache"), "OS trust cache, not the restore one")
        let dtb = try DeviceTree.parse(Data(contentsOf: URL(fileURLWithPath: args[args.firstIndex(of: "-dtb")! + 1])))
        XCTAssertEqual(dtb.node(at: "filesystems/fstab")?.children.map(\.name), ["system-vol", "data-vol", "preboot-vol", "xart-vol"],
                       "volumes a direct install lacks are dropped from the fstab")
        XCTAssertNil(dtb.node(at: "filesystems/fstab/data-vol")?.properties["vol.fs_ephemeral"],
                     "Data stays the real volume the install writes")

        let disk = vm.appendingPathComponent("nvme.1")
        let head = try FileHandle(forReadingFrom: disk).read(upToCount: 4)
        XCTAssertEqual(head, Data("NXSB".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: disk.path)[.size] as? UInt64, 32 << 30)

        // A second prepare keeps the installed disk (and anything the guest wrote to it).
        let handle = try FileHandle(forWritingTo: disk)
        try handle.seek(toOffset: 0); handle.write(Data("USER".utf8)); try handle.close()
        _ = try InfernoBackend(machine: .t8030).prepare(ctx)
        XCTAssertEqual(try FileHandle(forReadingFrom: disk).read(upToCount: 4), Data("USER".utf8))
    }

    private func fullIPSW() throws -> URL {
        let url = tmp.appendingPathComponent("full.ipsw")
        try TestZip.write(to: url, entries: [
            ("BuildManifest.plist", try Self.manifest(version: "14.0", build: "18A5351d", types: ["iPhone12,1"],
                                                      board: "n104ap"), false),
            ("kernelcache.release.iphone12b", Self.im4p("krnl"), false),
            ("kernelcache.research.iphone12b", Self.im4p("krnl"), false),
            ("Firmware/all_flash/DeviceTree.n104ap.im4p",
             DER.seq([DER.ia5("IM4P"), DER.ia5("dtre"), DER.ia5(""), DER.octets(Self.fstabTree())]), false),
            ("Firmware/038-44135-124.dmg.trustcache", Data([1]), false),
            ("038-44135-124.dmg", Data([2]), true),
            ("Firmware/038-44087-125.dmg.trustcache", Data([3]), false),
            ("038-44087-125.dmg", Data("NXSB-apfs-container".utf8), true),
        ])
        return url
    }

    private func context(_ ipsw: IPSW, vm: URL, assets: [String: URL]) -> PrepareContext {
        PrepareContext(ipsw: ipsw, identity: ipsw.manifest.identity()!, device: ipsw.devices[0], workDirectory: vm,
                       externalAssets: assets, bootMode: .auto, memoryMB: 2048, cpuCount: 2)
    }

    static func im4p(_ type: String) -> Data {
        DER.seq([DER.ia5("IM4P"), DER.ia5(type), DER.ia5(""), DER.octets(Data("payload".utf8))])
    }

    static func manifest(version: String, build: String, types: [String], board: String) throws -> Data {
        let info = { (p: String) in ["Info": ["Path": p]] }
        let plist: [String: Any] = [
            "ProductVersion": version, "ProductBuildVersion": build, "SupportedProductTypes": types,
            "BuildIdentities": [
                ["Info": ["DeviceClass": board, "Variant": "Customer Software Update", "RestoreBehavior": "Update"],
                 "Manifest": [:] as [String: Any]],
                ["Info": ["DeviceClass": board, "Variant": "Customer Erase Install (IPSW)", "RestoreBehavior": "Erase"],
                 "ApBoardID": "0x04", "ApChipID": "0x8030",
                 "Manifest": [
                    "KernelCache": info("kernelcache.release.iphone12b"),
                    "DeviceTree": info("Firmware/all_flash/DeviceTree.\(board).im4p"),
                    "RestoreRamDisk": info("038-44135-124.dmg"),
                    "RestoreTrustCache": info("Firmware/038-44135-124.dmg.trustcache"),
                    "StaticTrustCache": info("Firmware/038-44087-125.dmg.trustcache"),
                    "OS": info("038-44087-125.dmg"),
                 ]],
            ],
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}

// MARK: - Fixtures

enum DER {
    static func tlv(_ tag: UInt8, _ body: Data) -> Data {
        var out = Data([tag])
        if body.count < 0x80 {
            out.append(UInt8(body.count))
        } else {
            var len = body.count, bytes: [UInt8] = []
            while len > 0 { bytes.insert(UInt8(len & 0xFF), at: 0); len >>= 8 }
            out.append(0x80 | UInt8(bytes.count)); out.append(contentsOf: bytes)
        }
        return out + body
    }
    static func seq(_ items: [Data]) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    static func ia5(_ s: String) -> Data { tlv(0x16, Data(s.utf8)) }
    static func octets(_ d: Data) -> Data { tlv(0x04, d) }
    static func int(_ v: Int) -> Data {
        var bytes: [UInt8] = []
        var x = v
        repeat { bytes.insert(UInt8(x & 0xFF), at: 0); x >>= 8 } while x > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, Data(bytes))
    }
}

enum TestZip {
    static func lzfse(_ data: Data) throws -> Data { try encode(data, COMPRESSION_LZFSE) }

    static func deflate(_ data: Data) throws -> Data { try encode(data, COMPRESSION_ZLIB) }

    private static func encode(_ data: Data, _ algo: compression_algorithm) throws -> Data {
        let cap = data.count + 4096
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { dst.deallocate() }
        let n = data.withUnsafeBytes {
            compression_encode_buffer(dst, cap, $0.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, algo)
        }
        guard n > 0 else { throw DecompressionError.corrupt("test encode") }
        return Data(bytes: dst, count: n)
    }

    /// Writes a classic (non-ZIP64) archive; `deflate` picks method 8 instead of 0.
    static func write(to url: URL, entries: [(String, Data, Bool)]) throws {
        var body = Data(), central = Data()
        for (name, data, deflate) in entries {
            var crc = CRC32(); crc.update(data)
            let payload = deflate ? try self.deflate(data) : data
            let offset = UInt32(body.count)
            let nameData = Data(name.utf8)
            var local = Data()
            local.le32(0x0403_4B50); local.le16(20); local.le16(0); local.le16(deflate ? 8 : 0)
            local.le16(0); local.le16(0); local.le32(crc.value)
            local.le32(UInt32(payload.count)); local.le32(UInt32(data.count))
            local.le16(UInt16(nameData.count)); local.le16(0)
            body += local + nameData + payload

            var cd = Data()
            cd.le32(0x0201_4B50); cd.le16(20); cd.le16(20); cd.le16(0); cd.le16(deflate ? 8 : 0)
            cd.le16(0); cd.le16(0); cd.le32(crc.value)
            cd.le32(UInt32(payload.count)); cd.le32(UInt32(data.count))
            cd.le16(UInt16(nameData.count)); cd.le16(0); cd.le16(0); cd.le16(0); cd.le16(0); cd.le32(0)
            cd.le32(offset)
            central += cd + nameData
        }
        var eocd = Data()
        eocd.le32(0x0605_4B50); eocd.le16(0); eocd.le16(0)
        eocd.le16(UInt16(entries.count)); eocd.le16(UInt16(entries.count))
        eocd.le32(UInt32(central.count)); eocd.le32(UInt32(body.count)); eocd.le16(0)
        try (body + central + eocd).write(to: url)
    }
}

/// Builds a minimal UDIF image: data fork, XML plist with one "blkx" table per partition, koly trailer.
enum TestUDIF {
    /// Chunks are (type, first sector, sector count, stored bytes).
    static func build(sectors: UInt64, partitions: [(String, [(UInt32, UInt64, UInt64, Data)])]) throws -> Data {
        var fork = Data()
        var blkx: [[String: Any]] = []
        for (name, chunks) in partitions {
            var mish = Data()
            mish.be32(0x6D69_7368); mish.be32(1)
            mish.be64(0); mish.be64(sectors); mish.be64(0)       // first sector 0, count, data offset 0
            mish.be32(0); mish.be32(0)
            mish.append(Data(count: 24 + 136))                    // reserved + checksum
            mish.be32(UInt32(chunks.count))
            for (type, sector, count, bytes) in chunks {
                mish.be32(type); mish.be32(0)
                mish.be64(sector); mish.be64(count)
                mish.be64(UInt64(fork.count)); mish.be64(UInt64(bytes.count))
                fork.append(bytes)
            }
            blkx.append(["Name": name, "Data": mish])
        }
        let xml = try PropertyListSerialization.data(fromPropertyList: ["resource-fork": ["blkx": blkx]],
                                                     format: .xml, options: 0)
        var koly = Data()
        koly.be32(0x6B6F_6C79); koly.be32(4); koly.be32(512); koly.be32(1)
        koly.be64(0); koly.be64(0); koly.be64(UInt64(fork.count))    // running fork, data fork offset, length
        koly.append(Data(count: 216 - koly.count))
        koly.be64(UInt64(fork.count)); koly.be64(UInt64(xml.count))   // XML offset, length
        koly.append(Data(count: 492 - koly.count))
        koly.be64(sectors)
        koly.append(Data(count: 512 - koly.count))
        return fork + xml + koly
    }
}

private extension Data {
    mutating func be32(_ v: UInt32) { append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
    mutating func be64(_ v: UInt64) { be32(UInt32(v >> 32)); be32(UInt32(v & 0xFFFF_FFFF)) }
    mutating func le16(_ v: UInt16) { append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    mutating func le32(_ v: UInt32) { le16(UInt16(v & 0xFFFF)); le16(UInt16(v >> 16)) }
}
