import SwiftUI
import EmulatorKit

/// UserDefaults keys for everything on the Settings tab.
enum Pref {
    static let theme = "theme"
    static let bootMode = "defaultBootMode"
    static let cpus = "defaultCPUs"
    /// 0: the machine's own default.
    static let memoryMB = "defaultMemoryMB"
    static let translationCacheMB = "translationCacheMB"
    static let verboseBoot = "verboseBoot"
    static let verifyDownloads = "verifyDownloads"
    static let cellularDownloads = "cellularDownloads"
    static let keepAwake = "keepScreenAwake"

    static func register() {
        UserDefaults.standard.register(defaults: [
            theme: AppTheme.aurora.rawValue,
            bootMode: BootMode.direct.rawValue,
            cpus: 2,
            memoryMB: 0,
            translationCacheMB: QEMURunner.defaultTranslationCacheMB,
            verboseBoot: true,
            verifyDownloads: true,
            cellularDownloads: false,
            keepAwake: true,
        ])
    }

    static var defaults: UserDefaults { .standard }
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

struct SettingsView: View {
    @Environment(\.theme) private var theme
    @AppStorage(Pref.theme) private var themeName = AppTheme.aurora.rawValue
    @AppStorage(Pref.bootMode) private var bootMode = BootMode.direct.rawValue
    @AppStorage(Pref.cpus) private var cpus = 2
    @AppStorage(Pref.memoryMB) private var memoryMB = 0
    @AppStorage(Pref.translationCacheMB) private var cacheMB = QEMURunner.defaultTranslationCacheMB
    @AppStorage(Pref.verboseBoot) private var verboseBoot = true
    @AppStorage(Pref.verifyDownloads) private var verifyDownloads = true
    @AppStorage(Pref.cellularDownloads) private var cellular = false
    @AppStorage(Pref.keepAwake) private var keepAwake = true

