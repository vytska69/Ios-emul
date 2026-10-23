import Foundation
import IPSWKit

/// The IPSW listings of ipsw.me: every device and its firmware, for browsing and downloading, and a
/// firmware the emulator *can* boot for a requested iOS version.
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
        /// Whether Apple still signs it; irrelevant to the emulator, shown for orientation.
        public let signed: Bool?
        /// ISO 8601 release date, as ipsw.me lists it.
        public let releasedate: String?
        public let sha1sum: String?

        public var fileName: String { url.lastPathComponent }
    }

    /// A product listed by ipsw.me.
    public struct Device: Decodable, Hashable, Identifiable {
        public let name: String
        public let identifier: String
        public var id: String { identifier }
        /// "iPhone", "iPad" or "iPod"; nil for products the emulator never targets (Watch, TV, Mac…).
        public var family: String? {
            ["iPhone", "iPad", "iPod"].first { identifier.hasPrefix($0) }
        }
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
        let url = api.appendingPathComponent("device/\(productType)").appending(queryItems: [.init(name: "type", value: "ipsw")])
        return try Self.decodeFirmwares(try await get(url))
    }

    /// Every iPhone, iPad and iPod touch ipsw.me knows, emulated models first, then by family and
    /// newest first within it (ipsw.me lists oldest first).
    public func devices() async throws -> [Device] {
        try Self.decodeDevices(try await get(api.appendingPathComponent("devices")))
    }

    static func decodeFirmwares(_ data: Data) throws -> [Firmware] {
        struct Listing: Decodable { let firmwares: [Firmware] }
        return try JSONDecoder().decode(Listing.self, from: data).firmwares
    }

    static func decodeDevices(_ data: Data) throws -> [Device] {
        let all = try JSONDecoder().decode([Device].self, from: data).filter { $0.family != nil }
        let families = ["iPhone", "iPad", "iPod"]
        return all.enumerated().sorted { a, b in
            let ea = emulatedProducts.firstIndex(of: a.element.identifier) ?? .max
            let eb = emulatedProducts.firstIndex(of: b.element.identifier) ?? .max
            if ea != eb { return ea < eb }
            let fa = families.firstIndex(of: a.element.family!)!, fb = families.firstIndex(of: b.element.family!)!
            if fa != fb { return fa < fb }
            return a.offset > b.offset
        }.map(\.element)
    }

    /// The backend that would run `firmware` on its own device, if any.
    public static func compatibility(of firmware: Firmware, registry: BackendRegistry = .shared,
                                     database: DeviceDatabase = .shared) -> Compatibility {
        let device = database.device(firmware.identifier)
        if let (_, compat) = registry.evaluate(device: device, version: firmware.version, build: firmware.buildid) {
            return compat
        }
        return .unsupported(BackendRegistry.reason(for: device))
    }

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        return data
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
