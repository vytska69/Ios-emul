import SwiftUI
import AppKit
import UniformTypeIdentifiers
import IPSWKit
import EmulatorKit

/// The Mac version: the same installer and machine as the iPhone app (EmulatorKit), with QEMU
/// running as a helper process bundled in the app (Contents/MacOS/qemu-system-aarch64).
@main
struct IOSEmulMacApp: App {
    @StateObject private var library = MacLibrary()

    var body: some Scene {
        WindowGroup("iOS Emul") {
            LibraryView().environmentObject(library)
                .frame(minWidth: 760, minHeight: 520)
        }
        WindowGroup("Machine", for: UUID.self) { $id in
            if let id, let machine = library.machines[id] {
                MacMachineView(machine: machine)
            } else {
                Text("This machine has stopped.").frame(width: 320, height: 200)
            }
        }
        .windowResizability(.contentSize)
        Settings { MacSettingsView() }
    }
}

enum MacPref {
    static let defaults = UserDefaults.standard
    static let ipsws = "ipswPaths"
    static let memoryMB = "memoryMB"
    static let cpus = "cpus"
    static let removableApps = "installRemovableApps"
    static let skipSetup = "guestSkipSetup"
    static let accelerator = "accelerator"
    static let cacheMB = "translationCacheMB"

    static func register() {
        defaults.register(defaults: [memoryMB: 4096, cpus: 4, removableApps: true, skipSetup: true,
                                     accelerator: Accelerator.tcg.rawValue, cacheMB: 1024])
    }

    /// Where machines live: ~/Library/Application Support/IOSEmul/Machines.
    static var machinesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("IOSEmul/Machines", isDirectory: true)
    }
}

/// How the guest's code runs: translated (TCG, works everywhere) or directly on the Mac's CPU
/// through Hypervisor.framework (experimental: the emulated iPhone's CPU is not yet supported).
enum Accelerator: String, CaseIterable, Identifiable {
    case tcg, hvf
    var id: String { rawValue }
    var title: String { self == .tcg ? "Translation (TCG)" : "Hypervisor (experimental)" }
}

/// One imported IPSW and what can boot it.
struct MacFirmware: Identifiable {
    let id: String          // the file path
    let url: URL
    var ipsw: IPSW?
    var report: CompatibilityReport?
    var error: String?
    var name: String { ipsw.map { "iOS \($0.version) (\($0.build))" } ?? url.lastPathComponent }
}

/// A running machine shown in its own window.
@MainActor
final class MacMachine: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    let runner: QEMURunner
    @Published var frame: CGImage?
    @Published var status = "Starting QEMU…"
    @Published var state: QEMURunner.State = .running
    private var vnc: VNCClient?
    private var connected = false

    init(title: String, runner: QEMURunner) {
        self.title = title
        self.runner = runner
        runner.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.state = state
                if case .stopped(let code) = state {
                    self?.status = "Machine stopped (exit \(code))"
                    self?.readLogTail()
                }
            }
        }
        connect()
    }

    /// The end of QEMU's output and the guest's serial log, shown when the machine stops.
    @Published var logTail = ""
    func readLogTail() {
        let dir = runner.configuration.workingDirectory
        func tail(_ name: String) -> String {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return "" }
            return String(decoding: data.suffix(4000), as: UTF8.self)
        }
        logTail = "qemu.log:\n" + tail("qemu.log") + "\n\nserial.log:\n" + tail("serial.log")
    }

    private func connect() {
        guard case .running = state else { return }
        let client = VNCClient(port: runner.configuration.vncPort)
        client.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .connected:
                    self.connected = true
                    self.status = "Waiting for iOS…"
                case .frame(let image):
                    self.frame = image
                case .disconnected:
                    self.connected = false
                    self.vnc = nil
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self.connect()
                }
            }
        }
        vnc = client
        client.connect()
    }

    func touch(_ point: CGPoint, in size: CGSize, pressed: Bool) {
        guard let frame, size.width > 0, size.height > 0 else { return }
        vnc?.pointer(x: Int(point.x / size.width * CGFloat(frame.width)),
                     y: Int(point.y / size.height * CGFloat(frame.height)), pressed: pressed)
    }

    /// Inferno's buttons device: F3/F4 volume, F5 side, F6 home.
    func press(_ keysym: UInt32) { vnc?.key(keysym) }

    /// A swipe up from the bottom edge (Face ID iPhone).
    func goHome() {
        guard let vnc, let frame else { return }
        let x = frame.width / 2, bottom = frame.height - 4, travel = frame.height * 45 / 100, steps = 20
        vnc.pointer(x: x, y: bottom, pressed: true)
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(i)) {
                vnc.pointer(x: x, y: bottom - i * travel / steps, pressed: i < steps)
            }
        }
    }

    func stop() {
        vnc?.disconnect()
        runner.stop()
    }
}

