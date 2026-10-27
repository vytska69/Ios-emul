import Foundation
import IPSWKit

/// Instruction patches to the installed system's dyld shared cache, so iOS draws without a GPU.
///
/// The emulated machine has no AGX GPU, so Metal has no device and OpenGL ES no renderer. iOS 14's
/// QuartzCore then falls back to its CPU renderer (CA::OGL::SWContext) for the display, but a few
/// paths do not cope: icon scaling and CoreImage use a GL context that has no functions (SpringBoard
/// crashes), the asynchronous dispatcher assumes a Metal renderer (backboardd crashes), and the
/// display surface is AGX-compressed, which the CPU renderer cannot draw into (the screen stays
/// black). Each patch names the instruction it expects; a cache that differs is left alone.
public enum SharedCachePatches {
    public struct Patch {
        public let address: UInt64
        public let original: UInt32
        public let replacement: UInt32
        public let reason: String
    }

    public static let cachePath = "System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e"

    /// Patches by IPSW build.
    public static let byBuild: [String: [Patch]] = [
        // iOS 14.0 (18A373), arm64e cache of the A13 iPhones.
        "18A373": [
            Patch(address: 0x1_A647_E260, original: 0x9400_0041, replacement: 0xD503_201F,
                  reason: "MobileIcons _LICGImageCreateScaled: skip the CoreImage Lanczos scaler (nop)"),
            Patch(address: 0x1_A647_E26C, original: 0x9400_003E, replacement: 0x97C0_E7EF,
                  reason: "MobileIcons _LICGImageCreateScaled: return the image unscaled (bl CGImageRetain)"),
            Patch(address: 0x1_8840_B094, original: 0x9400_D4F9, replacement: 0x5280_0000,
                  reason: "CoreImage -[CIContext initWithOptions:]: OpenGL ES is not usable (mov w0, #0)"),
            Patch(address: 0x1_8367_864C, original: 0x97FF_FE0F, replacement: 0xD503_201F,
                  reason: "QuartzCore AsynchronousDispatcher::timer_callback: no stop_timer without a Metal renderer (nop)"),
            // thread_body reaches stop_timer too (through a run loop source), e.g. for the
            // transition after the first swipe in Setup: backboardd crashed reading the null timer.
            Patch(address: 0x1_8367_7E88, original: 0xD503_237F, replacement: 0xD65F_03C0,
                  reason: "QuartzCore AsynchronousDispatcher::stop_timer: no timer to stop without a Metal renderer (ret)"),
            Patch(address: 0x1_8367_74E0, original: 0x5288_E828, replacement: 0xD65F_03C0,
                  reason: "QuartzCore get_compressed_agx_universal_rgb_fourcc: keep surfaces uncompressed (ret)"),
        ],
    ]

    /// With "Skip setup": the setup assistant's checks answer "no need to run". An emulated phone is
    /// never activated and SetupDone in the preferences does not cover every reason iOS has to show
    /// Setup, so each check returns NO from its first instruction (mov w0, #0; ret, replacing
    /// pacibsp and the stack frame setup).
    public static let skipSetupByBuild: [String: [Patch]] = [
        "18A373": [
            Patch(address: 0x1_945D_77A4, original: 0xD503_237F, replacement: 0x5280_0000,
                  reason: "SetupAssistant _BYSetupAssistantNeedsToRun: NO (mov w0, #0)"),
            Patch(address: 0x1_945D_77A8, original: 0xD102_03FF, replacement: 0xD65F_03C0,
                  reason: "SetupAssistant _BYSetupAssistantNeedsToRun: NO (ret)"),
            Patch(address: 0x1_945D_7B8C, original: 0xD503_237F, replacement: 0x5280_0000,
                  reason: "SetupAssistant _Daemon_BYSetupAssistantNeedsToRun: NO (mov w0, #0)"),
            Patch(address: 0x1_945D_7B90, original: 0xD101_43FF, replacement: 0xD65F_03C0,
                  reason: "SetupAssistant _Daemon_BYSetupAssistantNeedsToRun: NO (ret)"),
            Patch(address: 0x1_945D_7E88, original: 0xD503_237F, replacement: 0x5280_0000,
                  reason: "SetupAssistant _Internal_BYSetupAssistantNeedsToRun: NO (mov w0, #0)"),
            Patch(address: 0x1_945D_7E8C, original: 0xD101_43FF, replacement: 0xD65F_03C0,
                  reason: "SetupAssistant _Internal_BYSetupAssistantNeedsToRun: NO (ret)"),
        ],
    ]

    /// Applies the patches for `build` (and with `skipSetup` the setup assistant ones) to the shared
    /// cache on the container's system volume. Returns a line per patch saying what happened.
    @discardableResult
    public static func apply(build: String, container: APFSContainer, skipSetup: Bool = false) throws -> [String] {
        let patches = (byBuild[build] ?? []) + (skipSetup ? skipSetupByBuild[build] ?? [] : [])
        guard !patches.isEmpty else { return [] }
        let volumes = try container.volumes()
        guard let system = volumes.first(where: { $0.role == 0x1 }) ?? volumes.first else { return [] }
        let extents = try container.fileExtents(volume: system.oid, path: cachePath)

        func containerOffset(_ fileOffset: UInt64) -> UInt64? {
            extents.first { fileOffset >= $0.logical && fileOffset < $0.logical + $0.length }
                .map { $0.offset + fileOffset - $0.logical }
        }
        func read(_ fileOffset: UInt64, _ count: Int) throws -> Data {
            guard let at = containerOffset(fileOffset) else { throw APFSContainer.Error.unsupported("cache offset \(fileOffset)") }
            return try container.readBytes(at: at, count: count)
        }

        // dyld_cache_header: mappingOffset/mappingCount, then dyld_cache_mapping_info records.
        let header = try read(0, 0x200)
        guard header.prefix(7) == Data("dyld_v1".utf8) else { throw APFSContainer.Error.unsupported("not a dyld shared cache") }
        let mappingOffset = UInt64(header.le32(at: 0x10)), mappingCount = Int(header.le32(at: 0x14))
        let table = try read(mappingOffset, mappingCount * 32)
        let mappings = (0..<mappingCount).map { i in
            (address: table.le64(at: i * 32), size: table.le64(at: i * 32 + 8), fileOffset: table.le64(at: i * 32 + 16))
        }

        func hex<T: BinaryInteger>(_ v: T) -> String { "0x" + String(v, radix: 16) }
        var report: [String] = []
        for patch in patches {
            guard let m = mappings.first(where: { patch.address >= $0.address && patch.address < $0.address + $0.size }),
                  let at = containerOffset(m.fileOffset + patch.address - m.address) else {
                report.append("\(hex(patch.address)): not in the cache"); continue
            }
            let word = try container.readBytes(at: at, count: 4).le32(at: 0)
            if word == patch.replacement {
                report.append("\(hex(patch.address)): already patched")
            } else if word != patch.original {
                report.append("\(hex(patch.address)): expected \(hex(patch.original)), found \(hex(word)); left alone")
            } else {
                var bytes = Data(count: 4)
                bytes.withUnsafeMutableBytes { $0.storeBytes(of: patch.replacement.littleEndian, as: UInt32.self) }
                try container.writeBytes(bytes, at: at)
                report.append("\(hex(patch.address)): patched, \(patch.reason)")
            }
        }
        return report
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
