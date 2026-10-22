import Foundation

/// High-level view of an `.ipsw` firmware file.
public final class IPSW {
    public let archive: ZipArchive
    public let manifest: BuildManifest
    public let devices: [DeviceInfo]

    public var url: URL { archive.url }
    public var version: String { manifest.productVersion }
    public var build: String { manifest.buildVersion }

    /// Major/minor/patch parsed from `ProductVersion`, e.g. "14.0.1" → (14, 0, 1).
    public var versionTriple: (Int, Int, Int) {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        return (parts.first ?? 0, parts.count > 1 ? parts[1] : 0, parts.count > 2 ? parts[2] : 0)
    }

    public init(url: URL, database: DeviceDatabase = .shared) throws {
        archive = try ZipArchive(url: url)
        if let e = archive.entry("BuildManifest.plist") {
            manifest = try BuildManifest(plist: archive.data(for: e))
        } else {
            // Pre-iOS 5 firmwares only ship Restore.plist; synthesise a minimal manifest from it.
            manifest = try IPSW.legacyManifest(archive)
        }
        devices = manifest.supportedProductTypes.map(database.device)
    }

    /// Image container format used by this firmware generation.
    public var imageFormat: String {
        guard let identity = manifest.identity(),
              let path = identity.path("KernelCache") ?? identity.path("iBoot"),
              let entry = archive.entry(path),
              let head = try? archive.head(of: entry, count: 32) else { return "unknown" }
        if IM4P.looksLikeIMG4(head) { return "IMG4" }
        if head.prefix(4) == Data("3gmI".utf8) { return "IMG3" }
        return "raw"
    }

    public func rawComponent(_ name: String, identity: BuildManifest.Identity) throws -> Data {
        guard let path = identity.path(name) else { throw IPSWError.missingComponent(name) }
        return try archive.data(for: path)
    }

    /// Returns a component with its IM4P wrapper and compression removed.
    public func decodedComponent(_ name: String, identity: BuildManifest.Identity) throws -> Data {
        let raw = try rawComponent(name, identity: identity)
        guard IM4P.looksLikeIMG4(raw) else { return raw }
        return try IM4P(raw).decodedPayload()
    }

    /// Extracts the files a backend asks for into `directory`, returning name → URL.
    public func extract(components: [String], identity: BuildManifest.Identity, to directory: URL,
                        decode: Set<String> = [], progress: ((String, Double) -> Void)? = nil) throws -> [String: URL] {
        var out: [String: URL] = [:]
        for name in components {
            guard let path = identity.path(name), let entry = archive.entry(path) else {
                throw IPSWError.missingComponent(name)
            }
            let dest = directory.appendingPathComponent((path as NSString).lastPathComponent)
            if decode.contains(name) {
                let data = try decodedComponent(name, identity: identity)
                try data.write(to: dest.appendingPathExtension("raw"))
                out[name] = dest.appendingPathExtension("raw")
            } else {
                try archive.extract(entry, to: dest) { progress?(name, $0) }
                out[name] = dest
            }
            progress?(name, 1)
        }
        return out
    }

    /// Extracts one archive member verbatim (for files not referenced by the manifest).
    public func extract(path: String, to directory: URL) throws -> URL {
        guard let entry = archive.entry(path) else { throw ZipArchive.Error.entryNotFound(path) }
        let dest = directory.appendingPathComponent((path as NSString).lastPathComponent)
        try archive.extract(entry, to: dest)
        return dest
    }

    /// Apple ships research (development-fused) kernels next to release ones in some IPSWs;
    /// emulators prefer them because they keep debug facilities enabled.
    public func researchKernelPath(for identity: BuildManifest.Identity) -> String? {
        guard let release = identity.path("KernelCache") else { return nil }
        let research = release.replacingOccurrences(of: "kernelcache.release.", with: "kernelcache.research.")
        if research != release, archive.entry(research) != nil { return research }
        return release.contains(".research.") ? release : nil
    }

    private static func legacyManifest(_ archive: ZipArchive) throws -> BuildManifest {
        guard let e = archive.entry("Restore.plist"),
              let plist = try PropertyListSerialization.propertyList(from: archive.data(for: e), format: nil) as? [String: Any]
        else { throw IPSWError.badManifest("neither BuildManifest.plist nor Restore.plist found") }

        let types = (plist["SupportedProductTypes"] as? [String]) ?? [(plist["ProductType"] as? String)].compactMap { $0 }
        var manifestEntries: [String: Any] = [:]
        if let kernels = plist["KernelCachesByTarget"] as? [String: [String: String]],
           let first = kernels.values.first, let release = first["Release"] {
            manifestEntries["KernelCache"] = ["Info": ["Path": release]]
        } else if let kc = (plist["RestoreKernelCaches"] as? [String: String])?["Release"] {
            manifestEntries["KernelCache"] = ["Info": ["Path": kc]]
        }
        if let rootfs = (plist["SystemRestoreImages"] as? [String: String])?["User"] {
            manifestEntries["OS"] = ["Info": ["Path": rootfs]]
        }
        if let ramdisk = (plist["RestoreRamDisks"] as? [String: String])?["User"] {
            manifestEntries["RestoreRamDisk"] = ["Info": ["Path": ramdisk]]
        }
        let synth: [String: Any] = [
            "ProductVersion": plist["ProductVersion"] ?? "?",
            "ProductBuildVersion": plist["ProductBuildVersion"] ?? "?",
            "SupportedProductTypes": types,
            "BuildIdentities": [[
                "Info": ["DeviceClass": (plist["DeviceClass"] as? String) ?? "", "Variant": "Legacy Restore",
                         "RestoreBehavior": "Erase"],
                "Manifest": manifestEntries,
            ]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: synth, format: .binary, options: 0)
        return try BuildManifest(plist: data)
    }
}
