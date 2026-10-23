import SwiftUI
import IPSWKit
import EmulatorKit

/// Browses the IPSWs ipsw.me lists and downloads them from Apple's CDN.
struct CatalogView: View {
    @Environment(\.theme) private var theme
    @State private var devices: [FirmwareCatalog.Device] = []
    @State private var error: String?
    @State private var query = ""
    @State private var family = "All"

    private let families = ["All", "iPhone", "iPad", "iPod"]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header
                    familyPicker

                    if let error {
                        Card {
                            Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.red)
                            Button("Try again") { Task { await load() } }.buttonStyle(GhostButtonStyle())
                        }
                    } else if devices.isEmpty {
                        Card {
                            HStack(spacing: 12) {
                                ProgressView().tint(theme.accent)
                                Text("Loading devices from ipsw.me…").foregroundStyle(.white.opacity(0.7))
                            }
                        }
                    }

                    let emulated = Set(FirmwareCatalog.emulatedProducts)
                    let shown = filtered
                    let ready = shown.filter { emulated.contains($0.identifier) }
                    if !ready.isEmpty {
                        SectionLabel(text: "Emulated devices", icon: "bolt.fill")
                        ForEach(ready) { DeviceLink(device: $0, emulated: true) }
                        Text("These have a machine model. Firmware for other devices can still be inspected, and the same iOS version often exists for an emulated one.")
                            .font(.caption).foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 4)
                    }
                    ForEach(families.dropFirst(), id: \.self) { name in
                        let rows = shown.filter { $0.family == name && !emulated.contains($0.identifier) }
                        if !rows.isEmpty {
                            SectionLabel(text: name, icon: deviceSymbol(for: name))
                            ForEach(rows) { DeviceLink(device: $0, emulated: false) }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 32)
            }
            .screenStyle()
            .searchable(text: $query, prompt: "Device or identifier")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FirmwareCatalog.Device.self) { FirmwareListView(device: $0) }
            .task { if devices.isEmpty { await load() } }
            .refreshable { await load() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            GlyphTile(symbol: "arrow.down.circle", size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("Download").font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text("Every IPSW Apple has published, via ipsw.me")
                    .font(.footnote).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.top, 8)
    }

    private var familyPicker: some View {
        HStack(spacing: 8) {
            ForEach(families, id: \.self) { name in
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { family = name } } label: {
                    Text(name).font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .foregroundStyle(family == name ? Color.black.opacity(0.85) : Color.white.opacity(0.8))
                        .background {
                            if family == name {
                                Capsule().fill(theme.gradient)
                            } else {
                                Capsule().fill(.white.opacity(0.07))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var filtered: [FirmwareCatalog.Device] {
        devices.filter { device in
            (family == "All" || device.family == family)
                && (query.isEmpty || device.name.localizedCaseInsensitiveContains(query)
                    || device.identifier.localizedCaseInsensitiveContains(query))
        }
    }

    private func load() async {
        error = nil
        do {
            devices = try await FirmwareCatalog().devices()
        } catch {
            self.error = "Could not load the device list: \(error.localizedDescription)"
        }
    }
}

private struct DeviceLink: View {
    @Environment(\.theme) private var theme
    let device: FirmwareCatalog.Device
    let emulated: Bool

    var body: some View {
        NavigationLink(value: device) {
            HStack(spacing: 14) {
                if emulated {
                    GlyphTile(symbol: deviceSymbol(for: device.identifier), size: 40)
                } else {
                    Image(systemName: deviceSymbol(for: device.identifier))
                        .font(.title3).foregroundStyle(.white.opacity(0.5))
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text(device.identifier).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.3))
            }
            .padding(12)
            .background(.white.opacity(emulated ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(emulated ? theme.gradient(opacity: 0.45) : theme.gradient(opacity: 0)))
        }
        .buttonStyle(.plain)
    }
}

/// Every IPSW of one device, newest first, with what the emulator can do with it.
private struct FirmwareListView: View {
    let device: FirmwareCatalog.Device
    @Environment(\.theme) private var theme
    @State private var firmwares: [FirmwareCatalog.Firmware] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    GlyphTile(symbol: deviceSymbol(for: device.identifier), size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.system(.title, design: .rounded).weight(.bold))
                        Text(device.identifier).font(.footnote.monospaced()).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.top, 8)

                if let error {
                    Card { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                } else if loading {
                    Card { ProgressView().tint(theme.accent).frame(maxWidth: .infinity) }
                } else if firmwares.isEmpty {
                    Card { Text("ipsw.me lists no IPSW for this device.").foregroundStyle(.white.opacity(0.6)) }
                }
                ForEach(firmwares, id: \.url) { fw in
                    FirmwareRow(firmware: fw, deviceName: device.name)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 32)
        }
        .screenStyle()
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                firmwares = try await FirmwareCatalog().firmwares(for: device.identifier)
            } catch {
                self.error = "Could not load firmware: \(error.localizedDescription)"
            }
            loading = false
        }
    }
}

private struct FirmwareRow: View {
    let firmware: FirmwareCatalog.Firmware
    let deviceName: String
    @Environment(\.theme) private var theme
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: Library

    var body: some View {
        let compat = FirmwareCatalog.compatibility(of: firmware)
        let downloaded = library.items.contains { $0.fileName == firmware.fileName }
            || FileManager.default.fileExists(atPath: DownloadManager.localFile(for: firmware.url).path)
        Card(padding: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("iOS \(firmware.version)").font(.system(.title3, design: .rounded).weight(.bold))
                Text(firmware.buildid).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.5))
                Spacer()
                if firmware.signed == true { Chip(text: "Signed", color: .green, icon: "checkmark.seal.fill") }
            }
            HStack(spacing: 6) {
                Chip(text: compat.label, color: compat.color)
                if let size = firmware.filesize {
                    Chip(text: ByteCountFormatter.string(fromByteCount: size, countStyle: .file), color: .white.opacity(0.75))
                }
                if let date = firmware.releasedate?.prefix(10) {
                    Chip(text: String(date), color: .white.opacity(0.75))
                }
            }
            if compat != .supported {
                Text(compat.summary).font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
            }
            if let item = downloads.items.first(where: { $0.url == firmware.url }) {
                DownloadProgressRow(item: item)
            } else if downloaded {
                Label("Downloaded", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Button {
                    downloads.start(firmware, title: "\(deviceName) — iOS \(firmware.version) (\(firmware.buildid))")
                } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
    }
}

/// Progress, retry and cancel for one transfer; used in the catalog and the library.
struct DownloadProgressRow: View {
    let item: FirmwareDownloadItem
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch item.state {
            case .running:
                GlowBar(value: item.fraction)
                HStack {
                    Text(byteProgress).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Button(role: .destructive) { downloads.cancel(item) } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3)
                    }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
                }
            case .verifying:
                GlowBar(value: nil)
                Text("Checking the file…").font(.caption).foregroundStyle(.white.opacity(0.55))
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                HStack {
                    Button("Retry") { downloads.retry(item) }.buttonStyle(GhostButtonStyle())
                    Spacer()
                    Button("Remove", role: .destructive) { downloads.cancel(item) }
                        .font(.caption.weight(.semibold)).foregroundStyle(.red)
                }
            }
        }
    }

    private var byteProgress: String {
        let fmt = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let fraction = item.fraction.map { " · \(Int($0 * 100))%" } ?? ""
        return (item.expected > 0 ? "\(fmt(item.written)) of \(fmt(item.expected))" : fmt(item.written)) + fraction
    }
}
