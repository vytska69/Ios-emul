import SwiftUI
import os
import IPSWKit
import EmulatorKit

/// Loaded state for one firmware: the parsed IPSW plus its compatibility report.
@MainActor
final class FirmwareModel: ObservableObject {
    @Published var ipsw: IPSW?
    @Published var report: CompatibilityReport?
    @Published var coverage: [HardwareCoverage] = []
    /// The DeviceTree of the first build identity (hardware coverage, experimental browser).
    @Published var deviceTree: DeviceTreeNode?
    @Published var loadError: String?
    @Published var progress: (String, Double)?
    @Published var runner: QEMURunner?
    @Published var runError: String?
    /// QEMU's last output when the previous run ended the app (fatal QEMU error or crash).
    @Published var lastExit: String?
    @Published var suggestion: FirmwareCatalog.Suggestion?
    @Published var suggestionState: String?

    /// The row to boot: the best supported device, or (experimental) the first device forced onto
    /// the machine chosen in Settings → Experimental.
    var bootRow: CompatibilityReport.Row? {
        guard let report else { return nil }
        if let best = report.best { return best }
        guard let id = Pref.experimentalString(Pref.forceBackend),
              let backend = BackendRegistry.shared.backend(id: id),
              let device = report.rows.first?.device else { return nil }
        return CompatibilityReport.Row(device: device, backend: backend,
                                       compatibility: .experimental("forced onto \(backend.displayName)"))
    }

    private var scope: ScopedURL?
    /// Asset scopes stay open for the whole VM lifetime: QEMU opens the files lazily.
    private var assetScopes: [String: ScopedURL] = [:]

    func load(_ item: FirmwareItem) async {
        guard ipsw == nil else { return }
        guard let scope = ScopedURL(bookmark: item.bookmark) else {
            loadError = "The IPSW file moved or was deleted. Import it again."
            return
        }
        self.scope = scope
        do {
            let parsed = try await Task.detached { try IPSW(url: scope.url) }.value
            ipsw = parsed
            report = BackendRegistry.shared.report(for: parsed)
            if let backend = bootRow?.backend {
                lastExit = QEMURunner.unexpectedExit(in: item.workDirectory.appendingPathComponent(backend.id))
            }
            if let identity = parsed.manifest.identity(),
               let tree = try? await Task.detached(operation: { try parsed.deviceTree(identity: identity) }).value {
                deviceTree = tree
                coverage = await Task.detached { HardwareCoverage.analyze(tree) }.value
            }
        } catch {
            loadError = "\(error)"
        }
    }

