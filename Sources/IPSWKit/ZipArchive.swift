import Foundation

/// Minimal read-only ZIP reader with ZIP64 support.
///
/// IPSW files are plain ZIP archives that frequently exceed 4 GiB, so ZIP64
/// end-of-central-directory records and extra fields must be honoured.
/// Only the "stored" (0) and "deflate" (8) methods are used by Apple.
public final class ZipArchive {
    public struct Entry: Hashable {
        public let path: String
        public let method: UInt16
        public let crc32: UInt32
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let localHeaderOffset: UInt64

        public var isDirectory: Bool { path.hasSuffix("/") }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case notAZip
        case truncated(String)
        case unsupportedMethod(UInt16)
        case entryNotFound(String)
        case crcMismatch(String)

        public var description: String {
            switch self {
            case .notAZip: return "File is not a ZIP/IPSW archive"
            case .truncated(let what): return "Archive is truncated (\(what))"
            case .unsupportedMethod(let m): return "Unsupported ZIP compression method \(m)"
            case .entryNotFound(let p): return "Entry not found in archive: \(p)"
            case .crcMismatch(let p): return "CRC mismatch while extracting \(p)"
            }
        }
    }

    public let url: URL
    public private(set) var entries: [Entry] = []
    private var index: [String: Entry] = [:]
    private let handle: FileHandle
    private let fileSize: UInt64

    public init(url: URL) throws {
        self.url = url
        self.handle = try FileHandle(forReadingFrom: url)
        self.fileSize = try handle.seekToEnd()
        try readCentralDirectory()
    }

    deinit { try? handle.close() }

    public func entry(_ path: String) -> Entry? { index[path] }

    /// Case-insensitive lookup by last path component (IPSW layouts vary between versions).
    public func entry(named name: String) -> Entry? {
        let lower = name.lowercased()
        return entries.first { ($0.path as NSString).lastPathComponent.lowercased() == lower }
    }

    public func data(for path: String) throws -> Data {
        guard let e = index[path] else { throw Error.entryNotFound(path) }
        return try data(for: e)
    }

    public func data(for entry: Entry) throws -> Data {
        var out = Data()
        out.reserveCapacity(Int(clamping: entry.uncompressedSize))
        try stream(entry) { out.append($0) }
        return out
    }

    /// Reads only the first `count` decompressed bytes (enough to sniff magic numbers).
    public func head(of entry: Entry, count: Int) throws -> Data {
        struct Enough: Swift.Error {}
        var out = Data()
        do {
            try stream(entry) { chunk in
                out.append(chunk.prefix(count - out.count))
                if out.count >= count { throw Enough() }
            }
        } catch is Enough {}
        return out
    }

    /// Extracts an entry to disk without holding it in memory (root filesystem DMGs are several GiB).
    public func extract(_ entry: Entry, to destination: URL, progress: ((Double) -> Void)? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        var written: UInt64 = 0
        try stream(entry) { chunk in
            out.write(chunk)
            written += UInt64(chunk.count)
            if entry.uncompressedSize > 0 {
                progress?(Double(written) / Double(entry.uncompressedSize))
            }
        }
    }

    // MARK: - Streaming

    private static let chunkSize = 4 << 20

    private func stream(_ entry: Entry, _ sink: (Data) throws -> Void) throws {
        let dataOffset = try localDataOffset(entry)
        var crc = CRC32()
        switch entry.method {
        case 0:
            var remaining = entry.compressedSize
            try handle.seek(toOffset: dataOffset)
            while remaining > 0 {
                let n = Int(min(UInt64(Self.chunkSize), remaining))
                guard let chunk = try handle.read(upToCount: n), chunk.count == n else {
                    throw Error.truncated(entry.path)
                }
                crc.update(chunk)
                try sink(chunk)
                remaining -= UInt64(n)
            }
        case 8:
            let inflater = try RawInflater()
            var remaining = entry.compressedSize
            try handle.seek(toOffset: dataOffset)
            while remaining > 0 {
                let n = Int(min(UInt64(Self.chunkSize), remaining))
                guard let chunk = try handle.read(upToCount: n), chunk.count == n else {
                    throw Error.truncated(entry.path)
                }
                remaining -= UInt64(n)
                try inflater.process(chunk, final: remaining == 0) { out in
                    crc.update(out)
                    try sink(out)
                }
            }
        default:
            throw Error.unsupportedMethod(entry.method)
        }
        if crc.value != entry.crc32 { throw Error.crcMismatch(entry.path) }
    }

    private func localDataOffset(_ entry: Entry) throws -> UInt64 {
        try handle.seek(toOffset: entry.localHeaderOffset)
        guard let header = try handle.read(upToCount: 30), header.count == 30 else {
            throw Error.truncated("local header")
        }
        let r = ByteReader(header)
        guard r.u32(at: 0) == 0x0403_4B50 else { throw Error.notAZip }
        let nameLen = UInt64(r.u16(at: 26))
        let extraLen = UInt64(r.u16(at: 28))
        return entry.localHeaderOffset + 30 + nameLen + extraLen
    }

