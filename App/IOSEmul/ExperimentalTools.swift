import SwiftUI
import IPSWKit
import EmulatorKit

// MARK: - Firmware tools (firmware page, Settings → Experimental → Firmware tools)

struct FirmwareToolsCard: View {
    @Environment(\.theme) private var theme
    let item: FirmwareItem
    let ipsw: IPSW
    let deviceTree: DeviceTreeNode?
    let backendID: String?
    @State private var confirmWipe = false
    @State private var wiped = false

    private var machineFolder: URL? { backendID.map { item.workDirectory.appendingPathComponent($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Firmware tools", icon: "wrench.and.screwdriver")
            Card(padding: 6) {
                ToolLink(symbol: "doc.zipper", title: "IPSW explorer",
                         detail: "\(ipsw.archive.entries.filter { !$0.isDirectory }.count) files · export any of them") {
                    IPSWExplorer(ipsw: ipsw)
                }
                if let deviceTree {
                    ToolLink(symbol: "point.3.connected.trianglepath.dotted", title: "DeviceTree",
                             detail: "\(deviceTree.children.count) top-level nodes") {
                        DeviceTreeBrowser(node: deviceTree, path: "/")
                    }
                }
                if let machineFolder {
                    ToolLink(symbol: "doc.text.magnifyingglass", title: "Machine logs",
                             detail: "serial.log, qemu.log, qemu-debug.log") {
                        LogsView(folder: machineFolder)
                    }
                }
                Button { confirmWipe = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: wiped ? "checkmark.circle.fill" : "trash")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(wiped ? Color.green : Color.red)
                            .frame(width: 34, height: 34)
                            .background((wiped ? Color.green : Color.red).opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(wiped ? "Machine disk deleted" : "Wipe this machine").font(.subheadline.weight(.semibold))
                            Text("The next boot installs iOS from the IPSW again").font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer()
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .confirmationDialog("Delete this firmware's virtual disk?", isPresented: $confirmWipe, titleVisibility: .visible) {
            Button("Wipe machine", role: .destructive) {
                try? FileManager.default.removeItem(at: item.workDirectory)
                withAnimation { wiped = true }
            }
        }
    }
}

private struct ToolLink<Destination: View>: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var destination: Destination

    var body: some View {
        NavigationLink { destination } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .frame(width: 34, height: 34)
                    .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

/// Every file in the IPSW, with export to Documents/Extracted (visible in the Files app).
struct IPSWExplorer: View {
    @Environment(\.theme) private var theme
    let ipsw: IPSW
    @State private var query = ""
    @State private var exporting: String?
    @State private var progress: Double = 0
    @State private var exported: [String: URL] = [:]
    @State private var error: String?

    private static let folder = Library.documents.appendingPathComponent("Extracted", isDirectory: true)

    private var entries: [ZipArchive.Entry] {
        ipsw.archive.entries
            .filter { !$0.isDirectory && (query.isEmpty || $0.path.localizedCaseInsensitiveContains(query)) }
            .sorted { $0.uncompressedSize > $1.uncompressedSize }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let error {
                    Card { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption) }
                }
                ForEach(entries, id: \.path) { entry in
                    Card(padding: 12) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((entry.path as NSString).lastPathComponent)
                                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(entry.path).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.uncompressedSize), countStyle: .file)
                                     + (entry.method == 8 ? " · deflated" : " · stored"))
                                    .font(.caption).foregroundStyle(.white.opacity(0.55))
                            }
                            Spacer()
                            if let url = exported[entry.path] {
                                ShareLink(item: url) { Image(systemName: "square.and.arrow.up").font(.title3) }
                            } else if exporting == entry.path {
                                ProgressView(value: progress).frame(width: 60).tint(theme.accent)
                            } else {
                                Button { export(entry) } label: { Image(systemName: "arrow.down.doc").font(.title3) }
                                    .buttonStyle(.plain).foregroundStyle(theme.accent)
                                    .disabled(exporting != nil)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .screenStyle()
        .searchable(text: $query, prompt: "File name or path")
        .navigationTitle("IPSW explorer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func export(_ entry: ZipArchive.Entry) {
        exporting = entry.path
        progress = 0
        error = nil
        let destination = Self.folder.appendingPathComponent((entry.path as NSString).lastPathComponent)
        let archive = ipsw.archive
        let throttle = ProgressThrottle()
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: destination)
                    try archive.extract(entry, to: destination) { fraction in
                        guard throttle.shouldReport(done: fraction >= 1) else { return }
                        Task { @MainActor in progress = fraction }
                    }
                }.value
                exported[entry.path] = destination
            } catch {
                self.error = "\((entry.path as NSString).lastPathComponent): \(error)"
            }
            exporting = nil
        }
    }
}