    func boot(item: FirmwareItem, row: CompatibilityReport.Row, mode: BootMode, memoryMB: Int, cpus: Int) {
        guard let ipsw, let backend = row.backend else { return }
        runError = nil
        var cacheMB = Pref.defaults.integer(forKey: Pref.translationCacheMB)
        guard let identity = ipsw.manifest.identity(for: Self.boardConfig(for: row.device, in: ipsw)) else {
            runError = "\(IPSWError.noIdentity)"
            return
        }
        Pref.applyEngine()
        // Likewise without JIT: say so before the install rather than after it.
        if QEMURunner.needsJIT && !QEMURunner.jitAvailable {
            runError = "\(QEMURunner.RunnerError.jitUnavailable)"
            return
        }
        // iOS ends an app that goes over its memory limit without a message, so refuse up front
        // when the VM cannot fit (os_proc_available_memory is what is left before that limit).
        let guestMB = min(max(memoryMB, backend.memoryRangeMB.lowerBound), backend.memoryRangeMB.upperBound)
        var neededMB = QEMURunner.requiredMemoryMB(guestMB: guestMB, translationCacheMB: cacheMB)
        let availableMB = Int(os_proc_available_memory() / 1_048_576)
        // A smaller translation cache is slower (QEMU throws all translated code away each time
        // it fills) but better than not starting at all.
        while availableMB > 0 && availableMB < neededMB && cacheMB > 256 && QEMURunner.preparedJITMB == 0 {
            cacheMB = max(256, cacheMB / 2)
            neededMB = QEMURunner.requiredMemoryMB(guestMB: guestMB, translationCacheMB: cacheMB)
        }
        if availableMB > 0 && availableMB < neededMB {
            runError = "This VM needs about \(neededMB) MB (\(guestMB) MB guest RAM plus the emulator), "
                + "but iOS lets this app use only \(availableMB) MB more right now. "
                + (backend.memoryRangeMB.count == 1 ? "This machine's RAM size is fixed; close other apps and try again."
                    : "Lower the memory, or close other apps and try again.")
            return
        }
        assetScopes = item.assets.compactMapValues { ScopedURL(bookmark: $0) }
        // The install reports progress for every chunk it copies; a main-actor hop each time
        // swamped the UI, so pass on a few updates a second (and every step change).
        let throttle = ProgressThrottle()
        let ctx = PrepareContext(ipsw: ipsw, identity: identity, device: row.device,
                                 workDirectory: item.workDirectory.appendingPathComponent(backend.id),
                                 externalAssets: assetScopes.mapValues(\.url), bootMode: mode,
                                 memoryMB: memoryMB, cpuCount: cpus,
                                 verboseBoot: Pref.defaults.bool(forKey: Pref.verboseBoot),
                                 translationCacheMB: cacheMB,
                                 extraBootArgs: Pref.experimentalString(Pref.extraBootArgs) ?? "",
                                 firstBootErase: !Pref.experimentalBool(Pref.skipFirstBootErase),
                                 guestTweaks: Pref.guestTweaks) { [weak self] name, fraction in
            guard throttle.shouldReport(key: name, done: fraction <= 0 || fraction >= 1) else { return }
            Task { @MainActor in self?.progress = (name, fraction) }
        }
        Task {
            do {
                // Below the UI's priority, so scrolling and taps stay responsive during the install.
                var config = try await Task.detached(priority: .utility) { try backend.prepare(ctx) }.value
                if let extra = Pref.experimentalString(Pref.extraQEMUArgs) {
                    config.arguments += extra.split(separator: " ").map(String.init)
                }
                if let flags = Pref.experimentalString(Pref.qemuDebugFlags) {
                    config.arguments += ["-d", flags, "-D",
                                         config.workingDirectory.appendingPathComponent("qemu-debug.log").path]
                }
                let runner = QEMURunner(configuration: config)
                try runner.start()
                self.progress = nil
                self.runner = runner
            } catch {
                self.progress = nil
                self.runError = "\(error)"
            }
        }
    }

    func findSuggestion(version: String) async {
        suggestionState = "Searching firmware for iOS \(version)…"
        do {
            suggestion = try await FirmwareCatalog().suggestion(forVersion: version)
            suggestionState = suggestion == nil ? "No emulated device has iOS \(version) or another \(version.prefix { $0 != "." }).x build." : nil
        } catch {
            suggestionState = "Firmware lookup failed: \(error.localizedDescription)"
        }
    }

    /// Board configs are listed per identity; pick the one whose device tree names this product's board.
    static func boardConfig(for device: DeviceInfo, in ipsw: IPSW) -> String? {
        let classes = ipsw.manifest.deviceClasses
        if classes.count <= 1 || ipsw.devices.count <= 1 { return classes.first }
        // Product types and identities are listed in matching order in Apple's manifests.
        if let i = ipsw.devices.firstIndex(of: device), i < classes.count { return classes[i] }
        return classes.first
    }
}