    // MARK: - Central directory

    private func readCentralDirectory() throws {
        // EOCD is at most 65535 + 22 bytes from the end.
        let tailLen = min(fileSize, 65_557)
        try handle.seek(toOffset: fileSize - tailLen)
        guard let tail = try handle.read(upToCount: Int(tailLen)) else { throw Error.notAZip }
        let t = ByteReader(tail)
        var eocd: Int?
        var i = tail.count - 22
        while i >= 0 {
            if t.u32(at: i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard let eocdPos = eocd else { throw Error.notAZip }

        var count = UInt64(t.u16(at: eocdPos + 10))
        var cdSize = UInt64(t.u32(at: eocdPos + 12))
        var cdOffset = UInt64(t.u32(at: eocdPos + 16))

        // ZIP64 locator sits immediately before the classic EOCD.
        let locPos = eocdPos - 20
        if locPos >= 0, t.u32(at: locPos) == 0x0706_4B50 {
            let eocd64Offset = t.u64(at: locPos + 8)
            try handle.seek(toOffset: eocd64Offset)
            guard let rec = try handle.read(upToCount: 56), rec.count == 56 else {
                throw Error.truncated("zip64 eocd")
            }
            let r = ByteReader(rec)
            guard r.u32(at: 0) == 0x0606_4B50 else { throw Error.notAZip }
            count = r.u64(at: 32)
            cdSize = r.u64(at: 40)
            cdOffset = r.u64(at: 48)
        }

        try handle.seek(toOffset: cdOffset)
        guard let cd = try handle.read(upToCount: Int(cdSize)), UInt64(cd.count) == cdSize else {
            throw Error.truncated("central directory")
        }
        let r = ByteReader(cd)
        var pos = 0
        var result: [Entry] = []
        result.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard pos + 46 <= cd.count, r.u32(at: pos) == 0x0201_4B50 else {
                throw Error.truncated("central directory entry")
            }
            let method = r.u16(at: pos + 10)
            let crc = r.u32(at: pos + 16)
            var csize = UInt64(r.u32(at: pos + 20))
            var usize = UInt64(r.u32(at: pos + 24))
            let nameLen = Int(r.u16(at: pos + 28))
            let extraLen = Int(r.u16(at: pos + 30))
            let commentLen = Int(r.u16(at: pos + 32))
            var offset = UInt64(r.u32(at: pos + 42))
            let nameData = cd.subdata(in: (cd.startIndex + pos + 46)..<(cd.startIndex + pos + 46 + nameLen))
            let name = String(decoding: nameData, as: UTF8.self)

            // ZIP64 extended information extra field (0x0001).
            var ep = pos + 46 + nameLen
            let extraEnd = ep + extraLen
            while ep + 4 <= extraEnd {
                let tag = r.u16(at: ep)
                let size = Int(r.u16(at: ep + 2))
                if tag == 0x0001 {
                    var fp = ep + 4
                    if usize == 0xFFFF_FFFF { usize = r.u64(at: fp); fp += 8 }
                    if csize == 0xFFFF_FFFF { csize = r.u64(at: fp); fp += 8 }
                    if offset == 0xFFFF_FFFF { offset = r.u64(at: fp) }
                }
                ep += 4 + size
            }

            result.append(Entry(path: name, method: method, crc32: crc,
                                compressedSize: csize, uncompressedSize: usize,
                                localHeaderOffset: offset))
            pos += 46 + nameLen + extraLen + commentLen
        }
        entries = result
        index = Dictionary(result.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

/// Little/big-endian helpers over a `Data` value with a zero-based view.
struct ByteReader {
    let data: Data
    init(_ data: Data) { self.data = data }

    func u8(at i: Int) -> UInt8 { data[data.startIndex + i] }
    func u16(at i: Int) -> UInt16 { UInt16(u8(at: i)) | UInt16(u8(at: i + 1)) << 8 }
    func u32(at i: Int) -> UInt32 { UInt32(u16(at: i)) | UInt32(u16(at: i + 2)) << 16 }
    func u64(at i: Int) -> UInt64 { UInt64(u32(at: i)) | UInt64(u32(at: i + 4)) << 32 }
    func u32be(at i: Int) -> UInt32 {
        UInt32(u8(at: i)) << 24 | UInt32(u8(at: i + 1)) << 16 | UInt32(u8(at: i + 2)) << 8 | UInt32(u8(at: i + 3))
    }
}

struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private(set) var value: UInt32 = 0

    mutating func update(_ data: Data) {
        var c = ~value
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { c = Self.table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        value = ~c
    }
}