    @State private var machineBytes: Int64?
    @State private var firmwareBytes: Int64?
    @State private var confirmWipe = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    appearance
                    machineDefaults
                    emulator
                    downloads
                    storage
                    about
                }
                .padding(.horizontal, 16).padding(.bottom, 32)
            }
            .screenStyle()
            .navigationBarTitleDisplayMode(.inline)
            .task { await measureStorage() }
            .confirmationDialog("Delete every virtual disk?", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Delete machine disks", role: .destructive) {
                    try? FileManager.default.removeItem(at: Library.machinesDirectory)
                    Task { await measureStorage() }
                }
            } message: {
                Text("Installed systems are removed; the next boot installs from the IPSW again. Imported IPSWs stay.")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            GlyphTile(symbol: "slider.horizontal.3", size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings").font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text("Defaults for new boots, the emulator core and downloads")
                    .font(.footnote).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.top, 8)
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Appearance", icon: "paintpalette")
            Card {
                HStack(spacing: 12) {
                    ForEach(AppTheme.allCases) { option in
                        Button { themeName = option.rawValue } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(option.gradient)
                                    .frame(height: 54)
                                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(.white, lineWidth: themeName == option.rawValue ? 2.5 : 0))
                                Text(option.title).font(.caption.weight(.semibold))
                                    .foregroundStyle(themeName == option.rawValue ? .white : .white.opacity(0.5))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var machineDefaults: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "New boots", icon: "power")
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Boot mode").font(.subheadline.weight(.semibold))
                    Picker("Boot mode", selection: $bootMode) {
                        ForEach([BootMode.direct, .auto, .enterRecovery, .exitRecovery], id: \.self) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(theme.accent)
                    Text((BootMode(rawValue: bootMode) ?? .direct).subtitle)
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                }
                Divider().overlay(.white.opacity(0.08))
                Stepper(value: $cpus, in: 1...8) {
                    InfoRow(label: "CPU cores", value: "\(cpus)")
                }
                Divider().overlay(.white.opacity(0.08))
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(label: "Memory", value: memoryMB == 0 ? "Machine default" : "\(memoryMB) MB")
                    Slider(value: Binding(get: { Double(memoryMB) }, set: { memoryMB = Int($0) }),
                           in: 0...8192, step: 512)
                        .tint(theme.accent)
                    Text("Machines with a fixed RAM size (iPhone 6s: 2 GB) ignore this.")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    private var emulator: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Emulator", icon: "cpu")
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("JIT").font(.subheadline.weight(.semibold))
                        Text(jitDetail).font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    Chip(text: jitState.0, color: jitState.1, icon: jitState.2)
                }
                Divider().overlay(.white.opacity(0.08))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Translation cache").font(.subheadline.weight(.semibold))
                    Picker("Translation cache", selection: $cacheMB) {
                        ForEach([128, 256, 512, 1024], id: \.self) { Text("\($0) MB").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("Larger is faster for big guests but counts against the memory iOS allows the app.")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                }
                Divider().overlay(.white.opacity(0.08))
                Toggle(isOn: $verboseBoot) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Verbose boot").font(.subheadline.weight(.semibold))
                        Text("Kernel text on screen instead of the Apple logo.")
                            .font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .tint(theme.accent)
                Toggle(isOn: $keepAwake) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep screen awake").font(.subheadline.weight(.semibold))
                        Text("While a machine is running.").font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .tint(theme.accent)
            }
        }
    }

    private var downloads: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Downloads", icon: "arrow.down.circle")
            Card {
                Toggle(isOn: $verifyDownloads) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Verify SHA-1").font(.subheadline.weight(.semibold))
                        Text("Check each IPSW against ipsw.me before importing it.")
                            .font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .tint(theme.accent)
                Toggle(isOn: $cellular) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use mobile data").font(.subheadline.weight(.semibold))
                        Text("IPSWs are several GB. Applies to downloads started afterwards.")
                            .font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .tint(theme.accent)
            }
        }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Storage", icon: "internaldrive")
            Card {
                InfoRow(label: "Virtual disks", value: machineBytes.map(format) ?? "…")
                InfoRow(label: "Downloaded IPSWs", value: firmwareBytes.map(format) ?? "…")
                InfoRow(label: "Free on device", value: DownloadManager.freeSpace().map(format) ?? "–")
                Button { confirmWipe = true } label: {
                    Label("Delete machine disks", systemImage: "trash")
                }
                .buttonStyle(GhostButtonStyle())
                .padding(.top, 4)
                Text("Downloaded IPSWs are in Files → On My iPhone → iOS Emul → Firmware.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "About", icon: "info.circle")
            Card {
                InfoRow(label: "Version", value: appVersion)
                Link(destination: URL(string: "https://github.com/vytska69/Ios-emul")!) {
                    HStack { Text("Source code"); Spacer(); Image(systemName: "arrow.up.right") }
                }
                Link(destination: URL(string: "https://github.com/ChefKissInc/QEMUAppleSilicon")!) {
                    HStack { Text("Apple machine models (QEMUAppleSilicon)"); Spacer(); Image(systemName: "arrow.up.right") }
                }
                Link(destination: URL(string: "https://ipsw.me")!) {
                    HStack { Text("Firmware list (ipsw.me)"); Spacer(); Image(systemName: "arrow.up.right") }
                }
                Text("Use only software you are licensed to run. Not affiliated with Apple or ChefKiss.")
                    .font(.caption).foregroundStyle(.white.opacity(0.45))
            }
            .tint(theme.accent)
        }
    }

    private var jitState: (String, Color, String) {
        if !QEMURunner.needsJIT { return ("Not needed", .green, "checkmark.circle") }
        return QEMURunner.jitAvailable ? ("Enabled", .green, "bolt.fill") : ("Off", .orange, "bolt.slash")
    }

    private var jitDetail: String {
        if !QEMURunner.needsJIT { return "This build interprets guest code (TCI)." }
        return QEMURunner.jitAvailable
            ? "Generated code can run; machines boot at full speed."
            : "Open the app through StikDebug or TrollStore's Open with JIT before booting."
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private func measureStorage() async {
        let (machines, firmware) = await Task.detached(priority: .utility) {
            (Self.size(of: Library.machinesDirectory), Self.size(of: DownloadManager.directory))
        }.value
        machineBytes = machines
        firmwareBytes = firmware
    }

    /// Allocated size of everything under a folder (virtual disks are sparse).
    nonisolated private static func size(of folder: URL) -> Int64 {
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
