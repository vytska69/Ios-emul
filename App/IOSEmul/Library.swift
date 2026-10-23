import Foundation
import IPSWKit
import EmulatorKit

/// An imported firmware. The IPSW itself stays where the user keeps it (they are several GiB);
/// only a security-scoped bookmark is stored.
struct FirmwareItem: Identifiable, Codable, Hashable {
    let id: UUID
    var fileName: String
    var bookmark: Data
    var version: String
    var build: String
    var productTypes: [String]
    var assets: [String: Data] = [:]   // external asset id → bookmark

    var workDirectory: URL {
        Library.machinesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var items: [FirmwareItem] = []
    @Published var lastError: String?

    nonisolated static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    nonisolated static let machinesDirectory = documents.appendingPathComponent("Machines", isDirectory: true)
    private static let indexURL = documents.appendingPathComponent("library.json")

    init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let decoded = try? JSONDecoder().decode([FirmwareItem].self, from: data) {
            items = decoded
        }
    }

    func importIPSW(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let ipsw = try IPSW(url: url)
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let item = FirmwareItem(id: UUID(), fileName: url.lastPathComponent, bookmark: bookmark,
                                    version: ipsw.version, build: ipsw.build,
                                    productTypes: ipsw.manifest.supportedProductTypes)
            items.insert(item, at: 0)
            save()
        } catch {
            lastError = "\(url.lastPathComponent): \(error)"
        }
    }

    func setAsset(_ assetID: String, url: URL, for item: FirmwareItem) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let i = items.firstIndex(of: item),
              let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        items[i].assets[assetID] = bookmark
        save()
    }

    func remove(_ offsets: IndexSet) {
        for i in offsets { try? FileManager.default.removeItem(at: items[i].workDirectory) }
        items.remove(atOffsets: offsets)
        save()
    }

    func item(_ id: UUID) -> FirmwareItem? { items.first { $0.id == id } }

    private func save() {
        do {
            try JSONEncoder().encode(items).write(to: Self.indexURL, options: .atomic)
        } catch {
            lastError = "Could not save library: \(error)"
        }
    }
}

/// Resolves a bookmark and keeps its security scope open until `release()`.
final class ScopedURL {
    let url: URL
    private var scoped: Bool

    init?(bookmark: Data) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }

    func release() {
        if scoped { url.stopAccessingSecurityScopedResource() }
        scoped = false
    }

    deinit { release() }
}
