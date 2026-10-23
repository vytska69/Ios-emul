import SwiftUI
import IPSWKit
import EmulatorKit

/// Browses the IPSWs ipsw.me lists and downloads them from Apple's CDN.
struct CatalogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [FirmwareCatalog.Device] = []
    @State private var error: String?
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Button("Try again") { Task { await load() } }
                    }
                } else if devices.isEmpty {
                    ProgressView("Loading devices from ipsw.me…").frame(maxWidth: .infinity)
                }
                let emulated = Set(FirmwareCatalog.emulatedProducts)
                let shown = filtered
                if !shown.filter({ emulated.contains($0.identifier) }).isEmpty {
                    Section {
                        ForEach(shown.filter { emulated.contains($0.identifier) }) { DeviceLink(device: $0, emulated: true) }
                    } header: {
                        Text("Emulated devices")
                    } footer: {
                        Text("These have a machine model. Firmware for other devices can be inspected, and often the same iOS version exists for an emulated one.")
                    }
                }
                ForEach(["iPhone", "iPad", "iPod"], id: \.self) { family in
                    let rows = shown.filter { $0.family == family && !emulated.contains($0.identifier) }
                    if !rows.isEmpty {
                        Section(family) {
                            ForEach(rows) { DeviceLink(device: $0, emulated: false) }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Device or identifier")
            .navigationTitle("Download IPSW")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FirmwareCatalog.Device.self) { FirmwareListView(device: $0) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { if devices.isEmpty { await load() } }
        }
    }

    private var filtered: [FirmwareCatalog.Device] {
        guard !query.isEmpty else { return devices }
        return devices.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.identifier.localizedCaseInsensitiveContains(query)
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
    let device: FirmwareCatalog.Device
    let emulated: Bool

    var body: some View {
        NavigationLink(value: device) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                    Text(device.identifier).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if emulated {
                    Image(systemName: "cpu").foregroundStyle(.tint)
                }
            }
        }
    }
}

/// Every IPSW of one device, newest first, with what the emulator can do with it.
private struct FirmwareListView: View {
    let device: FirmwareCatalog.Device
    @State private var firmwares: [FirmwareCatalog.Firmware] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        List {
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            } else if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if firmwares.isEmpty {
                Text("ipsw.me lists no IPSW for this device.").foregroundStyle(.secondary)
            }
            ForEach(firmwares, id: \.url) { fw in
                FirmwareRow(firmware: fw, deviceName: device.name)
            }
        }
        .navigationTitle(device.name)
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
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: Library

    var body: some View {
        let compat = FirmwareCatalog.compatibility(of: firmware)
        let downloaded = library.items.contains { $0.fileName == firmware.fileName }
            || FileManager.default.fileExists(atPath: DownloadManager.localFile(for: firmware.url).path)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("iOS \(firmware.version)").font(.headline)
                Text(firmware.buildid).foregroundStyle(.secondary)
                Spacer()
                if firmware.signed == true {
                    Text("Signed").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.green.opacity(0.2), in: Capsule())
                }
            }
            Text(details).font(.caption).foregroundStyle(.secondary)
            Label(compat.summary, systemImage: compat == .supported ? "checkmark.circle"
                  : compat.isRunnable ? "exclamationmark.triangle" : "xmark.circle")
                .font(.caption)
                .foregroundStyle(compat == .supported ? .green : compat.isRunnable ? .orange : .secondary)
                .lineLimit(2)
            if let item = downloads.items.first(where: { $0.url == firmware.url }) {
                DownloadProgressRow(item: item)
            } else if downloaded {
                Label("Downloaded", systemImage: "arrow.down.circle.fill").font(.caption).foregroundStyle(.secondary)
            } else {
                Button {
                    downloads.start(firmware, title: "\(deviceName) — iOS \(firmware.version) (\(firmware.buildid))")
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private var details: String {
        var parts: [String] = []
        if let size = firmware.filesize { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let date = firmware.releasedate?.prefix(10) { parts.append(String(date)) }
        parts.append(firmware.fileName)
        return parts.joined(separator: " · ")
    }
}

/// Progress, retry and cancel for one transfer; used in the catalog and the library.
struct DownloadProgressRow: View {
    let item: FirmwareDownloadItem
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch item.state {
            case .running:
                if let f = item.fraction { ProgressView(value: f) } else { ProgressView() }
                HStack {
                    Text(byteProgress).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .destructive) { downloads.cancel(item) }
                        .buttonStyle(.borderless).font(.caption)
                }
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red)
                HStack {
                    Button("Retry") { downloads.retry(item) }.buttonStyle(.borderless)
                    Spacer()
                    Button("Remove", role: .destructive) { downloads.cancel(item) }.buttonStyle(.borderless)
                }
                .font(.caption)
            }
        }
    }

    private var byteProgress: String {
        let fmt = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return item.expected > 0 ? "\(fmt(item.written)) of \(fmt(item.expected))" : fmt(item.written)
    }
}
