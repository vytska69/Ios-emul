import Foundation
import IPSWKit

/// How well a backend can run a given firmware.
public enum Compatibility: Hashable {
    case supported
    case experimental(String)
    case unsupported(String)

    public var isRunnable: Bool {
        if case .unsupported = self { return false }
        return true
    }

    public var summary: String {
        switch self {
        case .supported: return "Supported"
        case .experimental(let why): return "Experimental: \(why)"
        case .unsupported(let why): return "Unsupported: \(why)"
        }
    }
}

/// A file the backend needs that is not inside the IPSW (boot ROM dumps, tickets, …).
public struct ExternalAsset: Hashable, Identifiable {
    public let id: String
    public let title: String
    public let help: String

    public init(id: String, title: String, help: String) {
        self.id = id; self.title = title; self.help = help
    }
}

/// Mirrors the Inferno machines' `boot-mode` property.
public enum BootMode: String, CaseIterable, Codable {
    /// Restore ramdisk until a restore has completed (NVRAM `auto-boot` set), then the installed OS.
    case auto
    /// Clear `auto-boot` and boot the restore ramdisk again.
    case enterRecovery = "enter_recovery"
    /// Set `auto-boot` and boot the installed OS.
    case exitRecovery = "exit_recovery"
    /// Skip the restore entirely: write the IPSW's root filesystem image straight onto the
    /// virtual disk and boot it. No restore host (computer, idevicerestore) is needed.
    case direct

    /// Value for the Inferno machines' `boot-mode` property.
    public var machineBootMode: String {
        self == .direct ? BootMode.exitRecovery.rawValue : rawValue
    }
}

/// Everything needed to start one virtual machine.
public struct MachineConfiguration: Codable, Equatable {
    public var backendID: String
    public var qemuBinary: String           // binary name (macOS) or dylib name (iOS)
    public var arguments: [String]
    public var workingDirectory: URL
    public var vncPort: UInt16
    public var monitorPort: UInt16
}

public struct PrepareContext {
    public let ipsw: IPSW
    public let identity: BuildManifest.Identity
    public let device: DeviceInfo
    public let workDirectory: URL
    public let externalAssets: [String: URL]
    public let bootMode: BootMode
    public let memoryMB: Int
    public let cpuCount: Int
    /// `-v` on the kernel command line: boot text instead of the Apple logo.
    public let verboseBoot: Bool
    /// QEMU translation cache for in-process runs on iOS (`-accel tcg,tb-size=`).
    public let translationCacheMB: Int
    /// Appended to the kernel command line (experimental settings).
    public let extraBootArgs: String
    public let progress: (String, Double) -> Void

    public init(ipsw: IPSW, identity: BuildManifest.Identity, device: DeviceInfo, workDirectory: URL,
                externalAssets: [String: URL], bootMode: BootMode, memoryMB: Int, cpuCount: Int,
                verboseBoot: Bool = true, translationCacheMB: Int = QEMURunner.defaultTranslationCacheMB,
                extraBootArgs: String = "",
                progress: @escaping (String, Double) -> Void = { _, _ in }) {
        self.ipsw = ipsw; self.identity = identity; self.device = device; self.workDirectory = workDirectory
        self.externalAssets = externalAssets; self.bootMode = bootMode; self.memoryMB = memoryMB
        self.cpuCount = cpuCount; self.verboseBoot = verboseBoot; self.translationCacheMB = translationCacheMB
        self.extraBootArgs = extraBootArgs
        self.progress = progress
    }
}

public enum BackendError: Error, CustomStringConvertible {
    case missingAsset(ExternalAsset)
    case incompatible(String)
    case diskCreation(String)

    public var description: String {
        switch self {
        case .missingAsset(let a): return "Missing required file: \(a.title). \(a.help)"
        case .incompatible(let s): return s
        case .diskCreation(let s): return "Could not create virtual disk: \(s)"
        }
    }
}

/// A machine model capable of running some subset of Apple firmware.
public protocol EmulatorBackend {
    var id: String { get }
    var displayName: String { get }
    /// QEMU fork this backend is built from (shown to the user and used by the build script).
    var upstream: String { get }
    var externalAssets: [ExternalAsset] { get }
    var defaultMemoryMB: Int { get }
    /// RAM the machine model accepts; QEMU exits on anything else, which on iOS ends the app.
    var memoryRangeMB: ClosedRange<Int> { get }
    var defaultCPUCount: Int { get }

    /// Judged from the release alone, so firmwares can be ranked before they are downloaded.
    func compatibility(device: DeviceInfo, version: String, build: String) -> Compatibility
    func prepare(_ ctx: PrepareContext) throws -> MachineConfiguration
}

extension EmulatorBackend {
    public var memoryRangeMB: ClosedRange<Int> { 512...8192 }

    public func compatibility(device: DeviceInfo, ipsw: IPSW) -> Compatibility {
        compatibility(device: device, version: ipsw.version, build: ipsw.build)
    }

    func requireAsset(_ id: String, in ctx: PrepareContext) throws -> URL {
        guard let asset = externalAssets.first(where: { $0.id == id }) else {
            preconditionFailure("unknown asset \(id)")
        }
        guard let url = ctx.externalAssets[id], FileManager.default.fileExists(atPath: url.path) else {
            throw BackendError.missingAsset(asset)
        }
        return url
    }

    /// Creates a sparse zero-filled raw disk image if it does not already exist.
    func ensureDisk(_ url: URL, sizeBytes: UInt64) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return }
        guard fm.createFile(atPath: url.path, contents: nil) else { throw BackendError.diskCreation(url.path) }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.truncate(atOffset: sizeBytes)
    }
}
