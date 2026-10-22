import Foundation

/// Writes a GUID partition table with a single APFS partition, laid out for a disk with
/// `blockSize`-byte logical blocks.
///
/// iPhone NVMe namespaces use 4096-byte blocks, while the GPT inside an IPSW's root filesystem
/// DMG is written for 512-byte sectors, so it is unreadable on the emulated disk (the kernel finds
/// no disk0s1). Rewriting the table for the real block size is what a restore effectively does.
public enum GPT {
    /// APFS container partition type, 7C3457EF-0000-11AA-AA11-00306543ECAC.
    public static let apfsType = guid("7C3457EF-0000-11AA-AA11-00306543ECAC")

    public struct Layout {
        public let blockSize: UInt64
        public let diskBlocks: UInt64
        public let firstUsable: UInt64
        public let lastUsable: UInt64
        public var partitionOffset: UInt64 { firstUsable * blockSize }
        public var partitionSize: UInt64 { (lastUsable - firstUsable + 1) * blockSize }
    }

    static let entryCount: UInt64 = 128
    static let entrySize: UInt64 = 128

    public static func layout(diskSize: UInt64, blockSize: UInt64) -> Layout {
        let blocks = diskSize / blockSize
        let entryBlocks = (entryCount * entrySize + blockSize - 1) / blockSize
        // Align the partition to 1 MiB like Apple's tools, past the MBR, header and entry array.
        let align = max(1, (1 << 20) / blockSize)
        let first = ((2 + entryBlocks + align - 1) / align) * align
        let last = blocks - 2 - entryBlocks
        return Layout(blockSize: blockSize, diskBlocks: blocks, firstUsable: first, lastUsable: last)
    }

    /// Writes protective MBR, primary and backup headers and entry arrays.
    public static func write(to handle: FileHandle, layout l: Layout, partitionName: String = "Container",
                             diskGUID: [UInt8] = randomGUID(), partitionGUID: [UInt8] = randomGUID()) throws {
        let bs = l.blockSize
        let entryBlocks = (entryCount * entrySize + bs - 1) / bs

        var entries = Data(count: Int(entryCount * entrySize))
        var e = Data()
        e.append(contentsOf: apfsType)
        e.append(contentsOf: partitionGUID)
        e.appendLE64(l.firstUsable)
        e.appendLE64(l.lastUsable)
        e.appendLE64(0)                                                   // attributes
        let name = Array(partitionName.utf16.prefix(36))
        for unit in name { e.appendLE16(unit) }
        e.append(Data(count: 128 - e.count))
        entries.replaceSubrange(0..<128, with: e)
        var entriesCRC = CRC32(); entriesCRC.update(entries)

        func header(current: UInt64, backup: UInt64, entriesLBA: UInt64) -> Data {
            var h = Data()
            h.append(contentsOf: Array("EFI PART".utf8))
            h.appendLE32(0x0001_0000); h.appendLE32(92); h.appendLE32(0); h.appendLE32(0)   // revision, size, crc (later), reserved
            h.appendLE64(current); h.appendLE64(backup)
            h.appendLE64(l.firstUsable); h.appendLE64(l.lastUsable)
            h.append(contentsOf: diskGUID)
            h.appendLE64(entriesLBA)
            h.appendLE32(UInt32(entryCount)); h.appendLE32(UInt32(entrySize)); h.appendLE32(entriesCRC.value)
            var crc = CRC32(); crc.update(h)
            h.replaceSubrange(16..<20, with: withUnsafeBytes(of: crc.value.littleEndian, Array.init))
            return h + Data(count: Int(bs) - h.count)
        }

        var mbr = Data(count: Int(bs))
        let part: [UInt8] = [0x00, 0x00, 0x02, 0x00, 0xEE, 0xFF, 0xFF, 0xFF, 0x01, 0, 0, 0]
        mbr.replaceSubrange(446..<(446 + part.count), with: part)
        let size32 = UInt32(clamping: l.diskBlocks - 1)
        mbr.replaceSubrange(458..<462, with: withUnsafeBytes(of: size32.littleEndian, Array.init))
        mbr[510] = 0x55; mbr[511] = 0xAA

        let backupLBA = l.diskBlocks - 1
        let backupEntriesLBA = backupLBA - entryBlocks
        let writes: [(UInt64, Data)] = [
            (0, mbr),
            (1, header(current: 1, backup: backupLBA, entriesLBA: 2)),
            (2, entries),
            (backupEntriesLBA, entries),
            (backupLBA, header(current: backupLBA, backup: 1, entriesLBA: backupEntriesLBA)),
        ]
        for (lba, data) in writes {
            try handle.seek(toOffset: lba * bs)
            handle.write(data)
        }
    }

    /// Parses "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX" into GPT's mixed-endian byte order.
    public static func guid(_ s: String) -> [UInt8] {
        let hex = s.replacingOccurrences(of: "-", with: "")
        var bytes: [UInt8] = stride(from: 0, to: hex.count, by: 2).map {
            let i = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[i..<hex.index(i, offsetBy: 2)], radix: 16)!
        }
        bytes[0..<4].reverse(); bytes[4..<6].reverse(); bytes[6..<8].reverse()
        return bytes
    }

    public static func randomGUID() -> [UInt8] {
        var b = (0..<16).map { _ in UInt8.random(in: 0...255) }
        b[7] = (b[7] & 0x0F) | 0x40   // version 4 (stored little-endian in field 3)
        b[8] = (b[8] & 0x3F) | 0x80
        return b
    }
}

extension Data {
    mutating func appendLE16(_ v: UInt16) { append(contentsOf: withUnsafeBytes(of: v.littleEndian, Array.init)) }
    mutating func appendLE32(_ v: UInt32) { append(contentsOf: withUnsafeBytes(of: v.littleEndian, Array.init)) }
    mutating func appendLE64(_ v: UInt64) { append(contentsOf: withUnsafeBytes(of: v.littleEndian, Array.init)) }
}
