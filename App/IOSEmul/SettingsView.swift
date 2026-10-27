import SwiftUI
import EmulatorKit
import os

/// UserDefaults keys for everything on the Settings tab.
enum Pref {
    static let theme = "theme"
    static let bootMode = "defaultBootMode"
    static let cpus = "defaultCPUs"
    /// 0: the machine's own default.
    static let memoryMB = "defaultMemoryMB"
    static let translationCacheMB = "translationCacheMB"
    /// QEMURunner.Engine: automatic, jit or interpreter.
    static let engine = "engine"
    static let verboseBoot = "verboseBoot"
    static let verifyDownloads = "verifyDownloads"
    static let cellularDownloads = "cellularDownloads"
    static let keepAwake = "keepScreenAwake"
    static let runInBackground = "runInBackground"

    /// Unlocked by tapping the version number in About.
    static let experimental = "experimentalUnlocked"
    /// Backend id to boot firmware on when no machine model supports it ("" = off).
    static let forceBackend = "experimentalForceBackend"
    static let qemuDebugFlags = "experimentalQEMUDebugFlags"
    static let extraBootArgs = "experimentalExtraBootArgs"
    static let serialConsole = "experimentalSerialConsole"
    static let skipFirstBootErase = "experimentalSkipFirstBootErase"
    /// Raw arguments appended to the QEMU command line.
    static let extraQEMUArgs = "experimentalExtraQEMUArgs"
    static let fpsCounter = "experimentalFPSCounter"
    /// Monitor console, pause/resume, reset and screenshots on the running machine.
    static let machineTools = "experimentalMachineTools"
    /// IPSW explorer, DeviceTree browser, logs and disk wipe on the firmware page.
    static let firmwareTools = "experimentalFirmwareTools"
    /// Settings written into the emulated iOS when it is installed (GuestTweaks).
    static let guestVoiceOver = "experimentalGuestVoiceOver"
    static let guestZoom = "guestZoom"
    static let guestAssistiveTouch = "guestAssistiveTouch"
    static let guestBoldText = "guestBoldText"
    static let guestReduceMotion = "guestReduceMotion"
    static let guestReduceTransparency = "guestReduceTransparency"
    static let guestIncreaseContrast = "guestIncreaseContrast"
    static let guestInvertColors = "guestInvertColors"
    static let guestGrayscale = "guestGrayscale"
    static let guestTextSize = "guestTextSize"
    static let guestAppearance = "guestAppearance"
    static let guestLanguage = "guestLanguage"
    static let guestRegion = "guestRegion"
    static let guestDeviceName = "guestDeviceName"
    static let guestSkipSetup = "guestSkipSetup"
    static let guest24Hour = "guest24Hour"
    static let guestKeys = [guestVoiceOver, guestZoom, guestAssistiveTouch, guestBoldText, guestReduceMotion,
                            guestReduceTransparency, guestIncreaseContrast, guestInvertColors, guestGrayscale,
                            guestTextSize, guestAppearance, guestLanguage, guestRegion, guestDeviceName,
                            guestSkipSetup, guest24Hour]

    /// The emulated-iOS settings for the next install; empty while experimental features are locked.
    static var guestTweaks: GuestTweaks {
        var t = GuestTweaks()
        guard defaults.bool(forKey: experimental) else { return t }
        t.voiceOver = defaults.bool(forKey: guestVoiceOver)
        t.zoom = defaults.bool(forKey: guestZoom)
        t.assistiveTouch = defaults.bool(forKey: guestAssistiveTouch)
        t.boldText = defaults.bool(forKey: guestBoldText)
        t.reduceMotion = defaults.bool(forKey: guestReduceMotion)
        t.reduceTransparency = defaults.bool(forKey: guestReduceTransparency)
        t.increaseContrast = defaults.bool(forKey: guestIncreaseContrast)
        t.invertColors = defaults.bool(forKey: guestInvertColors)
        t.grayscale = defaults.bool(forKey: guestGrayscale)
        t.textSize = GuestTweaks.TextSize(rawValue: defaults.string(forKey: guestTextSize) ?? "") ?? .system
        t.appearance = GuestTweaks.Appearance(rawValue: defaults.string(forKey: guestAppearance) ?? "") ?? .system
        t.language = experimentalString(guestLanguage)
        t.region = experimentalString(guestRegion)
        t.deviceName = experimentalString(guestDeviceName)
        t.skipSetupAssistant = defaults.bool(forKey: guestSkipSetup)
        t.use24HourClock = defaults.bool(forKey: guest24Hour)
        return t
    }

    static func register() {
        UserDefaults.standard.register(defaults: [
            theme: AppTheme.aurora.rawValue,
            bootMode: BootMode.direct.rawValue,
            cpus: 2,
            memoryMB: 0,
            translationCacheMB: QEMURunner.defaultTranslationCacheMB,
            engine: QEMURunner.Engine.automatic.rawValue,
            verboseBoot: true,
            verifyDownloads: true,
            cellularDownloads: false,
            keepAwake: true,
            runInBackground: true,
            experimental: false,
            forceBackend: "",
            qemuDebugFlags: "",
            extraBootArgs: "",
            serialConsole: false,
            skipFirstBootErase: false,
            extraQEMUArgs: "",
            fpsCounter: false,
            machineTools: false,
            firmwareTools: false,
            guestVoiceOver: false,
        ])
        applyEngine()
    }