struct FirmwareDetailView: View {
    let itemID: UUID
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.theme) private var theme
    @StateObject private var model = FirmwareModel()
    @State private var bootMode = BootMode(rawValue: Pref.defaults.string(forKey: Pref.bootMode) ?? "") ?? .direct
    @State private var memoryMB = 2048
    @State private var cpus = 2
    @State private var pickingAsset: ExternalAsset?

    var body: some View {
        Group {
            if let item = library.item(itemID) {
                content(item)
                    .task { await model.load(item) }
            } else {
                Text("Firmware removed").foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(AppBackground())
            }
        }
        .fullScreenCover(item: Binding(get: { model.runner.map(RunnerBox.init) }, set: { if $0 == nil { model.runner = nil } })) { box in
            MachineView(runner: box.runner)
                .environment(\.theme, theme)
        }
    }

    @ViewBuilder
    private func content(_ item: FirmwareItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero(item)

                if let error = model.loadError {
                    Card { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }

                if let report = model.report {
                    if let best = model.bootRow, let backend = best.backend {
                        bootCard(item: item, best: best, backend: backend)
                        if !backend.externalAssets.isEmpty { assetsCard(item: item, backend: backend) }
                    } else {
                        suggestionCard(item: item)
                    }
                    devicesCard(report)
                    if let best = model.coverage.first { CoverageCard(coverage: best) }
                    if Pref.experimentalBool(Pref.firmwareTools), let ipsw = model.ipsw {
                        FirmwareToolsCard(item: item, ipsw: ipsw, deviceTree: model.deviceTree,
                                          backendID: model.bootRow?.backend?.id)
                    }
                    componentsCard
                } else if model.loadError == nil {
                    Card {
                        HStack(spacing: 12) {
                            ProgressView().tint(theme.accent)
                            Text("Reading BuildManifest…").foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 32)
        }
        .screenStyle()
        .navigationTitle("iOS \(item.version)")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: Binding(get: { pickingAsset != nil }, set: { if !$0 { pickingAsset = nil } }),
                      allowedContentTypes: [.data, .folder]) { result in
            if case .success(let url) = result, let asset = pickingAsset {
                library.setAsset(asset.id, url: url, for: item)
            }
            pickingAsset = nil
        }
    }

    // MARK: Cards

    private func hero(_ item: FirmwareItem) -> some View {
        let best = model.bootRow
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    VersionBadge(version: item.version, size: 58)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("iOS \(item.version)")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text(item.build).font(.subheadline.monospaced()).foregroundStyle(.white.opacity(0.55))
                    }
                }
                HStack(spacing: 8) {
                    if let best { Chip(text: best.compatibility.label, color: best.compatibility.color) }
                    if let ipsw = model.ipsw {
                        Chip(text: ipsw.imageFormat, color: .white.opacity(0.8))
                        Chip(text: "\(ipsw.manifest.identities.count) identities", color: .white.opacity(0.8))
                    }
                }
                Text(item.fileName).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.gradient(opacity: 0.14), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(theme.gradient(opacity: 0.5)))
        }
        .padding(.top, 8)
    }

    private func bootCard(item: FirmwareItem, best: CompatibilityReport.Row, backend: EmulatorBackend) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Machine · \(backend.displayName)", icon: "cpu")
            Card {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach([BootMode.direct, .auto, .enterRecovery, .exitRecovery], id: \.self) { mode in
                        ModeTile(mode: mode, selected: bootMode == mode) { bootMode = mode }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    if backend.memoryRangeMB.count == 1 {
                        InfoRow(label: "Memory", value: "\(backend.memoryRangeMB.lowerBound) MB · fixed")
                    } else {
                        InfoRow(label: "Memory", value: "\(memoryMB) MB")
                        Slider(value: Binding(get: { Double(memoryMB) }, set: { memoryMB = Int($0) }),
                               in: Double(backend.memoryRangeMB.lowerBound)...Double(backend.memoryRangeMB.upperBound),
                               step: 512)
                            .tint(theme.accent)
                    }
                    Stepper(value: $cpus, in: 1...8) { InfoRow(label: "CPU cores", value: "\(cpus)") }
                }
                .padding(.top, 4)

                if let progress = model.progress {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(progress.0 == "OS" ? "Installing iOS…" : "Extracting \(progress.0)…")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(progress.1, format: .percent.precision(.fractionLength(0)))
                                .font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                        }
                        GlowBar(value: progress.1)
                    }
                    .padding(.top, 6)
                } else {
                    Button {
                        model.boot(item: item, row: best, mode: bootMode, memoryMB: memoryMB, cpus: cpus)
                    } label: {
                        Label("Boot \(best.device.name)", systemImage: "power")
                    }
                    .buttonStyle(GlowButtonStyle())
                    .padding(.top, 6)
                }

                if let error = model.runError {
                    Label(error, systemImage: "exclamationmark.octagon.fill")
                        .font(.footnote).foregroundStyle(.red)
                    if error == "\(QEMURunner.RunnerError.jitUnavailable)" { StikDebugButton() }
                }
                if let log = model.lastExit {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("The last run closed the app. QEMU's last output:", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                        ScrollView(.horizontal) {
                            Text(log.isEmpty ? "(nothing; the emulator crashed without a message)" : log)
                                .font(.caption2.monospaced()).foregroundStyle(.green.opacity(0.85))
                                .textSelection(.enabled)
                                .padding(10)
                        }
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
        .onAppear {
            let preferred = Pref.defaults.integer(forKey: Pref.memoryMB)
            memoryMB = preferred > 0
                ? min(max(preferred, backend.memoryRangeMB.lowerBound), backend.memoryRangeMB.upperBound)
                : backend.defaultMemoryMB
            cpus = min(max(Pref.defaults.integer(forKey: Pref.cpus), 1), 8)
        }
    }

    private func assetsCard(item: FirmwareItem, backend: EmulatorBackend) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Files not in the IPSW", icon: "doc.badge.plus")
            Card {
                ForEach(backend.externalAssets) { asset in
                    let provided = item.assets[asset.id] != nil
                    Button { pickingAsset = asset } label: {
                        HStack(spacing: 12) {
                            Image(systemName: provided ? "checkmark.circle.fill" : "plus.circle")
                                .font(.title3).foregroundStyle(provided ? Color.green : theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(asset.title).font(.subheadline.weight(.semibold))
                                Text(asset.help).font(.caption).foregroundStyle(.white.opacity(0.5))
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func suggestionCard(item: FirmwareItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Run iOS \(item.version) anyway", icon: "wand.and.stars")
            Card {
                Text("None of these devices has a machine model yet. The same iOS release can still run on an emulated device.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.65))
                if let s = model.suggestion {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(s.device.name) · iOS \(s.firmware.version)").font(.headline)
                        Text(s.firmware.buildid).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.5))
                        HStack(spacing: 8) {
                            Chip(text: s.compatibility.label, color: s.compatibility.color)
                            if let size = s.firmware.filesize {
                                Chip(text: ByteCountFormatter.string(fromByteCount: size, countStyle: .file), color: .white.opacity(0.8))
                            }
                        }
                    }
                    if let dl = downloads.items.first(where: { $0.url == s.firmware.url }) {
                        DownloadProgressRow(item: dl)
                    } else {
                        Button {
                            downloads.start(s.firmware, title: "\(s.device.name) — iOS \(s.firmware.version) (\(s.firmware.buildid))")
                        } label: { Label("Download and import", systemImage: "arrow.down.circle.fill") }
                            .buttonStyle(GlowButtonStyle())
                    }
                } else {
                    Button {
                        Task { await model.findSuggestion(version: item.version) }
                    } label: { Label("Find bootable firmware for iOS \(item.version)", systemImage: "magnifyingglass") }
                        .buttonStyle(GhostButtonStyle())
                }
                if let state = model.suggestionState {
                    Text(state).font(.caption).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    private func devicesCard(_ report: CompatibilityReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Devices in this IPSW", icon: "iphone")
            Card {
                ForEach(Array(report.rows.enumerated()), id: \.element.device.productType) { index, row in
                    if index > 0 { Divider().overlay(.white.opacity(0.08)) }
                    DeviceRow(row: row)
                }
            }
        }
    }

    @ViewBuilder
    private var componentsCard: some View {
        if let ipsw = model.ipsw, let identity = ipsw.manifest.identity() {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Components · \(identity.deviceClass)", icon: "shippingbox")
                Card {
                    DisclosureGroup("\(identity.components.count) firmware components") {
                        VStack(spacing: 6) {
                            ForEach(identity.components.keys.sorted(), id: \.self) { key in
                                InfoRow(label: key, value: (identity.components[key]!.path as NSString).lastPathComponent, mono: true)
                                    .font(.caption)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .tint(theme.accent)
                }
            }
        }
    }
}

/// One selectable boot mode.
private struct ModeTile: View {
    @Environment(\.theme) private var theme
    let mode: BootMode
    let selected: Bool
    let action: () -> Void

    private var symbol: String {
        switch mode {
        case .direct: return "bolt.fill"
        case .auto: return "arrow.triangle.2.circlepath"
        case .enterRecovery: return "lifepreserver"
        case .exitRecovery: return "internaldrive"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol).font(.headline)
                    .foregroundStyle(selected ? Color.black.opacity(0.8) : theme.accent)
                Text(mode.title).font(.caption.weight(.bold)).lineLimit(2)
                    .foregroundStyle(selected ? Color.black.opacity(0.85) : Color.white)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.gradient)
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.05))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(selected ? 0 : 0.08)))
        }
        .buttonStyle(.plain)
    }
}

private struct DeviceRow: View {
    let row: CompatibilityReport.Row

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: deviceSymbol(for: row.device.productType))
                .font(.title3).foregroundStyle(row.compatibility.color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(row.device.name).font(.subheadline.weight(.semibold))
                    Spacer()
                    Chip(text: row.compatibility.label, color: row.compatibility.color)
                }
                Text([row.device.productType, row.device.soc.map { "\($0.marketingName) · \($0.id)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
                switch row.compatibility {
                case .supported: EmptyView()
                case .experimental(let why), .unsupported(let why):
                    Text(why).font(.caption2).foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }
}

/// What fraction of this firmware's DeviceTree hardware the closest machine model emulates.
private struct CoverageCard: View {
    @Environment(\.theme) private var theme
    let coverage: HardwareCoverage
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Hardware coverage", icon: "square.stack.3d.up")
            Card {
                HStack(spacing: 16) {
                    RingGauge(value: coverage.fraction)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Closest model \(coverage.machine.uppercased())").font(.subheadline.weight(.semibold))
                        Text("\(coverage.emulatedCount) of \(coverage.peripherals.count) DeviceTree peripherals are emulated")
                            .font(.caption).foregroundStyle(.white.opacity(0.55))
                    }
                }
                if !coverage.missingBootCritical.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Missing boot-critical hardware").font(.caption.weight(.bold)).foregroundStyle(.red)
                        FlowChips(items: coverage.missingBootCritical.map(\.name), color: .red)
                    }
                }
                DisclosureGroup("All missing peripherals", isExpanded: $showAll) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(coverage.peripherals.filter { !$0.emulated }, id: \.path) { p in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.path).font(.caption.monospaced())
                                if !p.compatible.isEmpty {
                                    Text(p.compatible.joined(separator: ", ")).font(.caption2).foregroundStyle(.white.opacity(0.45))
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .tint(theme.accent)
            }
        }
    }
}

/// Chips that wrap onto several lines.
private struct FlowChips: View {
    let items: [String]
    let color: Color

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { Chip(text: $0, color: color) }
        }
    }
}

/// `fullScreenCover(item:)` needs an Identifiable value.
struct RunnerBox: Identifiable {
    let runner: QEMURunner
    var id: ObjectIdentifier { ObjectIdentifier(runner) }
}