@MainActor
final class MacLibrary: ObservableObject {
    @Published var firmwares: [MacFirmware] = []
    @Published var machines: [UUID: MacMachine] = [:]
    @Published var progress: (String, Double)?
    @Published var bootError: String?

    init() {
        MacPref.register()
        for path in MacPref.defaults.stringArray(forKey: MacPref.ipsws) ?? [] { load(URL(fileURLWithPath: path)) }
    }

    func add(_ url: URL) {
        guard !firmwares.contains(where: { $0.id == url.path }) else { return }
        var paths = MacPref.defaults.stringArray(forKey: MacPref.ipsws) ?? []
        paths.append(url.path)
        MacPref.defaults.set(paths, forKey: MacPref.ipsws)
        load(url)
    }

    func remove(_ firmware: MacFirmware) {
        firmwares.removeAll { $0.id == firmware.id }
        MacPref.defaults.set(firmwares.map(\.id), forKey: MacPref.ipsws)
    }

    private func load(_ url: URL) {
        let entry = MacFirmware(id: url.path, url: url)
        firmwares.append(entry)
        Task {
            let result = await Task.detached { () -> Result<IPSW, Error> in Result { try IPSW(url: url) } }.value
            guard let i = firmwares.firstIndex(where: { $0.id == url.path }) else { return }
            switch result {
            case .success(let ipsw):
                firmwares[i].ipsw = ipsw
                firmwares[i].report = BackendRegistry.shared.report(for: ipsw)
            case .failure(let error):
                firmwares[i].error = "\(error)"
            }
        }
    }

    /// The machine's folder for this IPSW and backend.
    /// A Hypervisor.framework machine has its own disk: its install leaves out the shared-cache
    /// patches that only TCG runs.
    func workDirectory(_ firmware: MacFirmware, backend: EmulatorBackend) -> URL {
        let name = (firmware.ipsw.map { "\($0.devices.first?.productType ?? "device")-\($0.build)" } ?? firmware.url.lastPathComponent)
        let hvf = MacPref.defaults.string(forKey: MacPref.accelerator) == Accelerator.hvf.rawValue
        return MacPref.machinesDirectory.appendingPathComponent(name).appendingPathComponent(backend.id + (hvf ? "-hvf" : ""))
    }

    func wipe(_ firmware: MacFirmware) {
        guard let backend = firmware.report?.best?.backend else { return }
        try? FileManager.default.removeItem(at: workDirectory(firmware, backend: backend))
    }

