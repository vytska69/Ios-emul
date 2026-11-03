import Compression
import Foundation
import IPSWKit

/// Instruction patches to a file that APFS stores compressed (decmpfs with a resource fork, as most
/// of the system volume's binaries are): the file has no data of its own, its bytes are 64 KiB
/// chunks in `com.apple.ResourceFork`, each compressed on its own.
///
/// A patch changes the chunk holding its address in place, the chunk's size and the fork's layout
/// staying as they are: first by changing the 4 bytes where they appear as literals in the
/// compressed stream, then (LZFSE, zlib) by compressing the patched chunk again when it fits in the
/// old one's space. Either way the chunk is decompressed again and must give the patched bytes,
/// or nothing is written.
enum CompressedFilePatch {
    static let chunkSize = 0x10000

    static func apply(_ patches: [SharedCachePatches.Patch], to file: APFSContainer.CompressedFile,
                      path: String, container: APFSContainer) throws -> [String] {
        func hex<T: BinaryInteger>(_ v: T) -> String { "0x" + String(v, radix: 16) }
        guard [4, 8, 12].contains(file.type), !file.fork.isEmpty else {
            return ["\(path): compression type \(file.type) not handled"]
        }
        let forkLength = file.fork.map { $0.logical + $0.length }.max() ?? 0
        func containerOffset(_ forkOffset: UInt64) -> UInt64? {
            file.fork.first { forkOffset >= $0.logical && forkOffset < $0.logical + $0.length }
                .map { $0.offset + forkOffset - $0.logical }
        }
        func readFork(_ offset: UInt64, _ count: Int) throws -> Data {
            var out = Data()
            var at = offset
            while out.count < count {
                guard let c = containerOffset(at) else { throw APFSContainer.Error.unsupported("fork offset \(at)") }
                let n = min(count - out.count, 4096 - Int(at % 4096))
                out += try container.readBytes(at: c, count: n)
                at += UInt64(n)
            }
            return out
        }
        func writeFork(_ data: Data, at offset: UInt64) throws {
            var written = 0
            while written < data.count {
                let at = offset + UInt64(written)
                guard let c = containerOffset(at) else { throw APFSContainer.Error.unsupported("fork offset \(at)") }
                let n = min(data.count - written, 4096 - Int(at % 4096))
                try container.writeBytes(data.subdata(in: (data.startIndex + written)..<(data.startIndex + written + n)), at: c)
                written += n
            }
        }

        // Where chunk i is in the fork: LZVN and LZFSE start with the chunks' offsets (one more
        // than there are chunks); zlib has a resource-fork header and (offset, size) pairs.
        let chunks = Int((file.size + UInt64(chunkSize) - 1) / UInt64(chunkSize))
        func chunkRange(_ i: Int) throws -> Range<UInt64> {
            if file.type == 4 {
                let base = UInt64(try readFork(0, 4).withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }) + 4
                let entry = try readFork(base + 4 + UInt64(i) * 8, 8)
                let start = base + UInt64(entry.le32(at: 0)), size = UInt64(entry.le32(at: 4))
                return start..<start + size
            }
            let table = try readFork(UInt64(i) * 4, 8)
            return UInt64(table.le32(at: 0))..<UInt64(table.le32(at: 4))
        }