    /// Hands the engine setting to QEMURunner, which reads it when a machine is prepared.
    static func applyEngine() {
        QEMURunner.preferredEngine = QEMURunner.Engine(rawValue: defaults.string(forKey: engine) ?? "") ?? .automatic
    }

    static var defaults: UserDefaults { .standard }

    /// An experimental setting's value, or nil while experimental features are locked.
    static func experimentalString(_ key: String) -> String? {
        guard defaults.bool(forKey: experimental) else { return nil }
        let value = (defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// An experimental toggle, false while experimental features are locked.
    static func experimentalBool(_ key: String) -> Bool {
        defaults.bool(forKey: experimental) && defaults.bool(forKey: key)
    }

    static var experimentalSerialConsole: Bool { experimentalBool(serialConsole) }

    /// Every experimental key, reset when the features are turned off.
    static let experimentalKeys = [forceBackend, qemuDebugFlags, extraBootArgs, serialConsole, skipFirstBootErase,
                                   extraQEMUArgs, fpsCounter, machineTools, firmwareTools] + guestKeys
}

extension BootMode {
    var title: String {
        switch self {
        case .direct: return "Install directly"
        case .auto: return "Restore via ramdisk"
        case .enterRecovery: return "Force restore ramdisk"
        case .exitRecovery: return "Force installed OS"
        }
    }

    var subtitle: String {
        switch self {
        case .direct: return "Writes iOS straight from the IPSW. No computer needed."
        case .auto: return "Boots Apple's restore ramdisk until a restore has run."
        case .enterRecovery: return "Boots the restore ramdisk again."
        case .exitRecovery: return "Boots whatever is installed on the virtual disk."
        }
    }
}

enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }
    static let sourceURL = URL(string: "https://github.com/vytska69/Ios-emul")!
    static let issuesURL = URL(string: "https://github.com/vytska69/Ios-emul/issues/new")!

    /// Whether this IPA was built with the QEMU framework (a failed QEMU build ships without it).
    static var hasEmulatorCore: Bool {
        guard let frameworks = Bundle.main.privateFrameworksURL else { return false }
        return FileManager.default.fileExists(
            atPath: frameworks.appendingPathComponent("qemu-aarch64-softmmu.framework").path)
    }

    /// Hardware identifier of the phone running the app, e.g. "iPhone14,2".
    static var hardware: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

// MARK: - Settings home

struct SettingsView: View {
    @AppStorage(Pref.theme) private var themeName = AppTheme.aurora.rawValue
    @AppStorage(Pref.experimental) private var experimental = false
    @AppStorage(Pref.bootMode) private var bootMode = BootMode.direct.rawValue
    @AppStorage(Pref.translationCacheMB) private var cacheMB = QEMURunner.defaultTranslationCacheMB

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PageHeader(symbol: "slider.horizontal.3", title: "Settings",
                               subtitle: "Defaults for new boots, the emulator core and downloads")

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Theme", icon: "paintpalette")
                        Card { ThemePicker(selection: $themeName) }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Machines", icon: "cpu")
                        Card(padding: 6) {
                            SettingsLink(symbol: "power", title: "New boots",
                                         detail: (BootMode(rawValue: bootMode) ?? .direct).title) { BootDefaultsPage() }
                            RowDivider()
                            SettingsLink(symbol: "bolt.horizontal", title: "Emulator",
                                         detail: "\(cacheMB) MB cache · JIT \(QEMURunner.jitStatusWord)") { EmulatorPage() }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Data", icon: "externaldrive")
                        Card(padding: 6) {
                            SettingsLink(symbol: "arrow.down.circle", title: "Downloads",
                                         detail: "SHA-1 check, mobile data") { DownloadsPage() }
                            RowDivider()
                            SettingsLink(symbol: "internaldrive", title: "Storage",
                                         detail: "Virtual disks and IPSWs") { StoragePage() }
                        }
                    }

                    if experimental {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(text: "Developer", icon: "flask")
                            Card(padding: 6) {
                                SettingsLink(symbol: "flask.fill", title: "Experimental",
                                             detail: "Unsupported firmware, QEMU logs, boot-args", tint: .orange) {
                                    ExperimentalPage()
                                }
                            }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "App", icon: "app.badge")
                        Card(padding: 6) {
                            SettingsLink(symbol: "info.circle", title: "About iOS Emul",
                                         detail: "Version \(AppInfo.version) (\(AppInfo.build))") { AboutPage() }
                            RowDivider()
                            SettingsLink(symbol: "stethoscope", title: "Diagnostics",
                                         detail: DiagnosticsPage.summary) { DiagnosticsPage() }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 32)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: experimental)
            }
            .screenStyle()
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