/// One DeviceTree node: its properties, decoded where they look like text, and its children.
struct DeviceTreeBrowser: View {
    let node: DeviceTreeNode
    let path: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text(path).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.5))
                if !node.children.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Children · \(node.children.count)", icon: "folder")
                        Card(padding: 6) {
                            ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                                NavigationLink {
                                    DeviceTreeBrowser(node: child, path: path + child.name + "/")
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(child.name).font(.subheadline.weight(.semibold).monospaced())
                                                .foregroundStyle(.white)
                                            if !child.compatible.isEmpty {
                                                Text(child.compatible.joined(separator: ", "))
                                                    .font(.caption2).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        Text("\(child.children.count)").font(.caption.monospacedDigit())
                                            .foregroundStyle(.white.opacity(0.35))
                                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                                            .foregroundStyle(.white.opacity(0.3))
                                    }
                                    .padding(10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Properties · \(node.properties.count)", icon: "list.bullet.rectangle")
                    Card {
                        ForEach(node.properties.keys.sorted(), id: \.self) { key in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key).font(.caption.weight(.semibold).monospaced())
                                Text(Self.preview(node.properties[key] ?? Data()))
                                    .font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.6))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .screenStyle()
        .navigationTitle(node.name.isEmpty ? "device-tree" : node.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Text for NUL-separated printable strings, hex for everything else.
    static func preview(_ data: Data) -> String {
        if data.isEmpty { return "(empty)" }
        let printable = data.allSatisfy { $0 == 0 || (0x20...0x7e).contains($0) }
        if printable, data.contains(where: { $0 != 0 }) {
            return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.joined(separator: " | ")
        }
        let hex = data.prefix(48).map { String(format: "%02x", $0) }.joined()
        return hex + (data.count > 48 ? "… (\(data.count) bytes)" : " (\(data.count) bytes)")
    }
}

/// Tails of the machine's logs with share buttons.
struct LogsView: View {
    let folder: URL
    @State private var logs: [(name: String, url: URL, size: Int64, tail: String)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if logs.isEmpty {
                    Card { Text("No logs yet; boot the machine first.").foregroundStyle(.white.opacity(0.6)) }
                }
                ForEach(logs, id: \.name) { log in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionLabel(text: log.name, icon: "doc.text")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: log.size, countStyle: .file))
                                .font(.caption2).foregroundStyle(.white.opacity(0.45))
                            ShareLink(item: log.url) { Image(systemName: "square.and.arrow.up") }
                        }
                        ScrollView(.horizontal) {
                            Text(log.tail.isEmpty ? "(empty)" : log.tail)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.green.opacity(0.85))
                                .textSelection(.enabled)
                                .padding(10)
                        }
                        .frame(maxHeight: 260)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .screenStyle()
        .navigationTitle("Machine logs")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .refreshable { load() }
    }

    private func load() {
        logs = ["serial.log", "qemu.log", "qemu-debug.log"].compactMap { name in
            let url = folder.appendingPathComponent(name)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64 else { return nil }
            return (name, url, size, Self.tail(of: url, bytes: 8192))
        }
    }

    static func tail(of url: URL, bytes: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > bytes ? size - bytes : 0
        try? handle.seek(toOffset: start)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }
}

// MARK: - Machine tools (running machine, Settings → Experimental → Machine tools)

struct MachineToolsPanel: View {
    @Environment(\.theme) private var theme
    @ObservedObject var display: DisplayModel
    @State private var command = ""
    @State private var output = ""
    @State private var paused = false
    @State private var running = false

    private var monitor: QEMUMonitor { QEMUMonitor(port: display.runner.configuration.monitorPort) }
    private let shortcuts = ["info registers", "info mtree -f", "info qtree", "info status"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ToolButton(symbol: paused ? "play.fill" : "pause.fill", title: paused ? "Resume" : "Pause") {
                    monitor.send(paused ? "cont" : "stop")
                    paused.toggle()
                }
                ToolButton(symbol: "arrow.counterclockwise", title: "Reset") { monitor.send("system_reset") }
                if let frame = display.frame {
                    ShareLink(item: Image(decorative: frame, scale: 1),
                              preview: SharePreview("iOS Emul screenshot", image: Image(decorative: frame, scale: 1))) {
                        VStack(spacing: 3) {
                            Image(systemName: "camera.fill").font(.system(size: 15, weight: .semibold))
                            Text("Screenshot").font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("QEMU monitor command", text: $command)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.caption.monospaced())
                    .padding(8).background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    .onSubmit { run(command) }
                Button { run(command) } label: {
                    Image(systemName: running ? "hourglass" : "return").font(.headline)
                        .frame(width: 38, height: 34)
                        .background(theme.gradient, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.black.opacity(0.8))
                }
                .buttonStyle(.plain)
                .disabled(running || command.isEmpty)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(shortcuts, id: \.self) { shortcut in
                        Button { command = shortcut; run(shortcut) } label: { Chip(text: shortcut, color: .orange) }
                            .buttonStyle(.plain)
                    }
                }
            }
            if !output.isEmpty {
                ScrollView([.vertical, .horizontal]) {
                    Text(output).font(.system(size: 10, design: .monospaced)).foregroundStyle(.green.opacity(0.9))
                        .textSelection(.enabled).padding(8)
                }
                .frame(maxHeight: 160)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }

    private func run(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !running else { return }
        running = true
        let monitor = self.monitor
        Task {
            let result = await Task.detached { monitor.query(line, idleSeconds: 1) }.value
            output = (result ?? "(the monitor did not answer)").trimmingCharacters(in: .whitespacesAndNewlines)
            running = false
        }
    }
}

private struct ToolButton: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(theme.accent)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
