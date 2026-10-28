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
            // release_iosurface asks the renderer to drop what it cached for the surface before
            // releasing it on its queue; without Metal renderer() is null (backboardd crashed there
            // after the first swipe in Setup), so skip that call and only release the surface.
            Patch(address: 0x1_8367_8264, original: 0x97FF_FF1E, replacement: 0xD503_201F,
                  reason: "QuartzCore release_iosurface: no renderer without Metal, skip bl renderer (nop)"),
            Patch(address: 0x1_8367_8268, original: 0xF940_0000, replacement: 0xD503_201F,
                  reason: "QuartzCore release_iosurface: no renderer without Metal, skip ldr x0, [x0] (nop)"),
            Patch(address: 0x1_8367_826C, original: 0xF940_0008, replacement: 0xD503_201F,
                  reason: "QuartzCore release_iosurface: no renderer without Metal, skip ldr x8, [x0] (nop)"),
            Patch(address: 0x1_8367_8270, original: 0xF820_5D09, replacement: 0xD503_201F,
                  reason: "QuartzCore release_iosurface: no renderer without Metal, skip ldraa x9, [x8, #0x28]! (nop)"),
            Patch(address: 0x1_8367_8274, original: 0xF2FA_35E8, replacement: 0xD503_201F,
                  reason: "QuartzCore release_iosurface: no renderer without Metal, skip movk x8 (nop)"),
            Patch(address: 0x1_8367_8278, original: 0xAA13_03E1, replacement: 0xD503_201F,
                  reason: "QuartzCore release_iosurface: no renderer without Metal, skip mov x1, x19 (nop)"),
            Patch(address: 0x1_8367_827C, original: 0xD73F_0928, replacement: 0xD503_201F,
                  reason: "QuartzCore release_iosurface: no renderer without Metal, skip blraa x9, x8 (nop)"),
            Patch(address: 0x1_8367_74E0, original: 0x5288_E828, replacement: 0xD65F_03C0,
                  reason: "QuartzCore get_compressed_agx_universal_rgb_fourcc: keep surfaces uncompressed (ret)"),
            // The emulated phone has no passcode, but the simulated SEP's keystore reports a lock
            // state other than "disabled" (3), so SpringBoard thinks one is set and asks for it after
            // the swipe up. Report "disabled" from the lock state calls SpringBoard and the system
            // services read.
            Patch(address: 0x1_948D_E7A0, original: 0xB940_07E8, replacement: 0x5280_0068,
                  reason: "MobileKeyBag MKBGetDeviceLockState: no passcode, lock state disabled (mov w8, #3)"),
            Patch(address: 0x1_948D_E80C, original: 0xB940_07E2, replacement: 0x5280_0062,
                  reason: "MobileKeyBag MKBGetDeviceLockStateInfo: no passcode, lock state disabled (mov w2, #3)"),
            Patch(address: 0x1_990E_07D8, original: 0x1A9F_07E8, replacement: 0x5280_0008,
                  reason: "SpringBoardFoundation -[SBFMobileKeyBag _queue_setHasPasscodeIfNecessary:]: no passcode (mov w8, #0)"),
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

    /// Patches to other files on the system volume, by IPSW build: the path (the first of the
    /// candidates that exists) and patches whose address is a file offset.
    public static let filePatchesByBuild: [String: [(paths: [String], patches: [Patch])]] = [
        "18A373": [
            // VirtualAudio's deferred initialisation applies a first audio route and, when there
            // is none yet, throws ("nort") and stays "not initialized", so iOS plays no sound at
            // all: the codec only publishes its devices once fud has loaded its DSP firmware,
            // which takes half a minute under emulation. Build the route request as before (the
            // function's end releases it) but skip applying it and logging the result; routes
            // follow when the devices appear.
            (["System/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio",
              "Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio"],
             [Patch(address: 0x7254, original: 0xA90A_7FE8, replacement: 0x9400_D418,
                    reason: "VirtualAudio deferred initialisation: let the devices in before the first route (bl device manager)"),
              Patch(address: 0x7258, original: 0x9102_83E1, replacement: 0x9406_1499,
                    reason: "VirtualAudio deferred initialisation: let the devices in before the first route (bl allow devices)"),
              Patch(address: 0x725C, original: 0x5280_00C0, replacement: 0x52A0_0F40,
                    reason: "VirtualAudio deferred initialisation: give them time to arrive (mov w0, #8 s)"),
              Patch(address: 0x7260, original: 0x9411_D370, replacement: 0x9412_4500,
                    reason: "VirtualAudio deferred initialisation: give them time to arrive (bl usleep)"),
              Patch(address: 0x7264, original: 0x3400_0300, replacement: 0x1400_0018,
                    reason: "VirtualAudio deferred initialisation: then build its first route (b 0x72c4)"),
              Patch(address: 0x19_C334, original: 0x5400_1301, replacement: 0xD503_201F,
                    reason: "VirtualAudio port: routable even when the hardware reports it not connected (nop)"),
              Patch(address: 0x1_58B4, original: 0x3946_A000, replacement: 0x5280_0020,
                    reason: "VirtualAudio port: reports itself connected (mov w0, #1)"),
              Patch(address: 0x1_FA88, original: 0x3946_A000, replacement: 0x5280_0020,
                    reason: "VirtualAudio port: reports itself connected (mov w0, #1)"),
              Patch(address: 0x2_0188, original: 0x3946_A000, replacement: 0x5280_0020,
                    reason: "VirtualAudio port: reports itself connected (mov w0, #1)"),
              Patch(address: 0x2_0190, original: 0x3946_A000, replacement: 0x5280_0020,
                    reason: "VirtualAudio port: reports itself connected (mov w0, #1)"),
              Patch(address: 0x2_0198, original: 0x3946_A000, replacement: 0x5280_0020,
                    reason: "VirtualAudio port: reports itself connected (mov w0, #1)"),
              Patch(address: 0x19_CE44, original: 0x3946_A000, replacement: 0x5280_0020,
                    reason: "VirtualAudio port: reports itself connected (mov w0, #1)"),
              Patch(address: 0x1A_0BF8, original: 0x3946_A000, replacement: 0x5280_0020,
                    reason: "VirtualAudio port: reports itself connected (mov w0, #1)"),
              Patch(address: 0x47_C020, original: 0xD503_237F, replacement: 0x5280_0020,
                    reason: "TEST VirtualAudio log scopes: every level enabled (mov w0, #1)"),
              Patch(address: 0x47_C024, original: 0xA9BD_57F6, replacement: 0xD65F_03C0,
                    reason: "TEST VirtualAudio log scopes: every level enabled (ret)")]),
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
        func hex<T: BinaryInteger>(_ v: T) -> String { "0x" + String(v, radix: 16) }
        var report: [String] = []
        for file in filePatchesByBuild[build] ?? [] {
            guard let found = file.paths.lazy
                .compactMap({ p in (try? container.fileExtents(volume: system.oid, path: p)).map { (p, $0) } }).first else {
                report.append("\(file.paths[0]): not found"); continue
            }
            let (path, fileExtents) = found
            if fileExtents.isEmpty, let compressed = try container.compressedFile(volume: system.oid, path: path) {
                report += try CompressedFilePatch.apply(file.patches, to: compressed, path: path, container: container)
                continue
            }
            for patch in file.patches {
                guard let e = fileExtents.first(where: { patch.address >= $0.logical && patch.address < $0.logical + $0.length }) else {
                    report.append("\(path)+\(hex(patch.address)): not in the file"); continue
                }
                let at = e.offset + patch.address - e.logical
                let word = try container.readBytes(at: at, count: 4).le32(at: 0)
                if word == patch.replacement {
                    report.append("\(path)+\(hex(patch.address)): already patched")
                } else if word != patch.original {
                    report.append("\(path)+\(hex(patch.address)): expected \(hex(patch.original)), found \(hex(word)); left alone")
                } else {
                    var bytes = Data(count: 4)
                    bytes.withUnsafeMutableBytes { $0.storeBytes(of: patch.replacement.littleEndian, as: UInt32.self) }
                    try container.writeBytes(bytes, at: at)
                    report.append("\(path)+\(hex(patch.address)): patched, \(patch.reason)")
                }
            }
        }
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
