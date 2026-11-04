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
            // Large copies and fills run natively: the emulator's hypercall (HINT #127, a NOP on
            // hardware; qemu/patches/inferno/0048) with x16 = 1 (memmove) or 2 (memset) does the
            // whole call on the host, where the guest's own loop runs 32 bytes per translated step.
            // Only the paths for big sizes are replaced (x0 destination, x1 source or byte, x2
            // length, as the function received them); short ones stay as they are.
            Patch(address: 0x1_C799_6610, original: 0x9100_8063, replacement: 0xD280_0030,
                  reason: "libsystem_platform _platform_memmove, 4 KB and more: mov x16, #1 (hypercall memmove)"),
            Patch(address: 0x1_C799_6614, original: 0x927B_E863, replacement: 0xD503_2FFF,
                  reason: "libsystem_platform _platform_memmove, 4 KB and more: hint #127 (hypercall)"),
            Patch(address: 0x1_C799_6618, original: 0xAC40_0C22, replacement: 0xD65F_03C0,
                  reason: "libsystem_platform _platform_memmove, 4 KB and more: ret"),
            Patch(address: 0x1_C799_6DC4, original: 0xB4FF_FCE1, replacement: 0xD280_0050,
                  reason: "libsystem_platform _platform_memset, 32 KB and more: mov x16, #2 (hypercall memset)"),
            Patch(address: 0x1_C799_6DC8, original: 0xAC00_0000, replacement: 0xD503_2FFF,
                  reason: "libsystem_platform _platform_memset, 32 KB and more: hint #127 (hypercall)"),
            Patch(address: 0x1_C799_6DCC, original: 0xAC01_0000, replacement: 0xD65F_03C0,
                  reason: "libsystem_platform _platform_memset, 32 KB and more: ret"),
            Patch(address: 0x1_C799_6D60, original: 0xAC00_0000, replacement: 0xD280_0050,
                  reason: "libsystem_platform _platform_bzero, 32 KB and more: mov x16, #2 (hypercall memset, x1 = 0)"),
            Patch(address: 0x1_C799_6D64, original: 0xAC01_0000, replacement: 0xD503_2FFF,
                  reason: "libsystem_platform _platform_bzero, 32 KB and more: hint #127 (hypercall)"),
            Patch(address: 0x1_C799_6D68, original: 0x9101_0003, replacement: 0xD65F_03C0,
                  reason: "libsystem_platform _platform_bzero, 32 KB and more: ret"),
            // The CPU renderer's hottest function, its bilinear read of 32-bit textures
            // (CA::OGL::SW::image_sampler<ARGB8_Host, unsigned, true, true, true, true>), runs
            // natively too: hypercall 3 (qemu/patches/inferno/0050) does what it does, pixel for
            // pixel (checked against this code run in an ARM emulator). x17 gets the function's
            // address, for the constants it reads.
            Patch(address: 0x1_8372_0C2C, original: 0xD503_237F, replacement: 0x1000_0011,
                  reason: "QuartzCore image_sampler<ARGB8_Host> (virtual GPU): adr x17, #0"),
            Patch(address: 0x1_8372_0C30, original: 0xD102_C3FF, replacement: 0xD280_0070,
                  reason: "QuartzCore image_sampler<ARGB8_Host> (virtual GPU): mov x16, #3"),
            Patch(address: 0x1_8372_0C34, original: 0x6D01_3BEF, replacement: 0xD503_2FFF,
                  reason: "QuartzCore image_sampler<ARGB8_Host> (virtual GPU): hint #127 (hypercall)"),
            Patch(address: 0x1_8372_0C38, original: 0x6D02_33ED, replacement: 0xD65F_03C0,
                  reason: "QuartzCore image_sampler<ARGB8_Host> (virtual GPU): ret"),
            // Next hottest in the CPU renderer, also native (hypercalls 4-6, patch 0051, checked the
            // same way): the affine bilinear reads of XRGB8 and ARGB8 textures and the color matrix
            // (with unpremultiply and premultiply) behind blurs and vibrancy.
            Patch(address: 0x1_8372_00E4, original: 0x3400_05C1, replacement: 0xD280_0090,
                  reason: "QuartzCore image_sampler<XRGB8_Host, affine> (virtual GPU): mov x16, #4"),
            Patch(address: 0x1_8372_00E8, original: 0xF940_0008, replacement: 0xD503_2FFF,
                  reason: "QuartzCore image_sampler<XRGB8_Host, affine> (virtual GPU): hint #127 (hypercall)"),
            Patch(address: 0x1_8372_00EC, original: 0xF940_010A, replacement: 0xD65F_03C0,
                  reason: "QuartzCore image_sampler<XRGB8_Host, affine> (virtual GPU): ret"),
            Patch(address: 0x1_8372_11AC, original: 0x3400_0501, replacement: 0xD280_00B0,
                  reason: "QuartzCore image_sampler<ARGB8_Host, affine> (virtual GPU): mov x16, #5"),
            Patch(address: 0x1_8372_11B0, original: 0xF940_0008, replacement: 0xD503_2FFF,
                  reason: "QuartzCore image_sampler<ARGB8_Host, affine> (virtual GPU): hint #127 (hypercall)"),
            Patch(address: 0x1_8372_11B4, original: 0xF940_010A, replacement: 0xD65F_03C0,
                  reason: "QuartzCore image_sampler<ARGB8_Host, affine> (virtual GPU): ret"),
            Patch(address: 0x1_8370_8FD8, original: 0xB400_09C2, replacement: 0x1000_0011,
                  reason: "QuartzCore tex_color_matrix_4x4_bias (virtual GPU): adr x17, #0"),
            Patch(address: 0x1_8370_8FDC, original: 0xD000_0B68, replacement: 0xD280_00D0,
                  reason: "QuartzCore tex_color_matrix_4x4_bias (virtual GPU): mov x16, #6"),
            Patch(address: 0x1_8370_8FE0, original: 0xBD4C_2500, replacement: 0xD503_2FFF,
                  reason: "QuartzCore tex_color_matrix_4x4_bias (virtual GPU): hint #127 (hypercall)"),
            Patch(address: 0x1_8370_8FE4, original: 0x1E2E_1001, replacement: 0xD65F_03C0,
                  reason: "QuartzCore tex_color_matrix_4x4_bias (virtual GPU): ret"),
            // And three more (hypercalls 7-9, patch 0053, checked the same way): the nearest-texel
            // ARGB8 read, tex_multiply_color and the DarkenSover blend loop.
            Patch(address: 0x1_8372_1590, original: 0x3400_01C1, replacement: 0xD280_00F0,
                  reason: "QuartzCore image_sampler<ARGB8_Host, nearest> (virtual GPU): mov x16, #7"),
            Patch(address: 0x1_8372_1594, original: 0xF940_000A, replacement: 0xD503_2FFF,
                  reason: "QuartzCore image_sampler<ARGB8_Host, nearest> (virtual GPU): hint #127 (hypercall)"),
            Patch(address: 0x1_8372_1598, original: 0x2946_A408, replacement: 0xD65F_03C0,
                  reason: "QuartzCore image_sampler<ARGB8_Host, nearest> (virtual GPU): ret"),
            Patch(address: 0x1_8370_8A8C, original: 0xB400_0383, replacement: 0xD280_0110,
                  reason: "QuartzCore tex_multiply_color (virtual GPU): mov x16, #8"),
            Patch(address: 0x1_8370_8A90, original: 0x5318_7C48, replacement: 0xD503_2FFF,
                  reason: "QuartzCore tex_multiply_color (virtual GPU): hint #127 (hypercall)"),
            Patch(address: 0x1_8370_8A94, original: 0x5310_5C49, replacement: 0xD65F_03C0,
                  reason: "QuartzCore tex_multiply_color (virtual GPU): ret"),
            Patch(address: 0x1_8370_C264, original: 0xD503_237F, replacement: 0xD280_0130,
                  reason: "QuartzCore Blend::Mode<DarkenSover>::blend (virtual GPU): mov x16, #9"),
            Patch(address: 0x1_8370_C268, original: 0xD101_03FF, replacement: 0xD503_2FFF,
                  reason: "QuartzCore Blend::Mode<DarkenSover>::blend (virtual GPU): hint #127 (hypercall)"),
            Patch(address: 0x1_8370_C26C, original: 0xA901_57F6, replacement: 0xD65F_03C0,
                  reason: "QuartzCore Blend::Mode<DarkenSover>::blend (virtual GPU): ret"),
            // The edge-clamped affine ARGB8 read (hypercall 10, patch 0057, checked the same way).
            Patch(address: 0x1_8372_1014, original: 0x3400_0761, replacement: 0xD280_0150,
                  reason: "QuartzCore image_sampler<ARGB8_Host, clamped affine> (virtual GPU): mov x16, #10"),
            Patch(address: 0x1_8372_1018, original: 0xF940_0009, replacement: 0xD503_2FFF,
                  reason: "QuartzCore image_sampler<ARGB8_Host, clamped affine> (virtual GPU): hint #127 (hypercall)"),
            Patch(address: 0x1_8372_101C, original: 0xF940_012E, replacement: 0xD65F_03C0,
                  reason: "QuartzCore image_sampler<ARGB8_Host, clamped affine> (virtual GPU): ret"),
            // vImage's premultiplied BGRA alpha blend (hypercall 11, patch 0076): the row loop of
            // vImagePremultipliedAlphaBlend_BGRA8888, checked against the original in Unicorn
            // (scripts/vgpu-check/check_valpha.py).
            Patch(address: 0x1_9BAE_CFF4, original: 0xD503_237F, replacement: 0xD280_0170,
                  reason: "vImage vAlpha_Blend_Premultiplied_BGRA_8888 (virtual GPU hypercall): mov x16, #11"),
            Patch(address: 0x1_9BAE_CFF8, original: 0xD101_C3FF, replacement: 0xD503_2FFF,
                  reason: "vImage vAlpha_Blend_Premultiplied_BGRA_8888 (virtual GPU hypercall): hint #127"),
            Patch(address: 0x1_9BAE_CFFC, original: 0xA901_6FFC, replacement: 0xD65F_03C0,
                  reason: "vImage vAlpha_Blend_Premultiplied_BGRA_8888 (virtual GPU hypercall): ret"),
            // QuartzCore's source-over blend of one row (hypercall 12, patch 0077): a wrapper around
            // the vImage blend above, run without vImage's per-call thread and QoS queries.
            Patch(address: 0x1_8370_C1E8, original: 0xD503_237F, replacement: 0xD280_0190,
                  reason: "QuartzCore Blend::Mode<Sover, true>::blend (virtual GPU hypercall): mov x16, #12"),
            Patch(address: 0x1_8370_C1EC, original: 0xD102_03FF, replacement: 0xD503_2FFF,
                  reason: "QuartzCore Blend::Mode<Sover, true>::blend (virtual GPU hypercall): hint #127"),
            Patch(address: 0x1_8370_C1F0, original: 0xA907_7BFD, replacement: 0xD65F_03C0,
                  reason: "QuartzCore Blend::Mode<Sover, true>::blend (virtual GPU hypercall): ret"),
            // QuartzCore scanline's un-premultiplying loop (hypercall 13, patch 0078): its first three
            // instructions become the hypercall and a branch past the loop
            // (scripts/vgpu-check/check_unpremul.py).
            Patch(address: 0x1_8370_621C, original: 0xB940_012C, replacement: 0xD280_01B0,
                  reason: "QuartzCore scanline un-premultiply loop (virtual GPU hypercall): mov x16, #13"),
            Patch(address: 0x1_8370_6220, original: 0x5318_7D8D, replacement: 0xD503_2FFF,
                  reason: "QuartzCore scanline un-premultiply loop (virtual GPU hypercall): hint #127"),
            Patch(address: 0x1_8370_6224, original: 0x5310_5D8E, replacement: 0x1400_002F,
                  reason: "QuartzCore scanline un-premultiply loop (virtual GPU hypercall): b past the loop"),
            // QuartzCore scanline's luminance-curve loop (hypercall 14, patch 0079), the same way; the
            // hypercall finds the luminance weights from the hint's address
            // (scripts/vgpu-check/check_lum.py).
            Patch(address: 0x1_8370_6FCC, original: 0xB840_45AE, replacement: 0xD280_01D0,
                  reason: "QuartzCore scanline luminance curve loop (virtual GPU hypercall): mov x16, #14"),
            Patch(address: 0x1_8370_6FD0, original: 0x5308_3DCF, replacement: 0xD503_2FFF,
                  reason: "QuartzCore scanline luminance curve loop (virtual GPU hypercall): hint #127"),
            Patch(address: 0x1_8370_6FD4, original: 0x5310_5DD0, replacement: 0x1400_002C,
                  reason: "QuartzCore scanline luminance curve loop (virtual GPU hypercall): b past the loop"),
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
            // VirtualAudio (the HAL plug-in that turns the codec's devices into the virtual audio
            // devices iOS plays through) creates none under emulation, so iOS plays no sound:
            // - Its deferred initialisation applies a first route before it has handled the codec's
            //   devices; the route fails ("nort") and the initialisation throws, leaving it "not
            //   initialized". Let the devices in first, and finish even when that route fails:
            //   it is applied again when the ports connect.
            // - Every route starts at the application processor port ('pap '), which nothing
            //   connects when the AP is emulated. Connect it before PortManager publishes it.
            // - Each route also wants the alternate devices of hardware the emulator has none of
            //   (haptics actuator, AOP low-power microphone); treat those as optional like the
            //   others instead of failing the whole route.
            (["System/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio",
              "Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio"],
             [Patch(address: 0x7254, original: 0xA90A_7FE8, replacement: 0x9400_D418,
                    reason: "VirtualAudio deferred initialisation: let the devices in before the first route (bl device manager)"),
              Patch(address: 0x7258, original: 0x9102_83E1, replacement: 0x9406_1499,
                    reason: "VirtualAudio deferred initialisation: let the devices in before the first route (bl allow devices)"),
              Patch(address: 0x725C, original: 0x5280_00C0, replacement: 0x1400_001A,
                    reason: "VirtualAudio deferred initialisation: then build its first route (b 0x72c4)"),
              Patch(address: 0x734C, original: 0x3500_5288, replacement: 0xD503_201F,
                    reason: "VirtualAudio deferred initialisation: finish even when the first route request fails (nop)"),
              Patch(address: 0x7354, original: 0x3500_5528, replacement: 0xD503_201F,
                    reason: "VirtualAudio deferred initialisation: finish even when the first route is refused (nop)"),
              Patch(address: 0x1_1528, original: 0x9100_63F3, replacement: 0x9100_63E0,
                    reason: "VirtualAudio PortManager: connect the application processor port before publishing it (add x0, sp, #0x18)"),
              Patch(address: 0x1_152C, original: 0x9100_8260, replacement: 0x9401_FDB3,
                    reason: "VirtualAudio PortManager: connect the application processor port before publishing it (bl release)"),
              Patch(address: 0x1_1530, original: 0x9401_FDB2, replacement: 0x9100_23E0,
                    reason: "VirtualAudio PortManager: connect the application processor port before publishing it (add x0, sp, #0x8)"),
              Patch(address: 0x1_1534, original: 0x9100_4260, replacement: 0x9401_FDB1,
                    reason: "VirtualAudio PortManager: connect the application processor port before publishing it (bl release)"),
              Patch(address: 0x1_1538, original: 0x9401_FDB0, replacement: 0xAA13_03E0,
                    reason: "VirtualAudio PortManager: connect the application processor port before publishing it (mov x0, x19 (the port))"),
              Patch(address: 0x1_153C, original: 0x9100_63E0, replacement: 0x9406_3DA1,
                    reason: "VirtualAudio PortManager: connect the application processor port before publishing it (bl Connect)"),
              Patch(address: 0x1_1540, original: 0x9401_FDAE, replacement: 0xAA14_03E0,
                    reason: "VirtualAudio PortManager: connect the application processor port before publishing it (mov x0, x20)"),
              Patch(address: 0x1_1544, original: 0x9100_23E0, replacement: 0x5280_0021,
                    reason: "VirtualAudio PortManager: connect the application processor port before publishing it (mov w1, #1)"),
              Patch(address: 0x1_1548, original: 0x9401_FDAC, replacement: 0x9400_10EB,
                    reason: "VirtualAudio PortManager: connect the application processor port before publishing it (bl publish ports)"),
              Patch(address: 0x1_154C, original: 0xAA14_03E0, replacement: 0xD503_201F,
                    reason: "VirtualAudio PortManager: connect the application processor port before publishing it (nop)"),
              Patch(address: 0x1_1550, original: 0x5280_0021, replacement: 0xD503_201F,
                    reason: "VirtualAudio PortManager: connect the application processor port before publishing it (nop)"),
              Patch(address: 0x1_1554, original: 0x9400_10E8, replacement: 0xD503_201F,
                    reason: "VirtualAudio PortManager: connect the application processor port before publishing it (nop)"),
              Patch(address: 0x1C_33B4, original: 0x5400_0F81, replacement: 0xD503_201F,
                    reason: "VirtualAudio routing: an alternate VAD whose ports the hardware lacks (haptics, AOP mic) is skipped instead of failing the route (nop)")]),
        ],
    ]

    /// Applies the patches for `build` (and with `skipSetup` the setup assistant ones) to the shared
    /// cache on the container's system volume. Returns a line per patch saying what happened.
    @discardableResult
    /// Without `hypercalls` the functions that call into the emulator (`hint #127`) are left as they
    /// are: only our TCG answers that hint, a real CPU (Hypervisor.framework) runs it as a NOP.
    public static func apply(build: String, container: APFSContainer, skipSetup: Bool = false,
                             hypercalls: Bool = true) throws -> [String] {
        let patches = ((byBuild[build] ?? []) + (skipSetup ? skipSetupByBuild[build] ?? [] : []))
            .filter { hypercalls || !($0.reason.contains("hypercall") || $0.reason.contains("virtual GPU")) }
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