extension QEMURunner {
    /// One word for the Settings summary row.
    static var jitStatusWord: String {
        if !needsJIT { return "interpreter" }
        return jitAvailable ? "on" : "off"
    }
}

// MARK: - Building blocks

private struct PageHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            GlyphTile(symbol: symbol, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(subtitle).font(.footnote).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.top, 8)
    }
}

/// A settings sub-page: header plus cards on the app background.
private struct SettingsPage<Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(symbol: symbol, title: title, subtitle: subtitle)
                content
            }
            .padding(.horizontal, 16).padding(.bottom, 32)
        }
        .screenStyle()
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsLink<Destination: View>: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let title: String
    let detail: String
    var tint: Color?
    @ViewBuilder var destination: Destination

    var body: some View {
        NavigationLink { destination } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint ?? theme.accent)
                    .frame(width: 34, height: 34)
                    .background((tint ?? theme.accent).opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text(detail).font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.3))
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RowDivider: View {
    var body: some View { Divider().overlay(.white.opacity(0.08)).padding(.leading, 56) }
}

private struct ToggleRow: View {
    @Environment(\.theme) private var theme
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.5))
            }
        }
        .tint(theme.accent)
    }
}

private struct Hint: View {
    let text: String
    var body: some View { Text(text).font(.caption).foregroundStyle(.white.opacity(0.5)) }
}