    /// Installs (first time) and boots; returns the new machine's id for its window.
    func boot(_ firmware: MacFirmware, open: @escaping (UUID) -> Void) {
        guard let ipsw = firmware.ipsw, let row = firmware.report?.best, let backend = row.backend,
              let identity = ipsw.identity(forProduct: row.device.productType) else { return }
        bootError = nil
        let d = MacPref.defaults
        var tweaks = GuestTweaks()
        tweaks.skipSetupAssistant = d.bool(forKey: MacPref.skipSetup)
        let accelerator = Accelerator(rawValue: d.string(forKey: MacPref.accelerator) ?? "") ?? .tcg
        let cacheMB = d.integer(forKey: MacPref.cacheMB)
        let ctx = PrepareContext(ipsw: ipsw, identity: identity, device: row.device,
                                 workDirectory: workDirectory(firmware, backend: backend), externalAssets: [:],
                                 bootMode: .direct, memoryMB: d.integer(forKey: MacPref.memoryMB),
                                 cpuCount: d.integer(forKey: MacPref.cpus), translationCacheMB: cacheMB,
                                 guestTweaks: tweaks, removableApps: d.bool(forKey: MacPref.removableApps),
                                 hypercalls: accelerator == .tcg) { [weak self] name, fraction in
            Task { @MainActor in self?.progress = (name, fraction) }
        }
        progress = ("OS", 0)
        Task {
            do {
                var config = try await Task.detached(priority: .userInitiated) { try backend.prepare(ctx) }.value
                config.arguments += Self.acceleratorArguments(accelerator, cacheMB: cacheMB)
                // QEMU's data files (keymaps, firmware) are in the app's Resources/qemu.
                if let data = Bundle.main.resourceURL?.appendingPathComponent("qemu"),
                   FileManager.default.fileExists(atPath: data.path) {
                    config.arguments += ["-L", data.path]
                }
                let runner = QEMURunner(configuration: config)
                try runner.start()
                let machine = MacMachine(title: "\(row.device.name) · iOS \(ipsw.version)", runner: runner)
                machines[machine.id] = machine
                progress = nil
                open(machine.id)
            } catch {
                progress = nil
                bootError = "\(error)"
            }
        }
    }

