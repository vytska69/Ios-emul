import Foundation
import IPSWKit

/// Instruction patches to the kernelcache, applied to a decoded copy that QEMU boots (Inferno loads
/// a raw Mach-O as readily as an IM4P).
///
/// iOS 14's touch driver, AppleHIDTransportDeviceSPI, expects iBoot to have loaded the touch
/// controller's firmware ('wftm') and hands its HBPP bootloader an image downloader for it. Without
/// iBoot there is no image, and the bootloader then neither has firmware nor advertises itself as
/// "HID Bootloadable", which is what mtmergeprops waits for to merge the firmware personality
/// (the firmware it builds from, the HIDSPI and interface configuration) from the installed
/// Multitouch.mtprops. Answering "no downloader" takes the personality path instead. Each patch names
/// the instruction it expects; a kernel that differs is left alone.
public enum KernelPatches {
    public typealias Patch = SharedCachePatches.Patch

    /// Patches by IPSW build. The addresses are those of the research kernelcache (kaslr-off).
    public static let byBuild: [String: [Patch]] = [
        // iOS 14.0 (18A373), kernelcache.research.iphone12b.
        "18A373": [
            Patch(address: 0xFFFF_FFF0_084B_3A04, original: 0xD503_237F, replacement: 0xD280_0000,
                  reason: "AppleHIDTransportDeviceSPI::getImageDownloader: none (mov x0, #0)"),
            Patch(address: 0xFFFF_FFF0_084B_3A08, original: 0xD101_C3FF, replacement: 0xD65F_03C0,
                  reason: "AppleHIDTransportDeviceSPI::getImageDownloader: none (ret)"),
        ],
    ]

    /// Writes `kernel` (an IM4P kernelcache) patched for `build` to `output` as a raw Mach-O and
    /// returns a line per patch, or nil when the build has no patches. When one of them does not
    /// match it writes nothing and says why.
    public static func apply(build: String, kernel: URL, output: URL) throws -> [String]? {
        guard let patches = byBuild[build], !patches.isEmpty else { return nil }
        var macho = try IM4P(Data(contentsOf: kernel)).decodedPayload()
        guard macho.count > 32, macho.le32(at: 0) == 0xFEED_FACF else { return nil }

        // LC_SEGMENT_64 (vmaddr, vmsize, fileoff, filesize) for virtual-address lookups.
        var segments: [(vm: UInt64, fileOffset: UInt64, fileSize: UInt64)] = []
        var at = 32
        for _ in 0..<Int(macho.le32(at: 16)) {
            let cmd = macho.le32(at: at), size = Int(macho.le32(at: at + 4))
            if cmd == 0x19 {
                segments.append((macho.le64(at: at + 24), macho.le64(at: at + 40), macho.le64(at: at + 48)))
            }
            at += size
        }

        func hex<T: BinaryInteger>(_ v: T) -> String { "0x" + String(v, radix: 16) }
        // The patches replace whole function prologues, so they apply all together or not at all.
        var offsets: [Int] = []
        for patch in patches {
            guard let s = segments.first(where: { patch.address >= $0.vm && patch.address < $0.vm + $0.fileSize }) else {
                return ["\(hex(patch.address)): not in the kernel; kernel left alone"]
            }
            let offset = Int(s.fileOffset + patch.address - s.vm)
            let word = macho.le32(at: offset)
            guard word == patch.original else {
                return ["\(hex(patch.address)): expected \(hex(patch.original)), found \(hex(word)); kernel left alone"]
            }
            offsets.append(offset)
        }
        for (patch, offset) in zip(patches, offsets) {
            withUnsafeBytes(of: patch.replacement.littleEndian) { macho.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        try macho.write(to: output)
        return patches.map { "\(hex($0.address)): patched, \($0.reason)" }
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
