import Foundation
import Compression

/// Reader for Apple UDIF disk images (.dmg), the container IPSWs use for root filesystems and
/// ramdisks. The image is a run of block chunks (raw, zero-fill, zlib, LZFSE, …) described by
/// a "koly" trailer and an XML plist of "blkx" partition tables.
public struct UDIFImage {
    public struct Chunk {
        public let type: UInt32
        public let sector: UInt64        // absolute sector in the expanded image
        public let sectorCount: UInt64
        public let compressedOffset: UInt64
        public let compressedLength: UInt64
    }

    public struct Partition {
        public let name: String          // e.g. "Apple_APFS : 4"
        public let chunks: [Chunk]
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case notUDIF
        case malformed(String)
        case unsupportedChunk(UInt32)

        public var description: String {
            switch self {
            case .notUDIF: return "Not a UDIF disk image (no koly trailer)"
            case .malformed(let s): return "Malformed UDIF image: \(s)"
            case .unsupportedChunk(let t): return String(format: "Unsupported UDIF chunk type 0x%08x", t)
            }
        }
    }

    public static let sectorSize: UInt64 = 512

    public let sectorCount: UInt64
    public let dataForkOffset: UInt64
    public let partitions: [Partition]
    private let source: RandomAccessSource

    public var size: UInt64 { sectorCount * Self.sectorSize }

    /// True when the image carries its own partition map (GPT/MBR), so its filesystem is a
    /// partition (disk0s1) rather than the whole disk.
    public var hasPartitionMap: Bool {
        partitions.contains { $0.name.contains("GUID Partition") || $0.name.contains("Master Boot Record") }
    }

    public static func isUDIF(_ source: RandomAccessSource) -> Bool {
        guard source.size >= 512, let t = try? source.read(at: source.size - 512, count: 4) else { return false }
        return t == Data("koly".utf8)
    }

    public init(source: RandomAccessSource) throws {
        self.source = source
        guard source.size >= 512 else { throw Error.notUDIF }
        let trailer = try source.read(at: source.size - 512, count: 512)
        let t = ByteReader(trailer)
        guard t.u32be(at: 0) == 0x6B6F_6C79 else { throw Error.notUDIF } // "koly"
        dataForkOffset = t.u64be(at: 24)
        let xmlOffset = t.u64be(at: 216)
        let xmlLength = t.u64be(at: 224)
        sectorCount = t.u64be(at: 492)
        guard xmlLength > 0, xmlOffset + xmlLength <= source.size else { throw Error.malformed("XML range") }
        let xml = try source.read(at: xmlOffset, count: Int(xmlLength))
        guard let plist = try PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let fork = plist["resource-fork"] as? [String: Any],
              let blkx = fork["blkx"] as? [[String: Any]] else { throw Error.malformed("no blkx table") }
        partitions = try blkx.map { entry in
            guard let mish = entry["Data"] as? Data else { throw Error.malformed("blkx without Data") }
            let name = entry["Name"] as? String ?? entry["CFName"] as? String ?? ""
            return Partition(name: name, chunks: try Self.parseMish(mish))
        }
    }

    static func parseMish(_ d: Data) throws -> [Chunk] {
        let r = ByteReader(d)
        guard d.count >= 204, r.u32be(at: 0) == 0x6D69_7368 else { throw Error.malformed("mish header") } // "mish"
        let firstSector = r.u64be(at: 8)
        let dataStart = r.u64be(at: 24)
        let count = Int(r.u32be(at: 200))
        guard d.count >= 204 + count * 40 else { throw Error.malformed("mish chunk table") }
        return (0..<count).map { i in
            let o = 204 + i * 40
            return Chunk(type: r.u32be(at: o),
                         sector: firstSector + r.u64be(at: o + 8),
                         sectorCount: r.u64be(at: o + 16),
                         compressedOffset: dataStart + r.u64be(at: o + 24),
                         compressedLength: r.u64be(at: o + 32))
        }
    }

    /// Expands the image into `destination` (created or overwritten; zero chunks are left sparse).
    /// The result is the raw disk the DMG describes, partition map included.
    public func expand(to destination: URL, progress: ((Double) -> Void)? = nil) throws {
        let fm = FileManager.default
        fm.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        try out.truncate(atOffset: size)

        let chunks = partitions.flatMap(\.chunks).filter { $0.sectorCount > 0 }
        let total = max(1, chunks.reduce(0) { $0 + $1.sectorCount })
        var done: UInt64 = 0
        for chunk in chunks {
            let length = Int(chunk.sectorCount * Self.sectorSize)
            let base = dataForkOffset + chunk.compressedOffset
            var payload: Data?
            switch chunk.type {
            case 0x0000_0000, 0x0000_0002, 0x7FFF_FFFE, 0xFFFF_FFFF:
                payload = nil                                        // zero-fill, ignore, comment, end
            case 0x0000_0001:
                payload = try source.read(at: base, count: Int(chunk.compressedLength))
            case 0x8000_0005:                                        // zlib: 2-byte header + raw deflate
                let z = try source.read(at: base, count: Int(chunk.compressedLength))
                payload = try Self.decode(z.dropFirst(2), algorithm: COMPRESSION_ZLIB, size: length)
            case 0x8000_0007:                                        // LZFSE
                let c = try source.read(at: base, count: Int(chunk.compressedLength))
                payload = try Self.decode(c, algorithm: COMPRESSION_LZFSE, size: length)
            case 0x8000_0008:                                        // LZMA
                let c = try source.read(at: base, count: Int(chunk.compressedLength))
                payload = try Self.decode(c, algorithm: COMPRESSION_LZMA, size: length)
            default:
                throw Error.unsupportedChunk(chunk.type)
            }
            if let payload, payload.contains(where: { $0 != 0 }) {
                try out.seek(toOffset: chunk.sector * Self.sectorSize)
                out.write(payload)
            }
            done += chunk.sectorCount
            progress?(Double(done) / Double(total))
        }
    }

    static func decode(_ input: Data, algorithm: compression_algorithm, size: Int) throws -> Data {
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { dst.deallocate() }
        let n = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            compression_decode_buffer(dst, size, src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, algorithm)
        }
        guard n == size else { throw Error.malformed("chunk decoded to \(n) of \(size) bytes") }
        return Data(bytes: dst, count: n)
    }
}

/// Random access to bytes, either a plain file or a stored (uncompressed) member inside a ZIP.
public protocol RandomAccessSource {
    var size: UInt64 { get }
    func read(at offset: UInt64, count: Int) throws -> Data
}

public final class FileSource: RandomAccessSource {
    private let handle: FileHandle
    private let base: UInt64
    public let size: UInt64

    public init(url: URL, offset: UInt64 = 0, size: UInt64? = nil) throws {
        handle = try FileHandle(forReadingFrom: url)
        base = offset
        self.size = try size ?? (handle.seekToEnd() - offset)
    }

    deinit { try? handle.close() }

    public func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset + UInt64(count) <= size else { throw UDIFImage.Error.malformed("read past end") }
        try handle.seek(toOffset: base + offset)
        guard let d = try handle.read(upToCount: count), d.count == count else {
            throw UDIFImage.Error.malformed("short read")
        }
        return d
    }
}

extension ByteReader {
    func u64be(at i: Int) -> UInt64 { UInt64(u32be(at: i)) << 32 | UInt64(u32be(at: i + 4)) }
}
