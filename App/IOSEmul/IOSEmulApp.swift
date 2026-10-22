import SwiftUI
import UniformTypeIdentifiers

@main
struct IOSEmulApp: App {
    @StateObject private var library = Library()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
        }
    }
}

extension UTType {
    /// IPSWs have no registered system type; accept any archive/data file and validate on import.
    static let ipsw = UTType(filenameExtension: "ipsw", conformingTo: .zip) ?? .zip
}

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                if library.items.isEmpty {
                    ContentUnavailableHint()
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
                Button { importing = true } label: { Label("Import IPSW", systemImage: "plus") }
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
        }
    }
}

private struct ContentUnavailableHint: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.gen3").font(.largeTitle)
            Text("No firmware yet").font(.headline)
            Text("Import an iPhone or iPad .ipsw file. It is read in place, not copied.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