        var report: [String] = []
        for patch in patches {
            let chunk = Int(patch.address) / chunkSize, within = Int(patch.address) % chunkSize
            guard chunk < chunks else { report.append("\(path)+\(hex(patch.address)): past the end"); continue }
            let range = try chunkRange(chunk)
            guard range.upperBound <= forkLength, range.count > 0 else {
                report.append("\(path)+\(hex(patch.address)): chunk \(chunk) outside the fork"); continue
            }
            let compressed = try readFork(range.lowerBound, range.count)
            let rawSize = min(chunkSize, Int(file.size) - chunk * chunkSize)
            guard let plain = decode(compressed, type: file.type, rawSize: rawSize), plain.count == rawSize else {
                report.append("\(path)+\(hex(patch.address)): chunk \(chunk) does not decompress"); continue
            }
            let word = plain.le32(at: within)
            if word == patch.replacement { report.append("\(path)+\(hex(patch.address)): already patched"); continue }
            guard word == patch.original else {
                report.append("\(path)+\(hex(patch.address)): expected \(hex(patch.original)), found \(hex(word)); left alone"); continue
            }
            var expected = plain
            withUnsafeBytes(of: patch.replacement.littleEndian) { expected.replaceSubrange(within..<within + 4, with: $0) }

            // The original bytes as a literal in the stream.
            let needle = withUnsafeBytes(of: patch.original.littleEndian) { Data($0) }
            let replacement = withUnsafeBytes(of: patch.replacement.littleEndian) { Data($0) }
            var done: String?
            var from = compressed.startIndex
            while done == nil, let hit = compressed.range(of: needle, in: from..<compressed.endIndex) {
                var candidate = compressed
                candidate.replaceSubrange(hit, with: replacement)
                if decode(candidate, type: file.type, rawSize: rawSize) == expected {
                    try writeFork(replacement, at: range.lowerBound + UInt64(hit.lowerBound - compressed.startIndex))
                    done = "patched in place"
                }
                from = hit.lowerBound + 1
            }
            // Or the whole chunk compressed again, if it fits.
            if done == nil, let encoded = encode(expected, type: file.type), encoded.count <= compressed.count,
               decode(encoded + Data(count: compressed.count - encoded.count), type: file.type, rawSize: rawSize) == expected {
                try writeFork(encoded + Data(count: compressed.count - encoded.count), at: range.lowerBound)
                done = "chunk recompressed (\(encoded.count) of \(compressed.count) bytes)"
            }
            report.append("\(path)+\(hex(patch.address)): " + (done.map { "\($0), \(patch.reason)" }
                ?? "compressed (type \(file.type)) and could not be patched; left alone"))
        }
        return report
    }

    /// The whole file, decompressed. Handles the inline types (1, 3, 7, 11) and the
    /// resource-fork ones (4, 8, 12), as iOS's system volumes store them.
    static func contents(of file: APFSContainer.CompressedFile, container: APFSContainer) throws -> Data {
        let size = Int(file.size)
        func fail(_ why: String) -> Error { APFSContainer.Error.unsupported("decmpfs type \(file.type): \(why)") }
        switch file.type {
        case 1:
            guard file.inline.count >= size else { throw fail("short") }
            return file.inline.prefix(size)
        case 3, 7, 11:
            guard size > 0 else { return Data() }
            guard let first = file.inline.first else { throw fail("no data") }
            // Stored rather than compressed: 0x?F (zlib), 0x06 (LZVN), 0xFF (LZFSE), then the bytes.
            if (file.type == 3 && first & 0x0F == 0x0F) || (file.type == 7 && first == 0x06) || (file.type == 11 && first == 0xFF) {
                return file.inline.dropFirst().prefix(size)
            }
            let data: Data? = file.type == 3
                ? (file.inline.count > 2 ? run(file.inline.dropFirst(2), algorithm: COMPRESSION_ZLIB, outputSize: size) : nil)
                : decode(file.inline, type: file.type == 7 ? 8 : 12, rawSize: size)
            guard let data, data.count == size else { throw fail("does not decompress") }
            return data
        case 4, 8, 9, 12:
            guard size > 0 else { return Data() }
            var fork = Data()
            for extent in file.fork {
                guard extent.logical == UInt64(fork.count) else { throw fail("fork has a hole") }
                fork += try container.readBytes(at: extent.offset, count: Int(extent.length))
            }
            // Type 9 keeps the bytes uncompressed in the fork: as they are, or in chunks after an
            // offset table like LZVN's.
            if file.type == 9 {
                let chunks = (size + chunkSize - 1) / chunkSize
                let tableSize = (chunks + 1) * 4
                if fork.count >= tableSize, Int(fork.le32(at: 0)) == tableSize {
                    var out = Data(capacity: size)
                    for i in 0..<chunks {
                        let start = Int(fork.le32(at: i * 4)), end = Int(fork.le32(at: i * 4 + 4))
                        guard start <= end, end <= fork.count else { throw fail("chunk \(i)") }
                        var chunk = fork.subdata(in: start..<end)
                        // A stored chunk may carry a one-byte marker.
                        let rawSize = min(chunkSize, size - i * chunkSize)
                        if chunk.count == rawSize + 1 { chunk = chunk.dropFirst() }
                        guard chunk.count == rawSize else { throw fail("chunk \(i) size") }
                        out += chunk
                    }
                    return out
                }
                guard fork.count >= size else { throw fail("short fork") }
                return fork.prefix(size)
            }
            let chunks = (size + chunkSize - 1) / chunkSize
            var out = Data(capacity: size)
            for i in 0..<chunks {
                let range: Range<Int>
                if file.type == 4 {
                    guard fork.count >= 4 else { throw fail("short fork") }
                    let base = Int(fork.prefix(4).withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }) + 4
                    let at = base + 4 + i * 8
                    guard at + 8 <= fork.count else { throw fail("chunk table") }
                    let start = base + Int(fork.le32(at: at))
                    range = start..<start + Int(fork.le32(at: at + 4))
                } else {
                    guard (i + 1) * 4 + 4 <= fork.count else { throw fail("chunk table") }
                    range = Int(fork.le32(at: i * 4))..<Int(fork.le32(at: i * 4 + 4))
                }
                guard range.lowerBound >= 0, range.upperBound <= fork.count, !range.isEmpty else { throw fail("chunk \(i)") }
                let rawSize = min(chunkSize, size - i * chunkSize)
                guard let plain = decode(fork.subdata(in: range), type: file.type, rawSize: rawSize), plain.count == rawSize else {
                    throw fail("chunk \(i) does not decompress")
                }
                out += plain
            }
            return out
        default:
            throw fail("not handled")
        }
    }

    /// One chunk decompressed, or nil.
    static func decode(_ data: Data, type: UInt32, rawSize: Int) -> Data? {
        guard let first = data.first else { return nil }
        switch type {
        case 8:                                                    // LZVN; 0x06 marks a stored chunk
            if first == 0x06 { return data.dropFirst().prefix(rawSize) }
            // Apple's decoder reads LZVN inside an LZFSE frame ("bvxn" block, then "bvx$").
            var framed = Data("bvxn".utf8)
            framed.appendLE32(UInt32(rawSize)); framed.appendLE32(UInt32(data.count))
            framed += data + Data("bvx$".utf8)
            return run(framed, algorithm: COMPRESSION_LZFSE, outputSize: rawSize)
        case 12:                                                   // LZFSE; 0xFF marks a stored chunk
            if first == 0xFF { return data.dropFirst().prefix(rawSize) }
            return run(data, algorithm: COMPRESSION_LZFSE, outputSize: rawSize)
        case 4:                                                    // zlib (2-byte header); 0xFF stored
            if first == 0xFF { return data.dropFirst().prefix(rawSize) }
            guard data.count > 2 else { return nil }
            return run(data.dropFirst(2), algorithm: COMPRESSION_ZLIB, outputSize: rawSize)
        default:
            return nil
        }
    }

    /// One chunk compressed the way the file's type stores it, or nil (LZVN cannot be produced).
    static func encode(_ data: Data, type: UInt32) -> Data? {
        switch type {
        case 12:
            return run(data, algorithm: COMPRESSION_LZFSE, outputSize: data.count + 4096, encode: true)
        case 4:
            // zlib stream: header, raw deflate, Adler-32 of the data (big-endian).
            guard let deflated = run(data, algorithm: COMPRESSION_ZLIB, outputSize: data.count + 4096, encode: true) else { return nil }
            var a: UInt32 = 1, b: UInt32 = 0
            for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
            return Data([0x78, 0x5E]) + deflated + withUnsafeBytes(of: (b << 16 | a).bigEndian) { Data($0) }
        default:
            return nil
        }
    }

    static func run(_ input: Data, algorithm: compression_algorithm, outputSize: Int, encode: Bool = false) -> Data? {
        var output = Data(count: outputSize)
        let n = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                encode
                    ? compression_encode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, outputSize,
                                                inp.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, algorithm)
                    : compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, outputSize,
                                                inp.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, algorithm)
            }
        }
        return n > 0 ? output.prefix(n) : nil
    }
}

private extension Data {
    func le32(at i: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + i + $1]) << (8 * $1) }
    }
    mutating func appendLE32(_ v: UInt32) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}