private struct ThemePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 12) {
            ForEach(AppTheme.allCases) { option in
                Button { selection = option.rawValue } label: {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(option.gradient)
                            .frame(height: 50)
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white, lineWidth: selection == option.rawValue ? 2.5 : 0))
                        Text(option.title).font(.caption.weight(.semibold))
                            .foregroundStyle(selection == option.rawValue ? Color.white : Color.white.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Pages

private struct BootDefaultsPage: View {
    @Environment(\.theme) private var theme
    @AppStorage(Pref.bootMode) private var bootMode = BootMode.direct.rawValue
    @AppStorage(Pref.cpus) private var cpus = 2
    @AppStorage(Pref.memoryMB) private var memoryMB = 0

    var body: some View {
        SettingsPage(symbol: "power", title: "New boots", subtitle: "What the firmware page starts with") {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Boot mode", icon: "arrow.triangle.branch")
                Card {
                    ForEach([BootMode.direct, .auto, .enterRecovery, .exitRecovery], id: \.self) { mode in
                        Button { bootMode = mode.rawValue } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: bootMode == mode.rawValue ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(bootMode == mode.rawValue ? theme.accent : Color.white.opacity(0.4))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.title).font(.subheadline.weight(.semibold))
                                    Text(mode.subtitle).font(.caption).foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Resources", icon: "memorychip")
                Card {
                    Stepper(value: $cpus, in: 1...8) { InfoRow(label: "CPU cores", value: "\(cpus)") }
                    Divider().overlay(.white.opacity(0.08))
                    InfoRow(label: "Memory", value: memoryMB == 0 ? "Machine default" : "\(memoryMB) MB")
                    Slider(value: Binding(get: { Double(memoryMB) }, set: { memoryMB = Int($0) }),
                           in: 0...8192, step: 512)
                        .tint(theme.accent)
                    Hint(text: "0 uses each machine's default. Machines with a fixed RAM size (iPhone 6s: 2 GB) ignore this.")
                }
            }
        }
    }
}

private struct EmulatorPage: View {
    @AppStorage(Pref.translationCacheMB) private var cacheMB = QEMURunner.defaultTranslationCacheMB
    @AppStorage(Pref.verboseBoot) private var verboseBoot = true
    @AppStorage(Pref.keepAwake) private var keepAwake = true
    @AppStorage(Pref.runInBackground) private var runInBackground = true

    @AppStorage(Pref.engine) private var engine = QEMURunner.Engine.automatic.rawValue

    private var jit: (String, Color, String, String) {
        _ = engine  // re-evaluate when the setting changes
        if !QEMURunner.needsJIT {
            return ("Interpreter", .green, "checkmark.circle",
                    "Guest code is interpreted: no JIT needed, but several times slower.")
        }
        if QEMURunner.preparedJITMB > 0 {
            return ("Enabled", .green, "bolt.fill",
                    "StikDebug prepared \(QEMURunner.preparedJITMB) MB of JIT memory at launch (iOS 26+); the translation cache stays at that size until the next launch.")
        }
        return QEMURunner.jitAvailable
            ? ("Enabled", .green, "bolt.fill", "Generated code can run. On iOS 26 and later JIT memory must also be prepared: use Enable JIT with StikDebug below, which picks the right script.")
            : ("Off", .orange, "bolt.slash", "Open the app through StikDebug or TrollStore's Open with JIT before booting.")
    }

    var body: some View {
        SettingsPage(symbol: "bolt.horizontal", title: "Emulator", subtitle: "The QEMU core running inside the app") {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "JIT", icon: "bolt")
                Card {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Code generation").font(.subheadline.weight(.semibold))
                            Hint(text: jit.3)
                        }
                        Spacer()
                        Chip(text: jit.0, color: jit.1, icon: jit.2)
                    }
                    if QEMURunner.jitBundled && QEMURunner.preparedJITMB == 0 {
                        StikDebugButton()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Engine", icon: "cpu")
                Card {
                    Picker("Engine", selection: $engine) {
                        Text("Automatic").tag(QEMURunner.Engine.automatic.rawValue)
                        Text("JIT").tag(QEMURunner.Engine.jit.rawValue)
                        Text("Interpreter").tag(QEMURunner.Engine.interpreter.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!(QEMURunner.interpreterBundled && QEMURunner.jitBundled))
                    .onChange(of: engine) { _ in Pref.applyEngine() }
                    if QEMURunner.interpreterBundled && QEMURunner.jitBundled {
                        Hint(text: "Automatic uses JIT when it is enabled for the app and the interpreter otherwise. Choose Interpreter if machines stop right after starting with JIT on. Applies to machines started afterwards.")
                    } else {
                        Hint(text: "This build has only the \(QEMURunner.jitBundled ? "JIT" : "interpreter") engine; the interpreter for running without JIT comes with a newer build.")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Performance", icon: "speedometer")
                Card {
                    Text("Translation cache").font(.subheadline.weight(.semibold))
                    Picker("Translation cache", selection: $cacheMB) {
                        ForEach([128, 256, 512, 1024], id: \.self) { Text("\($0) MB").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Hint(text: "Larger is faster: when the cache fills, QEMU throws away all translated code and starts over. iOS guests want at least 512 MB. It counts against the memory iOS allows the app, next to the guest RAM: 1024 MB only fits with a smaller guest (e.g. 2–3 GB). With StikDebug the size is fixed when the app opens, so reopen it after a change.")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Sound", icon: "speaker.wave.2")
                Card {
                    Button {
                        MachineAudio.shared.playTestTone()
                    } label: {
                        Label("Play test tone", systemImage: "play.circle")
                            .font(.subheadline.weight(.semibold))
                    }
                    Hint(text: "Plays a short tone through the app's own audio, with no emulator involved. If you hear it, the app can play sound on this device and any silence is the emulated phone making none; if you do not, the app's audio output is the problem.")
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        VStack(alignment: .leading, spacing: 2) {
                            Hint(text: "Engine running: \(MachineAudio.shared.engineRunning ? "yes" : "no")")
                            Hint(text: "Guest sound source attached: \(MachineAudio.shared.guestSourceAttached ? "yes" : "no")")
                            Hint(text: "Guest audio read so far: \(MachineAudio.totalGuestBytesRead / 1024) KB")
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Behaviour", icon: "gearshape.2")
                Card {
                    ToggleRow(title: "Verbose boot", detail: "Kernel text on screen instead of the Apple logo.", isOn: $verboseBoot)
                    Divider().overlay(.white.opacity(0.08))
                    ToggleRow(title: "Keep screen awake", detail: "While a machine is running.", isOn: $keepAwake)
                    Divider().overlay(.white.opacity(0.08))
                    ToggleRow(title: "Run in background",
                              detail: "The machine keeps running when you leave the app or lock the phone (plays silent audio, as UTM does). Uses battery and warms the phone; iOS can still close the app when memory runs short. Applies to the next boot.",
                              isOn: $runInBackground)
                }
            }
        }
    }
}

private struct DownloadsPage: View {
    @AppStorage(Pref.verifyDownloads) private var verify = true
    @AppStorage(Pref.cellularDownloads) private var cellular = false

    var body: some View {
        SettingsPage(symbol: "arrow.down.circle", title: "Downloads", subtitle: "IPSWs fetched from Apple via ipsw.me") {
            Card {
                ToggleRow(title: "Verify SHA-1", detail: "Check each IPSW against ipsw.me before importing it.", isOn: $verify)
                Divider().overlay(.white.opacity(0.08))
                ToggleRow(title: "Use mobile data", detail: "IPSWs are several GB. Applies to downloads started afterwards.", isOn: $cellular)
            }
        }
    }
}

private struct StoragePage: View {
    @State private var machineBytes: Int64?
    @State private var firmwareBytes: Int64?
    @State private var confirmWipe = false

    var body: some View {
        SettingsPage(symbol: "internaldrive", title: "Storage", subtitle: "Space the app uses on this device") {
            Card {
                InfoRow(label: "Virtual disks", value: machineBytes.map(format) ?? "…")
                InfoRow(label: "Downloaded IPSWs", value: firmwareBytes.map(format) ?? "…")
                InfoRow(label: "Free on device", value: DownloadManager.freeSpace().map(format) ?? "–")
            }
            Card {
                Button { confirmWipe = true } label: { Label("Delete machine disks", systemImage: "trash") }
                    .buttonStyle(GhostButtonStyle())
                Hint(text: "Installed systems are removed; the next boot installs from the IPSW again. Imported IPSWs stay. Downloaded IPSWs are in Files → On My iPhone → iOS Emul → Firmware.")
            }
        }
        .task { await measure() }
        .confirmationDialog("Delete every virtual disk?", isPresented: $confirmWipe, titleVisibility: .visible) {
            Button("Delete machine disks", role: .destructive) {
                try? FileManager.default.removeItem(at: Library.machinesDirectory)
                Task { await measure() }
            }
        }
    }

    private func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private func measure() async {
        let (machines, firmware) = await Task.detached(priority: .utility) {
            (StoragePage.size(of: Library.machinesDirectory), StoragePage.size(of: DownloadManager.directory))
        }.value
        machineBytes = machines
        firmwareBytes = firmware
    }

    /// Allocated size of everything under a folder (virtual disks are sparse).
    nonisolated static func size(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

// MARK: - About

/// What the installer signed this copy with and what the emulator can use, so a machine that
/// will not start after installing the IPA some other way can be explained.
private struct DiagnosticsPage: View {
    @Environment(\.theme) private var theme
    @State private var copied = false
    private let info = SigningInfo.current

    private struct Check: Identifiable {
        let title: String
        let value: String
        let ok: Bool?
        let help: String?
        var id: String { title }
    }

    static var summary: String {
        let info = SigningInfo.current
        let missing = [info.getTaskAllow, info.increasedMemoryLimit, info.extendedVirtualAddressing].filter { !$0 }.count
        return missing == 0 ? "Signing looks right" : "\(missing) entitlement\(missing == 1 ? "" : "s") missing"
    }

    private var checks: [Check] {
        let availableMB = Int(os_proc_available_memory() / 1_048_576)
        let expiry = info.profileExpiry.map { $0.formatted(date: .abbreviated, time: .omitted) }
        return [
            Check(title: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "?", ok: nil, help: nil),
            Check(title: "Provisioning profile",
                  value: info.profileKind.map { [$0, info.profileTeam, expiry.map { "until \($0)" }].compactMap { $0 }.joined(separator: " · ") } ?? "none",
                  ok: info.profileKind.map { $0 == "Development" },
                  help: info.profileKind == "Development" ? nil : "Only a development profile allows JIT. Re-install the IPA signed with a development certificate and profile, not a distribution (ad hoc, App Store or enterprise) one."),
            Check(title: "get-task-allow (JIT)", value: info.getTaskAllow ? "present" : "missing", ok: info.getTaskAllow,
                  help: info.getTaskAllow ? nil : "Without it no JIT enabler (StikDebug, SideStore) can turn on JIT, and the app falls back to the much slower interpreter."),
            Check(title: "Increased memory limit", value: info.increasedMemoryLimit ? "present" : "missing", ok: info.increasedMemoryLimit,
                  help: info.increasedMemoryLimit ? nil : "Without it iOS ends the app when the emulated phone's memory is set up. With a paid developer account, enable \"Increased Memory Limit\" for this App ID, or let the installer keep the IPA's entitlements."),
            Check(title: "Extended virtual addressing", value: info.extendedVirtualAddressing ? "present" : "missing", ok: info.extendedVirtualAddressing,
                  help: info.extendedVirtualAddressing ? nil : "Without it the app cannot reserve address space for a 4 GB guest and QEMU fails to start. It needs a paid developer account with \"Extended Virtual Address Space\" enabled for this App ID."),
            Check(title: "JIT enabled now", value: QEMURunner.jitAvailable ? "yes" : "no", ok: QEMURunner.jitAvailable,
                  help: QEMURunner.jitAvailable ? nil : "Launch the app through StikDebug (or another JIT enabler) for the fast engine."),
            Check(title: "Engine for the next boot",
                  value: QEMURunner.activeEngine == .jit ? "JIT" : "interpreter", ok: nil, help: nil),
            Check(title: "Emulator cores in the IPA",
                  value: [QEMURunner.jitBundled ? "JIT" : nil, QEMURunner.interpreterBundled ? "interpreter" : nil].compactMap { $0 }.joined(separator: " + ").nilIfEmpty ?? "none",
                  ok: QEMURunner.jitBundled || QEMURunner.interpreterBundled, help: nil),
            Check(title: "Memory iOS allows now", value: "\(availableMB) MB", ok: availableMB == 0 ? nil : availableMB >= 3000,
                  help: availableMB > 0 && availableMB < 3000 ? "A 4 GB machine needs more; check the memory entitlements above or lower the machine's memory." : nil),
            Check(title: "Phone", value: "\(AppInfo.hardware) · iOS \(UIDevice.current.systemVersion)", ok: nil, help: nil),
        ]
    }

    private var report: String {
        (["iOS Emul \(AppInfo.version) (\(AppInfo.build))"] + checks.map { "\($0.title): \($0.value)" }).joined(separator: "\n")
    }

    var body: some View {
        SettingsPage(symbol: "stethoscope", title: "Diagnostics", subtitle: "How this copy was signed and what the emulator can use") {
            Card(padding: 14) {
                ForEach(checks) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: check.ok == nil ? "info.circle" : check.ok! ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(check.ok == nil ? .white.opacity(0.4) : check.ok! ? theme.accent : .orange)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(check.title).font(.subheadline.weight(.semibold))
                            Text(check.value).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.7)).textSelection(.enabled)
                            if let help = check.help { Hint(text: help) }
                        }
                    }
                }
            }
            Button {
                UIPasteboard.general.string = report
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy report", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(12)
                    .background(theme.accent.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)
            Hint(text: "Installers re-sign the IPA and some leave out entitlements the emulator needs without saying so. SideStore keeps them.")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct AboutPage: View {
    @Environment(\.theme) private var theme
    @AppStorage(Pref.experimental) private var experimental = false
    @State private var taps = 0
    @State private var toast: String?

    /// Taps on the version number that unlock the experimental settings.
    private let tapsToUnlock = 7

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    ZStack {
                        Circle().fill(theme.gradient(opacity: 0.22)).frame(width: 150, height: 150).blur(radius: 18)
                        GlyphTile(symbol: "cpu", size: 96)
                            .shadow(color: theme.colors.0.opacity(0.5), radius: 20)
                    }
                    Text("iOS Emul").font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Any IPSW, on an emulated Apple device, on your phone.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)

                    Button(action: tapVersion) {
                        HStack(spacing: 6) {
                            Text("Version \(AppInfo.version)")
                            Text("·").foregroundStyle(.white.opacity(0.4))
                            Text("Build \(AppInfo.build)")
                            if experimental { Image(systemName: "flask.fill").foregroundStyle(.orange) }
                        }
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.white.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    if let toast {
                        Text(toast).font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .padding(.top, 12)

                VStack(spacing: 10) {
                    Link(destination: AppInfo.sourceURL) {
                        Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .buttonStyle(GlowButtonStyle())
                    Link(destination: AppInfo.issuesURL) {
                        Label("Report a problem", systemImage: "exclamationmark.bubble")
                    }
                    .buttonStyle(GhostButtonStyle())
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "This build", icon: "shippingbox")
                    Card {
                        InfoRow(label: "Version", value: AppInfo.version)
                        InfoRow(label: "Build", value: AppInfo.build)
                        InfoRow(label: "Emulator core", value: AppInfo.hasEmulatorCore ? "Included" : "Missing")
                        InfoRow(label: "Code generation", value: QEMURunner.needsJIT ? "JIT (\(QEMURunner.jitStatusWord))" : "Interpreter")
                        InfoRow(label: "Device", value: AppInfo.hardware, mono: true)
                        InfoRow(label: "iOS", value: UIDevice.current.systemVersion)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Built on", icon: "heart")
                    Card {
                        Credit(name: "QEMUAppleSilicon", role: "Apple machine models (A9, A13), GPLv3",
                               url: "https://github.com/ChefKissInc/QEMUAppleSilicon")
                        Credit(name: "UTM", role: "QEMU on iOS: shared library and JIT patches",
                               url: "https://github.com/utmapp/UTM")
                        Credit(name: "ipsw.me", role: "Firmware catalogue", url: "https://ipsw.me")
                        Credit(name: "Asahi Linux", role: "Apple Silicon hardware documentation",
                               url: "https://asahilinux.org")
                    }
                }

                Text("Use only software you are licensed to run. Not affiliated with Apple or ChefKiss.")
                    .font(.caption).foregroundStyle(.white.opacity(0.4)).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16).padding(.bottom, 32)
        }
        .screenStyle()
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tapVersion() {
        if experimental {
            show("Experimental features are already on")
            return
        }
        taps += 1
        let left = tapsToUnlock - taps
        if left <= 0 {
            withAnimation(.spring(response: 0.35)) { experimental = true }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            show("Experimental features unlocked — see Settings")
        } else if taps >= 3 {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            show("\(left) more \(left == 1 ? "tap" : "taps") to unlock experimental features")
        }
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
        let shown = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if toast == shown { withAnimation { toast = nil } }
        }
    }
}

private struct Credit: View {
    let name: String
    let role: String
    let url: String

    var body: some View {
        Link(destination: URL(string: url)!) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text(role).font(.caption).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}

// MARK: - Experimental

private struct ExperimentalPage: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Pref.experimental) private var experimental = false
    @AppStorage(Pref.forceBackend) private var forceBackend = ""
    @AppStorage(Pref.qemuDebugFlags) private var debugFlags = ""
    @AppStorage(Pref.extraBootArgs) private var bootArgs = ""
    @AppStorage(Pref.extraQEMUArgs) private var qemuArgs = ""
    @AppStorage(Pref.serialConsole) private var serialConsole = false
    @AppStorage(Pref.skipFirstBootErase) private var skipErase = false
    @AppStorage(Pref.fpsCounter) private var fpsCounter = false
    @AppStorage(Pref.machineTools) private var machineTools = false
    @AppStorage(Pref.firmwareTools) private var firmwareTools = false

    private let debugPresets = ["guest_errors", "guest_errors,unimp", "int", "in_asm", "exec,nochain,int"]

    private var guestSummary: String {
        let count = Pref.guestTweaks.files().count
        return count == 0 ? "VoiceOver, appearance, language, setup assistant…" : "\(count) preference \(count == 1 ? "file" : "files") on install"
    }

    var body: some View {
        SettingsPage(symbol: "flask.fill", title: "Experimental", subtitle: "For bringing up new devices. Things may break.") {
            Card {
                Label("These change how machines are built and started. A wrong value can make QEMU exit, which closes the app.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Machines", icon: "cpu")
                Card {
                    Text("Boot unsupported firmware on").font(.subheadline.weight(.semibold))
                    Picker("Machine", selection: $forceBackend) {
                        Text("Off").tag("")
                        ForEach(BackendRegistry.shared.backends, id: \.id) { backend in
                            Text(backend.displayName).tag(backend.id)
                        }
                    }
                    .pickerStyle(.menu)
                    Hint(text: "Firmware without a machine model (e.g. iPhone XR) gets a Boot button on this machine, like the boot tests' force_backend.")
                    Divider().overlay(.white.opacity(0.08))
                    ToggleRow(title: "Skip first-boot erase",
                              detail: "Boot a direct install as written instead of resuming Erase All Content (no system keybag).",
                              isOn: $skipErase)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Emulated iOS", icon: "iphone.gen3")
                Card(padding: 6) {
                    SettingsLink(symbol: "gearshape.2", title: "Emulated iOS settings",
                                 detail: guestSummary, tint: .orange) { GuestTweaksPage() }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Command line", icon: "terminal")
                Card {
                    Text("Extra boot-args").font(.subheadline.weight(.semibold))
                    MonoField(placeholder: "e.g. cs_enforcement_disable=1", text: $bootArgs)
                    Hint(text: "Appended to the kernel command line of every boot.")
                    Divider().overlay(.white.opacity(0.08))
                    Text("Extra QEMU arguments").font(.subheadline.weight(.semibold))
                    MonoField(placeholder: "e.g. -icount shift=auto", text: $qemuArgs)
                    Hint(text: "Split on spaces and appended to QEMU's arguments.")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Diagnostics", icon: "stethoscope")
                Card {
                    Text("QEMU debug flags").font(.subheadline.weight(.semibold))
                    MonoField(placeholder: "guest_errors,unimp", text: $debugFlags)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(debugPresets, id: \.self) { preset in
                                Button { debugFlags = preset } label: {
                                    Chip(text: preset, color: debugFlags == preset ? .orange : .white.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Hint(text: "Passed as -d and written to qemu-debug.log in the machine folder. int and exec produce gigabytes.")
                    Divider().overlay(.white.opacity(0.08))
                    ToggleRow(title: "Serial console", detail: "Kernel serial output over the running machine.", isOn: $serialConsole)
                    ToggleRow(title: "Frame counter", detail: "Display frames per second in the status pill.", isOn: $fpsCounter)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Tools", icon: "wrench.and.screwdriver")
                Card {
                    ToggleRow(title: "Machine tools",
                              detail: "QEMU monitor console, pause and resume, reset and screenshots while a machine runs.",
                              isOn: $machineTools)
                    Divider().overlay(.white.opacity(0.08))
                    ToggleRow(title: "Firmware tools",
                              detail: "IPSW file explorer with export, DeviceTree browser, machine logs and disk wipe on each firmware page.",
                              isOn: $firmwareTools)
                }
            }

            Button(role: .destructive) {
                Pref.experimentalKeys.forEach { Pref.defaults.removeObject(forKey: $0) }
                experimental = false
                dismiss()
            } label: {
                Label("Turn off experimental features", systemImage: "xmark.octagon")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GhostButtonStyle())
        }
    }
}

private struct MonoField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .font(.callout.monospaced())
            .padding(10).background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Emulated iOS settings

private struct GuestTweaksPage: View {
    @AppStorage(Pref.guestVoiceOver) private var voiceOver = false
    @AppStorage(Pref.guestZoom) private var zoom = false
    @AppStorage(Pref.guestAssistiveTouch) private var assistiveTouch = false
    @AppStorage(Pref.guestBoldText) private var boldText = false
    @AppStorage(Pref.guestReduceMotion) private var reduceMotion = false
    @AppStorage(Pref.guestReduceTransparency) private var reduceTransparency = false
    @AppStorage(Pref.guestIncreaseContrast) private var increaseContrast = false
    @AppStorage(Pref.guestInvertColors) private var invertColors = false
    @AppStorage(Pref.guestGrayscale) private var grayscale = false
    @AppStorage(Pref.guestTextSize) private var textSize = GuestTweaks.TextSize.system.rawValue
    @AppStorage(Pref.guestAppearance) private var appearance = GuestTweaks.Appearance.system.rawValue
    @AppStorage(Pref.guestLanguage) private var language = ""
    @AppStorage(Pref.guestRegion) private var region = ""
    @AppStorage(Pref.guestDeviceName) private var deviceName = ""
    @AppStorage(Pref.guestSkipSetup) private var skipSetup = false
    @AppStorage(Pref.guest24Hour) private var clock24 = false
    @AppStorage(Pref.skipFirstBootErase) private var skipErase = false

    private let languages: [(String, String)] = [
        ("", "IPSW default (English)"), ("en", "English"), ("lt", "Lietuvių"), ("de", "Deutsch"), ("fr", "Français"),
        ("es", "Español"), ("it", "Italiano"), ("pl", "Polski"), ("ru", "Русский"), ("uk", "Українська"),
        ("ja", "日本語"), ("zh-Hans", "简体中文"),
    ]
    private let regions: [(String, String)] = [
        ("", "IPSW default"), ("lt_LT", "Lithuania"), ("en_US", "United States"), ("en_GB", "United Kingdom"),
        ("de_DE", "Germany"), ("fr_FR", "France"), ("es_ES", "Spain"), ("it_IT", "Italy"), ("pl_PL", "Poland"),
        ("uk_UA", "Ukraine"), ("ja_JP", "Japan"), ("zh_CN", "China"),
    ]

    var body: some View {
        SettingsPage(symbol: "iphone.gen3", title: "Emulated iOS", subtitle: "How the installed iOS starts up") {
            Card {
                Label("Written into the installed iOS's own preference files on the Data volume when iOS is installed directly: they apply to new machines, or after Wipe this machine. The keys are the ones iOS keeps for these settings; no emulated iOS reaches its home screen yet, so they are untested there.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.white.opacity(0.65))
                if !skipErase {
                    Hint(text: "The first-boot erase recreates the Data volume and drops them.")
                    Button { skipErase = true } label: { Label("Skip the first-boot erase", systemImage: "checkmark.circle") }
                        .buttonStyle(GhostButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Start-up", icon: "sunrise")
                Card {
                    ToggleRow(title: "Skip the setup assistant",
                              detail: "Marks setup as done, straight to the home screen.", isOn: $skipSetup)
                    Divider().overlay(.white.opacity(0.08))
                    Text("Device name").font(.subheadline.weight(.semibold))
                    TextField("iPhone", text: $deviceName)
                        .font(.callout)
                        .padding(10).background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Language & region", icon: "globe")
                Card {
                    Picker("Language", selection: $language) {
                        ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Picker("Region", selection: $region) {
                        ForEach(regions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    ToggleRow(title: "24-hour time", detail: "Whatever the region's default.", isOn: $clock24)
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Display", icon: "sun.max")
                Card {
                    Picker("Appearance", selection: $appearance) {
                        Text("Default").tag(GuestTweaks.Appearance.system.rawValue)
                        Text("Light").tag(GuestTweaks.Appearance.light.rawValue)
                        Text("Dark").tag(GuestTweaks.Appearance.dark.rawValue)
                    }
                    .pickerStyle(.segmented)
                    Text("Text size").font(.subheadline.weight(.semibold))
                    Picker("Text size", selection: $textSize) {
                        Text("Default").tag(GuestTweaks.TextSize.system.rawValue)
                        Text("Large").tag(GuestTweaks.TextSize.large.rawValue)
                        Text("XL").tag(GuestTweaks.TextSize.extraLarge.rawValue)
                        Text("Max").tag(GuestTweaks.TextSize.accessibility.rawValue)
                    }
                    .pickerStyle(.segmented)
                    ToggleRow(title: "Bold text", detail: "Heavier system font.", isOn: $boldText)
                    ToggleRow(title: "Increase contrast", detail: "Darker colours and borders.", isOn: $increaseContrast)
                    ToggleRow(title: "Reduce transparency", detail: "Solid backgrounds instead of blur.", isOn: $reduceTransparency)
                    ToggleRow(title: "Classic invert", detail: "Inverted colours.", isOn: $invertColors)
                    ToggleRow(title: "Greyscale", detail: "Colour filter: greyscale.", isOn: $grayscale)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Accessibility", icon: "accessibility")
                Card {
                    ToggleRow(title: "VoiceOver", detail: "Spoken screen reader from the first start.", isOn: $voiceOver)
                    ToggleRow(title: "Zoom", detail: "Screen magnifier.", isOn: $zoom)
                    ToggleRow(title: "AssistiveTouch", detail: "Floating on-screen button for gestures and buttons.",
                              isOn: $assistiveTouch)
                    ToggleRow(title: "Reduce motion", detail: "Fewer animations; faster in the emulator too.",
                              isOn: $reduceMotion)
                }
            }

            Button(role: .destructive) {
                Pref.guestKeys.forEach { Pref.defaults.removeObject(forKey: $0) }
            } label: {
                Label("Reset emulated iOS settings", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GhostButtonStyle())
        }
    }
}
