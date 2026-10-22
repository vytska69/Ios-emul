import Foundation

public struct SoC: Hashable {
    public let id: String            // e.g. "T8030"
    public let marketingName: String // e.g. "A13 Bionic"
    public let core: String
    public let arch: String          // armv6 / armv7 / arm64

    init(id: String, from raw: SoC.Raw) {
        self.id = id; marketingName = raw.marketingName; core = raw.core; arch = raw.arch
    }

    struct Raw: Decodable { let marketingName: String; let core: String; let arch: String }
}

public struct DeviceInfo: Hashable {
    public let productType: String   // e.g. "iPhone12,1"
    public let name: String          // e.g. "iPhone 11"
    public let soc: SoC?

    public var family: String {
        if productType.hasPrefix("iPad") { return "iPad" }
        if productType.hasPrefix("iPod") { return "iPod" }
        return "iPhone"
    }
}

public final class DeviceDatabase {
    public static let shared: DeviceDatabase = {
        guard let url = Bundle.module.url(forResource: "devices", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let db = try? DeviceDatabase(json: data) else {
            return DeviceDatabase(socs: [:], devices: [:])
        }
        return db
    }()

    private let socs: [String: SoC]
    private let devices: [String: (name: String, soc: String)]

    private init(socs: [String: SoC], devices: [String: (name: String, soc: String)]) {
        self.socs = socs; self.devices = devices
    }

    convenience init(json: Data) throws {
        struct Root: Decodable {
            struct Device: Decodable { let name: String; let soc: String }
            let socs: [String: SoC.Raw]
            let devices: [String: Device]
        }
        let root = try JSONDecoder().decode(Root.self, from: json)
        self.init(socs: Dictionary(uniqueKeysWithValues: root.socs.map { ($0.key, SoC(id: $0.key, from: $0.value)) }),
                  devices: root.devices.mapValues { ($0.name, $0.soc) })
    }

    public func device(_ productType: String) -> DeviceInfo {
        guard let d = devices[productType] else {
            return DeviceInfo(productType: productType, name: productType, soc: nil)
        }
        return DeviceInfo(productType: productType, name: d.name, soc: socs[d.soc])
    }

    public func soc(_ id: String) -> SoC? { socs[id.uppercased()] }
}
