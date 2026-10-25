import Foundation

/// What this copy of the app was signed with, read from its own executable and provisioning
/// profile. Installers re-sign the IPA and some drop entitlements QEMU needs (get-task-allow for
/// JIT, the memory ones for a 4 GB guest) without saying so.
struct SigningInfo {
    /// Entitlements in the executable's code signature (what the process actually has).
    let entitlements: [String: Any]
    /// The embedded provisioning profile, if the installer left one.
    let profile: [String: Any]?

    static let current = SigningInfo()

    init() {
        entitlements = Bundle.main.executableURL.flatMap { Self.entitlements(ofExecutable: $0) } ?? [:]
        profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision").flatMap(Self.profile(at:))
    }

    func has(_ key: String) -> Bool { entitlements[key] as? Bool ?? false }

    var getTaskAllow: Bool { has("get-task-allow") }
    var increasedMemoryLimit: Bool { has("com.apple.developer.kernel.increased-memory-limit") }
    var extendedVirtualAddressing: Bool { has("com.apple.developer.kernel.extended-virtual-addressing") }

    /// "Development", "Ad hoc", "Enterprise", "App Store" or nil without a profile.
    var profileKind: String? {
        guard let profile else { return nil }
        let profileEntitlements = profile["Entitlements"] as? [String: Any] ?? [:]
        if profileEntitlements["get-task-allow"] as? Bool == true { return "Development" }
        if profile["ProvisionsAllDevices"] as? Bool == true { return "Enterprise" }
        if profile["ProvisionedDevices"] != nil { return "Ad hoc" }
        return "App Store"
    }
    var profileTeam: String? { profile?["TeamName"] as? String }
    var profileExpiry: Date? { profile?["ExpirationDate"] as? Date }

    // MARK: Parsing

    private static func profile(at url: URL) -> [String: Any]? {
        // A CMS envelope around an XML plist.
        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil)) as? [String: Any]
    }

    private static func entitlements(ofExecutable url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 32 else { return nil }
        func be32(_ o: Int) -> Int { data.count >= o + 4 ? Int(data[o]) << 24 | Int(data[o + 1]) << 16 | Int(data[o + 2]) << 8 | Int(data[o + 3]) : 0 }
        func le32(_ o: Int) -> Int { data.count >= o + 4 ? Int(data[o]) | Int(data[o + 1]) << 8 | Int(data[o + 2]) << 16 | Int(data[o + 3]) << 24 : 0 }

        // A fat binary: take the arm64 slice.
        var base = 0
        if be32(0) == 0xCAFE_BABE {
            let count = be32(4)
            base = -1
            for i in 0..<count where be32(8 + i * 20) == 0x0100_000C { base = be32(8 + i * 20 + 8) }
            guard base >= 0 else { return nil }
        }
        guard le32(base) == 0xFEED_FACF else { return nil }
        let commands = le32(base + 16)
        var offset = base + 32
        for _ in 0..<commands {
            let cmd = le32(offset), size = le32(offset + 4)
            guard size > 0 else { return nil }
            if cmd == 0x1D /* LC_CODE_SIGNATURE */ {
                let blob = base + le32(offset + 8)
                guard be32(blob) == 0xFADE_0CC0 else { return nil }
                for i in 0..<be32(blob + 8) {
                    let type = be32(blob + 12 + i * 8), at = blob + be32(blob + 16 + i * 8)
                    guard type == 5 /* entitlements */, be32(at) == 0xFADE_7171 else { continue }
                    let length = be32(at + 4)
                    guard length > 8, at + length <= data.count else { return nil }
                    return (try? PropertyListSerialization.propertyList(from: data[(at + 8)..<(at + length)], format: nil)) as? [String: Any]
                }
                return [:]
            }
            offset += size
        }
        return nil
    }
}
