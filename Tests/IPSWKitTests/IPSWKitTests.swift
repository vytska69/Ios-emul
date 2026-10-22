import XCTest
import Compression
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

    private func fullIPSW() throws -> URL {
        let url = tmp.appendingPathComponent("full.ipsw")
        try TestZip.write(to: url, entries: [
            ("BuildManifest.plist", try Self.manifest(version: "14.0", build: "18A5351d", types: ["iPhone12,1"],
                                                      board: "n104ap"), false),
            ("kernelcache.release.iphone12b", Self.im4p("krnl"), false),
            ("kernelcache.research.iphone12b", Self.im4p("krnl"), false),
            ("Firmware/all_flash/DeviceTree.n104ap.im4p", Self.im4p("dtre"), false),
            ("Firmware/038-44135-124.dmg.trustcache", Data([1]), false),
            ("038-44135-124.dmg", Data([2]), true),
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

private extension Data {
    mutating func le16(_ v: UInt16) { append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    mutating func le32(_ v: UInt32) { le16(UInt16(v & 0xFFFF)); le16(UInt16(v >> 16)) }
}