    static func acceleratorArguments(_ accelerator: Accelerator, cacheMB: Int) -> [String] {
        switch accelerator {
        case .tcg: return ["-accel", "tcg,thread=multi,tb-size=\(max(256, cacheMB))"]
        case .hvf: return ["-accel", "hvf"]
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: MacLibrary
    @Environment(\.openWindow) private var openWindow
    @State private var selection: String?
    @State private var importing = false

    var body: some View {
        NavigationSplitView {
            List(library.firmwares, selection: $selection) { fw in
                VStack(alignment: .leading, spacing: 2) {
                    Text(fw.name).font(.headline)
                    Text(fw.url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
                .tag(fw.id)
                .contextMenu { Button("Remove from list") { library.remove(fw) } }
            }
            .toolbar {
                Button { importing = true } label: { Label("Add IPSW", systemImage: "plus") }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let id = selection, let fw = library.firmwares.first(where: { $0.id == id }) {
                FirmwareDetail(firmware: fw) { library.boot(fw) { openWindow(value: $0) } }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "iphone.gen3").font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("Add an iPhone 11 iOS 14 IPSW to start.").foregroundStyle(.secondary)
                    Button("Add IPSW…") { importing = true }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "ipsw") ?? .data, .zip]) { result in
            if case .success(let url) = result {
                library.add(url)
                selection = url.path
            }
        }
    }
}

struct FirmwareDetail: View {
    @EnvironmentObject private var library: MacLibrary
    let firmware: MacFirmware
    let boot: () -> Void
    @AppStorage(MacPref.memoryMB) private var memoryMB = 4096
    @AppStorage(MacPref.cpus) private var cpus = 4
    @AppStorage(MacPref.removableApps) private var removableApps = true
    @AppStorage(MacPref.skipSetup) private var skipSetup = true
    @AppStorage(MacPref.accelerator) private var accelerator = Accelerator.tcg.rawValue
    @State private var confirmWipe = false

    var body: some View {
        Form {
            if let error = firmware.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if let ipsw = firmware.ipsw, let report = firmware.report {
                Section("Firmware") {
                    LabeledContent("iOS", value: "\(ipsw.version) (\(ipsw.build))")
                    LabeledContent("Devices", value: ipsw.devices.map(\.name).joined(separator: ", "))
                    if let best = report.best {
                        LabeledContent("Machine", value: "\(best.device.name) · \(best.backend?.displayName ?? "")")
                    } else {
                        Text("No emulated machine boots this firmware yet.").foregroundStyle(.secondary)
                    }
                }
                if let best = report.best, let backend = best.backend {
                    Section("Machine") {
                        if backend.memoryRangeMB.count > 1 {
                            Picker("Memory", selection: $memoryMB) {
                                ForEach([2048, 3072, 4096, 6144, 8192].filter { backend.memoryRangeMB.contains($0) }, id: \.self) {
                                    Text("\($0 / 1024) GB").tag($0)
                                }
                            }
                        }
                        Stepper("CPU cores: \(cpus)", value: $cpus, in: 1...8)
                        Picker("Engine", selection: $accelerator) {
                            ForEach(Accelerator.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                    }
                    Section("When iOS is installed") {
                        Toggle("Include removable apps (Music, Calendar, Weather, …)", isOn: $removableApps)
                        Toggle("Skip the setup assistant", isOn: $skipSetup)
                        Text("Applies to a new machine. Wipe the machine to install again with other settings.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        if let progress = library.progress {
                            ProgressView(progress.0 == "OS" ? "Installing iOS…" : "Extracting \(progress.0)…", value: progress.1)
                        } else {
                            HStack {
                                Button("Boot \(best.device.name)", action: boot).keyboardShortcut(.defaultAction)
                                Button("Wipe machine…", role: .destructive) { confirmWipe = true }
                            }
                        }
                        if let error = library.bootError {
                            Label(error, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
                        }
                        Text(library.workDirectory(firmware, backend: backend).path)
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            } else {
                ProgressView("Reading the IPSW…")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete this machine's disk?", isPresented: $confirmWipe) {
            Button("Wipe", role: .destructive) { library.wipe(firmware) }
        } message: { Text("The installed iOS and everything in it are deleted. The next boot installs iOS again.") }
    }
}

struct MacMachineView: View {
    @ObservedObject var machine: MacMachine
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let frame = machine.frame {
                    let aspect = CGFloat(frame.width) / CGFloat(max(frame.height, 1))
                    GeometryReader { geo in
                        Image(decorative: frame, scale: 1).resizable().interpolation(.medium)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { v in pressed = true; machine.touch(v.location, in: geo.size, pressed: true) }
                                .onEnded { v in pressed = false; machine.touch(v.location, in: geo.size, pressed: false) })
                    }
                    .aspectRatio(aspect, contentMode: .fit)
                } else {
                    VStack(spacing: 12) {
                        if case .running = machine.state { ProgressView() }
                        Text(machine.status).foregroundStyle(.white)
                        if case .running = machine.state {} else {
                            ScrollView {
                                Text(machine.logTail).font(.caption.monospaced()).foregroundStyle(.green)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 360)
                        }
                    }
                    .padding(20)
                }
            }
            .frame(minWidth: 300, idealWidth: 414, minHeight: 600, idealHeight: 896)
        }
        .toolbar {
            Button { machine.goHome() } label: { Label("Home", systemImage: "house") }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button { machine.press(0xFFC2) } label: { Label("Lock", systemImage: "lock") }
                .keyboardShortcut("l", modifiers: [.command])
            Button { machine.press(0xFFC1) } label: { Label("Volume up", systemImage: "speaker.plus") }
            Button { machine.press(0xFFC0) } label: { Label("Volume down", systemImage: "speaker.minus") }
            Button { NSWorkspace.shared.activateFileViewerSelecting([machine.runner.configuration.workingDirectory
                .appendingPathComponent("qemu.log")]) } label: { Label("Show logs", systemImage: "doc.text.magnifyingglass") }
            Button(role: .destructive) { machine.stop() } label: { Label("Stop", systemImage: "power") }
        }
        .navigationTitle(machine.title)
        .navigationSubtitle(stateText)
        .onDisappear { machine.stop() }
    }

    private var stateText: String {
        switch machine.state {
        case .running: return machine.frame == nil ? machine.status : "Running"
        case .stopped(let code): return "Stopped (\(code))"
        case .failed(let why): return "Failed: \(why)"
        case .idle: return ""
        }
    }
}

struct MacSettingsView: View {
    @AppStorage(MacPref.cacheMB) private var cacheMB = 1024

    var body: some View {
        Form {
            Picker("Translation cache", selection: $cacheMB) {
                ForEach([512, 1024, 2048], id: \.self) { Text("\($0) MB").tag($0) }
            }
            Text("Machines are kept in \(MacPref.machinesDirectory.path).").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 460)
    }
}
