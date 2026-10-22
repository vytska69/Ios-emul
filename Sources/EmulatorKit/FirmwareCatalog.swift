import Foundation
import IPSWKit

/// Finds a firmware the emulator *can* boot for a requested iOS version.
///
/// Most iPhone/iPad models have no machine model, but the same iOS release usually exists for one
/// that does. Booting that IPSW gives the user the iOS version they asked for, which is what
/// "run this iOS" means in practice. Listings come from the public ipsw.me API, the files
/// themselves from Apple's CDN.
public struct FirmwareCatalog {
    public struct Firmware: Decodable, Hashable {
        public let identifier: String
        public let version: String
        public let buildid: String
        public let url: URL
        public let filesize: Int64?
        public let signed: Bool?
    }

    public struct Suggestion: Hashable {
        public let firmware: Firmware
        public let device: DeviceInfo
        public let backendID: String
        public let compatibility: Compatibility
        /// True when the suggestion is the exact version asked for, not just the same major release.
        public let exactVersion: Bool
    }

    let session: URLSession
    let api: URL

    public init(session: URLSession = .shared, api: URL = URL(string: "https://api.ipsw.me/v4/")!) {
        self.session = session
        self.api = api
    }

    /// Product types that have a machine model, best first.
    public static let emulatedProducts = ["iPhone12,1", "iPhone12,3", "iPhone12,5", "iPhone8,2", "iPhone8,1",
                                          "iPod2,1", "iPod1,1"]

    public func firmwares(for productType: String) async throws -> [Firmware] {
        struct Device: Decodable { let firmwares: [Firmware] }
        let url = api.appendingPathComponent("device/\(productType)").appending(queryItems: [.init(name: "type", value: "ipsw")])
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Device.self, from: data).firmwares
    }

    /// Picks the closest bootable firmware for `version`: exact version first, otherwise the newest
    /// build of the same major release, preferring fully supported machines.
    public func suggestion(forVersion version: String, registry: BackendRegistry = .shared,
                           database: DeviceDatabase = .shared) async throws -> Suggestion? {
        var candidates: [Suggestion] = []
        for product in Self.emulatedProducts {
            guard let list = try? await firmwares(for: product) else { continue }
            candidates += Self.rank(list, version: version, device: database.device(product), registry: registry)
        }
        return Self.best(candidates)
    }

    static func rank(_ list: [Firmware], version: String, device: DeviceInfo,
                     registry: BackendRegistry) -> [Suggestion] {
        let major = version.split(separator: ".").first.map(String.init) ?? version
        return list.compactMap { fw in
            let exact = fw.version == version
            guard exact || fw.version.split(separator: ".").first.map(String.init) == major else { return nil }
            guard let (backend, compat) = registry.evaluate(device: device, version: fw.version, build: fw.buildid),
                  compat.isRunnable else { return nil }
            return Suggestion(firmware: fw, device: device, backendID: backend.id, compatibility: compat,
                              exactVersion: exact)
        }
    }

    static func best(_ candidates: [Suggestion]) -> Suggestion? {
        func score(_ s: Suggestion) -> Int {
            (s.exactVersion ? 4 : 0) + (s.compatibility == .supported ? 2 : 0)
        }
        // Stable: among equal scores keep API order, which is newest build first.
        return candidates.enumerated().max { a, b in
            score(a.element) != score(b.element) ? score(a.element) < score(b.element) : a.offset > b.offset
        }?.element
    }
}

/// Downloads an IPSW to disk with progress, resuming nothing fancy: IPSWs are fetched once.
public final class FirmwareDownload: NSObject, URLSessionDownloadDelegate {
    public var onProgress: ((Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private let destination: URL

    public init(destination: URL) { self.destination = destination }

    public func start(_ url: URL) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            session.downloadTask(with: url).resume()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error); continuation = nil }
    }
}
