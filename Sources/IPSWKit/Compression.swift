import Foundation
import Compression

public enum DecompressionError: Error, CustomStringConvertible {
    case streamInit
    case corrupt(String)

    public var description: String {
        switch self {
        case .streamInit: return "Failed to initialise decompression stream"
        case .corrupt(let what): return "Corrupt compressed data (\(what))"
        }
    }
}

/// Incremental raw-DEFLATE decoder (Apple's COMPRESSION_ZLIB is headerless deflate, as used by ZIP).
final class RawInflater {
    private var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
    private let bufferSize = 1 << 20
    private let buffer: UnsafeMutablePointer<UInt8>
    private var finished = false

    init() throws {
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw DecompressionError.streamInit
        }
        buffer = .allocate(capacity: bufferSize)
    }

    deinit {
        compression_stream_destroy(&stream)
        buffer.deallocate()
    }

    func process(_ input: Data, final: Bool, sink: (Data) throws -> Void) throws {
        guard !finished else { return }
        try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(buffer)
            stream.src_size = src.count
            let flags = final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, flags)
                let produced = bufferSize - stream.dst_size
                if produced > 0 { try sink(Data(bytes: buffer, count: produced)) }
                switch status {
                case COMPRESSION_STATUS_END:
                    finished = true
                    return
                case COMPRESSION_STATUS_OK:
                    // Output buffer had room left and all input is consumed: wait for the next chunk.
                    // On the final chunk the decoder can report OK rather than END once it has flushed
                    // everything; a call that produces nothing more means it is done. The CRC check in
                    // ZipArchive catches a genuinely truncated stream.
                    if stream.dst_size > 0 && stream.src_size == 0 {
                        if !final { return }
                        if produced == 0 { finished = true; return }
                    }
                default:
                    throw DecompressionError.corrupt("deflate")
                }
            }
        }
    }
}

public enum Decompressor {
    /// Decodes an LZFSE stream ("bvx2"/"bvx1"/"bvxn"/"bvx-" blocks).
    /// `expectedSize` comes from the IM4P compression info; without it the buffer grows until the data fits.
    public static func lzfse(_ data: Data, expectedSize: Int? = nil) throws -> Data {
        var capacity = expectedSize ?? max(data.count * 4, 1 << 20)
        while true {
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dst.deallocate() }
            let n = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(dst, capacity, src.bindMemory(to: UInt8.self).baseAddress!, src.count,
                                          nil, COMPRESSION_LZFSE)
            }
            if n == 0 { throw DecompressionError.corrupt("lzfse") }
            // compression_decode_buffer silently truncates when the buffer is full; retry larger.
            if n < capacity || expectedSize != nil { return Data(bytes: dst, count: n) }
            capacity *= 2
        }
    }

    /// Decodes Apple's "complzss" container used by kernelcaches up to iOS 13 era.
    /// Header: "comp" "lzss" adler32 uncompressedSize compressedSize, padded to 0x180.
    public static func complzss(_ data: Data) throws -> Data {
        let r = ByteReader(data)
        guard data.count >= 0x180, r.u32be(at: 0) == 0x636F_6D70, r.u32be(at: 4) == 0x6C7A_7373 else {
            throw DecompressionError.corrupt("complzss header")
        }
        let usize = Int(r.u32be(at: 12))
        let csize = Int(r.u32be(at: 16))
        guard 0x180 + csize <= data.count else { throw DecompressionError.corrupt("complzss size") }
        let payload = data.subdata(in: (data.startIndex + 0x180)..<(data.startIndex + 0x180 + csize))
        return lzss(payload, expectedSize: usize)
    }

    /// Classic Okumura LZSS (N=4096, F=18, threshold=2), as used by XNU.
    public static func lzss(_ src: Data, expectedSize: Int) -> Data {
        let N = 4096, F = 18, threshold = 2
        var text = [UInt8](repeating: 0x20, count: N + F - 1)
        var out = [UInt8]()
        out.reserveCapacity(expectedSize)
        var r = N - F
        var flags: UInt32 = 0
        var i = src.startIndex
        let end = src.endIndex
        while out.count < expectedSize {
            flags >>= 1
            if flags & 0x100 == 0 {
                guard i < end else { break }
                flags = UInt32(src[i]) | 0xFF00
                i += 1
            }
            if flags & 1 != 0 {
                guard i < end else { break }
                let c = src[i]; i += 1
                out.append(c)
                text[r] = c
                r = (r + 1) & (N - 1)
            } else {
                guard i + 1 < end else { break }
                var pos = Int(src[i])
                var len = Int(src[i + 1])
                i += 2
                pos |= (len & 0xF0) << 4
                len = (len & 0x0F) + threshold
                for k in 0...len {
                    let c = text[(pos + k) & (N - 1)]
                    out.append(c)
                    text[r] = c
                    r = (r + 1) & (N - 1)
                }
            }
        }
        if out.count > expectedSize { out.removeLast(out.count - expectedSize) }
        return Data(out)
    }

    /// Detects the compression scheme from magic bytes and decodes it.
    public static func auto(_ data: Data, expectedSize: Int? = nil) throws -> Data {
        guard data.count >= 8 else { return data }
        let r = ByteReader(data)
        let magic = r.u32be(at: 0)
        switch magic {
        case 0x6276_7832, 0x6276_7831, 0x6276_786E, 0x6276_782D: // bvx2 bvx1 bvxn bvx-
            return try lzfse(data, expectedSize: expectedSize)
        case 0x636F_6D70 where r.u32be(at: 4) == 0x6C7A_7373:     // complzss
            return try complzss(data)
        default:
            return data
        }
    }
}
