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
              Patch(address: 0x1AEC74, original: 0x940B34EB, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1AED58, original: 0x940B34B2, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1AEF34, original: 0x940B343B, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B09E4, original: 0x940B2D8F, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B1E10, original: 0x940B2884, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B24CC, original: 0x940B26D5, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B2534, original: 0x940B26BB, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B28E8, original: 0x940B25CE, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B37F4, original: 0x940B220B, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B3C68, original: 0x940B20EE, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B3E68, original: 0x940B206E, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B3F98, original: 0x940B2022, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B40CC, original: 0x940B1FD5, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B428C, original: 0x940B1F65, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B42E0, original: 0x940B1F50, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B50F8, original: 0x940B1BCA, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B51CC, original: 0x940B1B95, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B5480, original: 0x940B1AE8, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B5548, original: 0x940B1AB6, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B5658, original: 0x940B1A72, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B57F8, original: 0x940B1A0A, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B59EC, original: 0x940B198D, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B5B40, original: 0x940B1938, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B5E00, original: 0x940B1888, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B5EF0, original: 0x940B184C, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B6204, original: 0x940B1787, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B6E04, original: 0x940B1487, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B6ED8, original: 0x940B1452, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B7470, original: 0x940B12EC, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B97F4, original: 0x940B0A0B, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B994C, original: 0x940B09B5, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1B9AA8, original: 0x940B095E, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1BB858, original: 0x940B01F2, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1BB93C, original: 0x940B01B9, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1BBA20, original: 0x940B0180, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1BBBD8, original: 0x940B0112, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1BBE40, original: 0x940B0078, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1BBEFC, original: 0x940B0049, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1BBFD4, original: 0x940B0013, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1BE248, original: 0x940AF776, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1BFF38, original: 0x940AF03A, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C081C, original: 0x940AEE01, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C089C, original: 0x940AEDE1, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C0ABC, original: 0x940AED59, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C0F18, original: 0x940AEC42, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C1170, original: 0x940AEBAC, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C1EB0, original: 0x940AE85C, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C1F10, original: 0x940AE844, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C20AC, original: 0x940AE7DD, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C210C, original: 0x940AE7C5, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C21C4, original: 0x940AE797, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C24AC, original: 0x940AE6DD, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C27DC, original: 0x940AE611, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C2980, original: 0x940AE5A8, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C2DEC, original: 0x940AE48D, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C2F9C, original: 0x940AE421, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C2FFC, original: 0x940AE409, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C3400, original: 0x940AE308, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C34D8, original: 0x940AE2D2, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C3538, original: 0x940AE2BA, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C3DBC, original: 0x940AE099, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C4094, original: 0x940ADFE3, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C4410, original: 0x940ADF04, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C4810, original: 0x940ADE04, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C4938, original: 0x940ADDBA, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C5E6C, original: 0x940AD86D, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C5EDC, original: 0x940AD851, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C62F8, original: 0x940AD74A, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C6724, original: 0x940AD63F, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C69D0, original: 0x940AD594, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C6E70, original: 0x940AD46C, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C6ED8, original: 0x940AD452, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C6F40, original: 0x940AD438, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C6FE8, original: 0x940AD40E, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C719C, original: 0x940AD3A1, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C7568, original: 0x940AD2AE, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)"),
              Patch(address: 0x1C9384, original: 0x940ACB27, replacement: 0x52800020,
                    reason: "TEST VirtualAudio routing detail log on (mov w0, #1)")]),
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
