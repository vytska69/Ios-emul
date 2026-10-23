import SwiftUI
import UniformTypeIdentifiers
import IPSWKit
import EmulatorKit

@main
struct IOSEmulApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = Library()
    @StateObject private var downloads = DownloadManager()
    @AppStorage(Pref.theme) private var themeName = AppTheme.aurora.rawValue

    init() { Pref.register() }

    var body: some Scene {
        WindowGroup {
            let theme = AppTheme(rawValue: themeName) ?? .aurora
            RootView()
                .environmentObject(library)
                .environmentObject(downloads)
                .environment(\.theme, theme)
                .tint(theme.accent)
                .preferredColorScheme(.dark)
                .onAppear { downloads.onFinished = { [library] in library.importIPSW(at: $0) } }
        }
    }
}

extension UTType {
    /// IPSWs have no registered system type; accept any archive/data file and validate on import.
    static let ipsw = UTType(filenameExtension: "ipsw", conformingTo: .zip) ?? .zip
}

enum AppTab: Hashable { case machines, download, settings }

struct RootView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @State private var tab = AppTab.machines

    var body: some View {
        TabView(selection: $tab) {
            LibraryView(openCatalog: { tab = .download })
                .tabItem { Label("Machines", systemImage: "cpu") }
                .tag(AppTab.machines)
            CatalogView()
                .tabItem { Label("Download", systemImage: "arrow.down.circle") }
                .badge(downloads.items.filter { $0.state == .running }.count)
                .tag(AppTab.download)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.theme) private var theme
    let openCatalog: () -> Void
    @State private var importing = false
    @State private var deleting: FirmwareItem?

    private let columns = [GridItem(.adaptive(minimum: 158), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if !downloads.items.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(text: "Downloading", icon: "arrow.down")
                            ForEach(downloads.items) { item in
                                Card {
                                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    DownloadProgressRow(item: item)
                                }
                            }
                        }
                    }
                    if library.items.isEmpty && downloads.items.isEmpty {
                        EmptyLibrary(download: openCatalog, importFile: { importing = true })
                    } else if !library.items.isEmpty {
                        SectionLabel(text: "Firmware", icon: "shippingbox")
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(library.items) { item in
                                NavigationLink(value: item.id) { FirmwareCard(item: item) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) { deleting = item } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 32)
            }
            .screenStyle()
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { FirmwareDetailView(itemID: $0) }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: openCatalog) { Label("Download from ipsw.me", systemImage: "arrow.down.circle") }
                        Button { importing = true } label: { Label("Import from Files", systemImage: "folder") }
                    } label: {
                        Image(systemName: "plus").font(.headline)
                            .frame(width: 34, height: 34)
                            .background(theme.gradient, in: Circle())
                            .foregroundStyle(.black.opacity(0.8))
                    }
                    .accessibilityLabel("Add IPSW")
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.ipsw, .zip, .data],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { urls.forEach(library.importIPSW) }
            }
            .confirmationDialog("Remove \(deleting.map { "iOS \($0.version)" } ?? "")?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Remove from library", role: .destructive) {
                    if let item = deleting, let i = library.items.firstIndex(of: item) {
                        library.remove(IndexSet(integer: i))
                    }
                    deleting = nil
                }
            } message: {
                Text("Its virtual disk is deleted. The IPSW file itself stays where it is.")
            }
            .alert("Import failed", isPresented: Binding(get: { library.lastError != nil },
                                                         set: { if !$0 { library.lastError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.lastError ?? "")
            }
            .alert("Download not started", isPresented: Binding(get: { downloads.lastError != nil },
                                                                set: { if !$0 { downloads.lastError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(downloads.lastError ?? "")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            GlyphTile(symbol: "cpu", size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("iOS Emul").font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text(library.items.isEmpty ? "Run any IPSW on an emulated Apple device"
                     : "\(library.items.count) firmware \(library.items.count == 1 ? "image" : "images")")
                    .font(.footnote).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.top, 8)
    }
}

/// One imported firmware in the library grid.
private struct FirmwareCard: View {
    @Environment(\.theme) private var theme
    let item: FirmwareItem

    private var emulated: Bool { item.productTypes.contains { FirmwareCatalog.emulatedProducts.contains($0) } }
    private var deviceNames: String {
        let names = item.productTypes.map { DeviceDatabase.shared.device($0).name }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: deviceSymbol(for: item.productTypes.first ?? ""))
                    .font(.title3)
                    .foregroundStyle(emulated ? theme.accent : .white.opacity(0.4))
                Spacer()
                if emulated { Chip(text: "Emulated", color: theme.accent, icon: "bolt.fill") }
            }
            Spacer(minLength: 4)
            Text("iOS \(item.version)")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(item.build).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.5))
            Text(deviceNames).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white.opacity(0.055))
                if emulated {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(theme.gradient(opacity: 0.16))
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(emulated ? AnyShapeStyle(theme.gradient(opacity: 0.6)) : AnyShapeStyle(.white.opacity(0.08))))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the firmware page")
    }
}

private struct EmptyLibrary: View {
    @Environment(\.theme) private var theme
    let download: () -> Void
    let importFile: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(theme.gradient(opacity: 0.18)).frame(width: 140, height: 140).blur(radius: 10)
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(theme.gradient)
            }
            Text("No firmware yet").font(.title3.weight(.bold))
            Text("Download an IPSW from ipsw.me, or import an .ipsw you already have. Imported files are read in place, not copied.")
                .font(.footnote).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
            Button(action: download) { Label("Browse firmware", systemImage: "arrow.down.circle.fill") }
                .buttonStyle(GlowButtonStyle())
            Button(action: importFile) { Label("Import from Files", systemImage: "folder") }
                .buttonStyle(GhostButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}
