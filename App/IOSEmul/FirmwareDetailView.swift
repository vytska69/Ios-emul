import SwiftUI
import IPSWKit
import EmulatorKit

/// Loaded state for one firmware: the parsed IPSW plus its compatibility report.
@MainActor
final class FirmwareModel: ObservableObject {
    @Published var ipsw: IPSW?
    @Published var report: CompatibilityReport?
    @Published var coverage: [HardwareCoverage] = []
    @Published var loadError: String?
    @Published var progress: (String, Double)?
    @Published var runner: QEMURunner?
    @Published var runError: String?
    /// QEMU's last output when the previous run ended the app (fatal QEMU error or crash).
    @Published var lastExit: String?
    @Published var suggestion: FirmwareCatalog.Suggestion?
    @Published var suggestionState: String?

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
            if let backend = report?.best?.backend {
                lastExit = QEMURunner.unexpectedExit(in: item.workDirectory.appendingPathComponent(backend.id))
            }
            if let identity = parsed.manifest.identity() {
                coverage = (try? await Task.detached {
                    HardwareCoverage.analyze(try parsed.deviceTree(identity: identity))
                }.value) ?? []
            }
        } catch {
            loadError = "\(error)"
        }
    }

    func boot(item: FirmwareItem, row: CompatibilityReport.Row, mode: BootMode, memoryMB: Int, cpus: Int) {
        guard let ipsw, let backend = row.backend else { return }
        guard let identity = ipsw.manifest.identity(for: Self.boardConfig(for: row.device, in: ipsw)) else {
            runError = "\(IPSWError.noIdentity)"
            return
        }
        assetScopes = item.assets.compactMapValues { ScopedURL(bookmark: $0) }
        let ctx = PrepareContext(ipsw: ipsw, identity: identity, device: row.device,
                                 workDirectory: item.workDirectory.appendingPathComponent(backend.id),
                                 externalAssets: assetScopes.mapValues(\.url), bootMode: mode,
                                 memoryMB: memoryMB, cpuCount: cpus) { [weak self] name, fraction in
            Task { @MainActor in self?.progress = (name, fraction) }
        }
        Task {
            do {
                let config = try await Task.detached { try backend.prepare(ctx) }.value
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
    @StateObject private var model = FirmwareModel()
    @State private var bootMode: BootMode = .direct
    @State private var memoryMB = 2048
    @State private var cpus = 2
    @State private var pickingAsset: ExternalAsset?

    var body: some View {
        Group {
            if let item = library.item(itemID) {
                content(item)
                    .task { await model.load(item) }
            } else {
                Text("Firmware removed")
            }
        }
        .fullScreenCover(item: Binding(get: { model.runner.map(RunnerBox.init) }, set: { if $0 == nil { model.runner = nil } })) { box in
            MachineView(runner: box.runner)
        }
    }

    @ViewBuilder
    private func content(_ item: FirmwareItem) -> some View {
        List {
            Section("Firmware") {
                LabeledContent("Version", value: item.version)
                LabeledContent("Build", value: item.build)
                if let ipsw = model.ipsw {
                    LabeledContent("Image format", value: ipsw.imageFormat)
                    LabeledContent("Build identities", value: "\(ipsw.manifest.identities.count)")
                }
            }

            if let error = model.loadError {
                Section { Text(error).foregroundStyle(.red) }
            }

            if let report = model.report {
                Section("Devices") {
                    ForEach(report.rows, id: \.device.productType) { row in
                        DeviceRow(row: row)
                    }
                }

                if report.best == nil {
                    Section {
                        Text("None of these devices has a machine model yet. The same iOS release can still run on an emulated device.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let s = model.suggestion {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(s.device.name) — iOS \(s.firmware.version) (\(s.firmware.buildid))").bold()
                                Text(s.compatibility.summary).font(.caption).foregroundStyle(.secondary)
                                if let size = s.firmware.filesize {
                                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption)
                                }
                            }
                            if let item = downloads.items.first(where: { $0.url == s.firmware.url }) {
                                DownloadProgressRow(item: item)
                            } else {
                                Button("Download and import") {
                                    downloads.start(s.firmware, title: "\(s.device.name) — iOS \(s.firmware.version) (\(s.firmware.buildid))")
                                }
                            }
                        } else {
                            Button("Find bootable firmware for iOS \(item.version)") {
                                Task { await model.findSuggestion(version: item.version) }
                            }
                        }
                        if let state = model.suggestionState {
                            Text(state).font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Run iOS \(item.version) anyway")
                    }
                }

                if let best = report.best, let backend = best.backend {
                    Section("Machine — \(backend.displayName)") {
                        Picker("Boot", selection: $bootMode) {
                            Text("Install directly (no computer)").tag(BootMode.direct)
                            Text("Restore via ramdisk").tag(BootMode.auto)
                            Text("Force restore ramdisk").tag(BootMode.enterRecovery)
                            Text("Force installed OS").tag(BootMode.exitRecovery)
                        }
                        Stepper("Memory: \(memoryMB) MB", value: $memoryMB, in: 512...8192, step: 512)
                        Stepper("CPUs: \(cpus)", value: $cpus, in: 1...8)
                        Link("Machine model source", destination: URL(string: backend.upstream)!)
                    }
                    .onAppear {
                        memoryMB = backend.defaultMemoryMB
                        cpus = backend.defaultCPUCount
                    }

                    Section {
                        ForEach(backend.externalAssets) { asset in
                            Button { pickingAsset = asset } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(asset.title)
                                        Text(asset.help).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: item.assets[asset.id] == nil ? "circle" : "checkmark.circle.fill")
                                        .foregroundStyle(item.assets[asset.id] == nil ? Color.secondary : Color.green)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Files not included in the IPSW")
                    }

                    Section {
                        if let progress = model.progress {
                            ProgressView("Extracting \(progress.0)…", value: progress.1)
                        } else {
                            Button {
                                model.boot(item: item, row: best, mode: bootMode, memoryMB: memoryMB, cpus: cpus)
                            } label: {
                                Label("Boot \(best.device.name)", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        if let error = model.runError {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                        if let log = model.lastExit {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("The last run closed the app. QEMU's last output:")
                                    .font(.footnote).foregroundStyle(.red)
                                Text(log.isEmpty ? "(nothing; the emulator crashed without a message)" : log)
                                    .font(.caption2.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }

                if let best = model.coverage.first {
                    CoverageSection(coverage: best)
                }

                if let ipsw = model.ipsw, let identity = ipsw.manifest.identity() {
                    Section("Components (\(identity.deviceClass))") {
                        ForEach(identity.components.keys.sorted(), id: \.self) { key in
                            LabeledContent(key, value: (identity.components[key]!.path as NSString).lastPathComponent)
                                .font(.caption)
                        }
                    }
                }
            } else if model.loadError == nil {
                Section { ProgressView("Reading BuildManifest…") }
            }
        }
        .navigationTitle("iOS \(item.version)")
        .fileImporter(isPresented: Binding(get: { pickingAsset != nil }, set: { if !$0 { pickingAsset = nil } }),
                      allowedContentTypes: [.data, .folder]) { result in
            if case .success(let url) = result, let asset = pickingAsset {
                library.setAsset(asset.id, url: url, for: item)
            }
            pickingAsset = nil
        }
    }
}

private struct DeviceRow: View {
    let row: CompatibilityReport.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.device.name).font(.headline)
                Spacer()
                badge
            }
            Text([row.device.productType, row.device.soc.map { "\($0.marketingName) · \($0.id)" }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            switch row.compatibility {
            case .supported: EmptyView()
            case .experimental(let why), .unsupported(let why):
                Text(why).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var badge: some View {
        let (text, color): (String, Color) = {
            switch row.compatibility {
            case .supported: return ("Supported", .green)
            case .experimental: return ("Experimental", .orange)
            case .unsupported: return ("Unsupported", .red)
            }
        }()
        return Text(text).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }
}

/// What fraction of this firmware's DeviceTree hardware the closest machine model emulates.
private struct CoverageSection: View {
    let coverage: HardwareCoverage

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Closest model: \(coverage.machine.uppercased())")
                    Spacer()
                    Text(coverage.fraction, format: .percent.precision(.fractionLength(0))).bold()
                }
                ProgressView(value: coverage.fraction)
                Text("\(coverage.emulatedCount) of \(coverage.peripherals.count) DeviceTree peripherals are emulated")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !coverage.missingBootCritical.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Missing boot-critical hardware").font(.subheadline.bold())
                    Text(coverage.missingBootCritical.map(\.name).joined(separator: ", "))
                        .font(.caption.monospaced()).foregroundStyle(.red)
                }
            }
            DisclosureGroup("All missing peripherals") {
                ForEach(coverage.peripherals.filter { !$0.emulated }, id: \.path) { p in
                    VStack(alignment: .leading) {
                        Text(p.path).font(.caption.monospaced())
                        if !p.compatible.isEmpty {
                            Text(p.compatible.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Hardware coverage")
        }
    }
}

/// `fullScreenCover(item:)` needs an Identifiable value.
struct RunnerBox: Identifiable {
    let runner: QEMURunner
    var id: ObjectIdentifier { ObjectIdentifier(runner) }
}
