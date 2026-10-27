import Foundation
import IPSWKit

/// Instruction patches to the kernelcache, applied to a decoded copy that QEMU boots (Inferno loads
/// a raw Mach-O as readily as an IM4P).
///
/// The patches are found by what the code does rather than by build: each starts from a string
/// that the kernel logs next to the instruction to change, finds the code that loads it, and
/// matches the instructions around it. A kernel where any of them is not found is left alone.
public enum KernelPatches {
    public typealias Patch = SharedCachePatches.Patch

    /// Writes `kernel` (an IM4P kernelcache) patched to `output` as a raw Mach-O and returns a
    /// line per patch. `fudPayloadOffset` is where the payload starts in the touch firmware file
    /// fud loads (see InfernoBackend's Preboot FUD folder). When a patch is not found it writes
    /// nothing and says which.
    public static func apply(kernel: URL, output: URL, fudPayloadOffset: Int) throws -> [String] {
        var macho = try IM4P(Data(contentsOf: kernel)).decodedPayload()
        guard macho.count > 32, macho.le32(at: 0) == 0xFEED_FACF else { return ["not a 64-bit Mach-O; kernel left alone"] }
        let image = MachOImage(macho)
        let patches: [Patch]
        do { patches = try find(in: image, fudPayloadOffset: fudPayloadOffset) }
        catch { return ["\(error); kernel left alone"] }
        for patch in patches {
            guard let offset = image.fileOffset(of: patch.address) else { continue }
            withUnsafeBytes(of: patch.replacement.littleEndian) { macho.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        try macho.write(to: output)
        return patches.map { "\(hex($0.address)): patched, \($0.reason)" }
    }

    struct NotFound: Error, CustomStringConvertible {
        let description: String
    }

    static func find(in image: MachOImage, fudPayloadOffset: Int) throws -> [Patch] {
        guard (1...0xFFF).contains(fudPayloadOffset) else { throw NotFound(description: "payload offset \(fudPayloadOffset) out of range") }
        var patches: [Patch] = []

        // AppleFirmwareUpdateKext::validateFirmware honours skipFWValidation only for one kind
        // of request (`cmp wN, #1; b.ne`), not for the firmware fud loads at boot (the touch
        // controller's), which is the IPSW's, without a personalised manifest, so validation
        // would always fail. Without the branch the boot-arg covers every request.
        let skip = image.codeAfter(string: "skipFWValidation", within: 16).first { at in
            image.word(at) & 0xFFFF_FC1F == 0x7100_041F && image.word(at + 4) & 0xFF00_001F == 0x5400_0001
        }
        guard let skip else { throw NotFound(description: "skipFWValidation check not found") }
        patches.append(Patch(address: skip + 4, original: image.word(skip + 4), replacement: 0xD503_201F,
                             reason: "AppleFirmwareUpdateKext::validateFirmware: skipFWValidation for every request (nop)"))

        // Unvalidated, AIDImageDownloader gets the whole file fud read, an IMG4, and unserializes
        // it as the IOKit XML that is only its payload: OSUnserializeXML(bytes, length) is called
        // with `mov w1, w0` (length) and then `mov x0, xN` (bytes) before the `bl`. Skip the
        // IMG4 and IM4P headers.
        var unserialize: (length: UInt64, bytes: UInt64, register: UInt32)?
        for at in image.codeAfter(string: "Unserializing payload with %u bytes", within: 48)
        where image.word(at) == 0x2A00_03E1 {
            for next in 1...3 {
                let candidate = at + UInt64(4 * next), word = image.word(candidate)
                if word & 0xFFE0_FFFF == 0xAA00_03E0, image.word(candidate + 4) & 0xFC00_0000 == 0x9400_0000 {
                    unserialize = (at, candidate, (word >> 16) & 31)
                    break
                }
            }
            break
        }
        guard let unserialize else { throw NotFound(description: "AIDImageDownloader's OSUnserializeXML call not found") }
        let imm = UInt32(fudPayloadOffset) << 10
        patches.append(Patch(address: unserialize.length, original: image.word(unserialize.length),
                             replacement: 0x5100_0001 | imm,
                             reason: "AIDImageDownloader: unserialize past the IMG4 headers (sub w1, w0, #\(hex(fudPayloadOffset)))"))
        patches.append(Patch(address: unserialize.bytes, original: image.word(unserialize.bytes),
                             replacement: 0x9100_0000 | imm | unserialize.register << 5,
                             reason: "AIDImageDownloader: unserialize past the IMG4 headers (add x0, x\(unserialize.register), #\(hex(fudPayloadOffset)))"))
        return patches
    }

    static func hex<T: BinaryInteger>(_ v: T) -> String { "0x" + String(v, radix: 16) }
}

/// Just enough of a Mach-O to find code by the strings it uses: segments for address lookups and
/// the instruction words of the executable ones.
struct MachOImage {
    struct Segment {
        let vm: UInt64
        let fileOffset: Int
        let fileSize: Int
        let executable: Bool
    }

    let data: Data
    let segments: [Segment]

    init(_ data: Data) {
        self.data = data
        var segments: [Segment] = []
        var at = 32
        for _ in 0..<Int(data.le32(at: 16)) {
            guard at + 8 <= data.count else { break }
            let cmd = data.le32(at: at), size = Int(data.le32(at: at + 4))
            if cmd == 0x19, at + 64 <= data.count {
                let initProt = data.le32(at: at + 60)
                segments.append(Segment(vm: data.le64(at: at + 24), fileOffset: Int(data.le64(at: at + 40)),
                                        fileSize: Int(data.le64(at: at + 48)), executable: initProt & 4 != 0))
            }
            guard size > 0 else { break }
            at += size
        }
        self.segments = segments
    }

    func fileOffset(of address: UInt64) -> Int? {
        for s in segments where address >= s.vm && address < s.vm + UInt64(s.fileSize) {
            let offset = s.fileOffset + Int(address - s.vm)
            return offset + 4 <= data.count ? offset : nil
        }
        return nil
    }

    func address(ofFileOffset offset: Int) -> UInt64? {
        segments.first { offset >= $0.fileOffset && offset < $0.fileOffset + $0.fileSize }
            .map { $0.vm + UInt64(offset - $0.fileOffset) }
    }

    func word(_ address: UInt64) -> UInt32 {
        fileOffset(of: address).map { data.le32(at: $0) } ?? 0
    }

    /// The addresses of the `count` instructions that follow each ADRP+ADD pair loading the
    /// NUL-terminated `string`.
    func codeAfter(string: String, within count: Int) -> [UInt64] {
        let needle = Data(string.utf8) + Data([0])
        var targets: Set<UInt64> = []
        var from = data.startIndex
        while let range = data.range(of: needle, in: from..<data.endIndex) {
            if range.lowerBound == data.startIndex || data[range.lowerBound - 1] == 0,
               let address = address(ofFileOffset: range.lowerBound - data.startIndex) {
                targets.insert(address)
            }
            from = range.lowerBound + 1
        }
        guard !targets.isEmpty else { return [] }
        let pages = Set(targets.map { $0 & ~0xFFF })
        var out: [UInt64] = []
        data.withUnsafeBytes { raw in
            for s in segments where s.executable && s.fileSize >= 8 {
                let end = min(s.fileOffset + s.fileSize, raw.count) - 8
                var offset = s.fileOffset
                while offset < end {
                    let w = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
                    if w & 0x9F00_0000 == 0x9000_0000 {
                        let pc = s.vm + UInt64(offset - s.fileOffset)
                        var imm = Int64((((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3)) << 12
                        if imm & (1 << 32) != 0 { imm -= 1 << 33 }
                        let page = UInt64(bitPattern: Int64(bitPattern: pc & ~0xFFF) &+ imm)
                        if pages.contains(page) {
                            let rd = w & 31
                            for j in 1...3 where offset + 4 * j + 4 <= raw.count {
                                let add = raw.loadUnaligned(fromByteOffset: offset + 4 * j, as: UInt32.self).littleEndian
                                if add & 0xFFC0_0000 == 0x9100_0000, (add >> 5) & 31 == rd,
                                   targets.contains(page + UInt64((add >> 10) & 0xFFF)) {
                                    let base = pc + UInt64(4 * j)
                                    out += (1...count).map { base + UInt64(4 * $0) }
                                    break
                                }
                            }
                        }
                    }
                    offset += 4
                }
            }
        }
        return out
    }
}

private extension Data {
    func le32(at i: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + i + $1]) << (8 * $1) }
    }
    func le64(at i: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[startIndex + i + $1]) << (8 * $1) }
    }
}
