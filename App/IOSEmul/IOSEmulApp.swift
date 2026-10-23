import SwiftUI
import UniformTypeIdentifiers

@main
struct IOSEmulApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = Library()
    @StateObject private var downloads = DownloadManager()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(downloads)
                .onAppear { downloads.onFinished = { [library] in library.importIPSW(at: $0) } }
        }
    }
}

extension UTType {
    /// IPSWs have no registered system type; accept any archive/data file and validate on import.
    static let ipsw = UTType(filenameExtension: "ipsw", conformingTo: .zip) ?? .zip
}

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadManager
    @State private var importing = false
    @State private var browsing = false

    var body: some View {
        NavigationStack {
            List {
                if !downloads.items.isEmpty {
                    Section("Downloading") {
                        ForEach(downloads.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.subheadline)
                                DownloadProgressRow(item: item)
                            }
                        }
                    }
                }
                if library.items.isEmpty && downloads.items.isEmpty {
                    ContentUnavailableHint(download: { browsing = true })
                }
                ForEach(library.items) { item in
                    NavigationLink(value: item.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("iOS \(item.version) (\(item.build))").font(.headline)
                            Text(item.productTypes.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(item.fileName).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .onDelete(perform: library.remove)
            }
            .navigationTitle("Firmware")
            .navigationDestination(for: UUID.self) { id in
                FirmwareDetailView(itemID: id)
            }
            .toolbar {
                Menu {
                    Button { browsing = true } label: { Label("Download from ipsw.me", systemImage: "arrow.down.circle") }
                    Button { importing = true } label: { Label("Import from Files", systemImage: "folder") }
                } label: {
                    Label("Add IPSW", systemImage: "plus")
                }
            }
            .sheet(isPresented: $browsing) {
                CatalogView()
                    .environmentObject(library)
                    .environmentObject(downloads)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.ipsw, .zip, .data],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { urls.forEach(library.importIPSW) }
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
}

private struct ContentUnavailableHint: View {
    let download: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.gen3").font(.largeTitle)
            Text("No firmware yet").font(.headline)
            Text("Download an IPSW from ipsw.me, or import an .ipsw file you already have (it is read in place, not copied).")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Download from ipsw.me", action: download).buttonStyle(.borderedProminent).padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
