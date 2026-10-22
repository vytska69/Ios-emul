import Foundation

/// Parsed `BuildManifest.plist` (iOS 5+) or `Restore.plist` fallback.
public struct BuildManifest {
    public struct Component: Hashable {
        public let name: String
        public let path: String
    }

    public struct Identity {
        public let deviceClass: String          // e.g. "n104ap"
        public let variant: String              // e.g. "Customer Erase Install (IPSW)"
        public let restoreBehavior: String?     // "Erase" / "Update"
        public let boardID: Int?
        public let chipID: Int?
        public let components: [String: Component]

        public var isErase: Bool {
            restoreBehavior == "Erase" || variant.localizedCaseInsensitiveContains("erase")
        }

        public func path(_ component: String) -> String? { components[component]?.path }
    }

    public let productVersion: String
    public let buildVersion: String
    public let supportedProductTypes: [String]
    public let identities: [Identity]

    public init(plist data: Data) throws {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw IPSWError.badManifest("root is not a dictionary")
        }
        productVersion = root["ProductVersion"] as? String ?? "?"
        buildVersion = root["ProductBuildVersion"] as? String ?? "?"
        supportedProductTypes = root["SupportedProductTypes"] as? [String] ?? []
        let rawIdentities = root["BuildIdentities"] as? [[String: Any]] ?? []
        identities = rawIdentities.map { raw in
            let info = raw["Info"] as? [String: Any] ?? [:]
            let manifest = raw["Manifest"] as? [String: Any] ?? [:]
            var comps: [String: Component] = [:]
            for (name, value) in manifest {
                guard let entry = value as? [String: Any],
                      let cinfo = entry["Info"] as? [String: Any],
                      let path = cinfo["Path"] as? String else { continue }
                comps[name] = Component(name: name, path: path)
            }
            return Identity(
                deviceClass: (info["DeviceClass"] as? String ?? "").lowercased(),
                variant: info["Variant"] as? String ?? "",
                restoreBehavior: info["RestoreBehavior"] as? String,
                boardID: Self.int(raw["ApBoardID"]),
                chipID: Self.int(raw["ApChipID"]),
                components: comps
            )
        }
    }

    /// Picks the identity that best matches a board, preferring a full erase install.
    public func identity(for deviceClass: String? = nil) -> Identity? {
        let candidates = deviceClass.map { dc in identities.filter { $0.deviceClass == dc.lowercased() } } ?? identities
        return candidates.first(where: \.isErase) ?? candidates.first
    }

    public var deviceClasses: [String] {
        var seen = Set<String>()
        return identities.map(\.deviceClass).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func int(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let s = value as? String {
            return s.hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s)
        }
        return nil
    }
}

public enum IPSWError: Error, CustomStringConvertible {
    case badManifest(String)
    case missingComponent(String)
    case noIdentity

    public var description: String {
        switch self {
        case .badManifest(let s): return "BuildManifest.plist is invalid: \(s)"
        case .missingComponent(let c): return "IPSW does not contain component \(c)"
        case .noIdentity: return "IPSW has no usable build identity"
        }
    }
}
