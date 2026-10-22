import Foundation
import IPSWKit

/// Result of matching one firmware against every known backend.
public struct CompatibilityReport {
    public struct Row {
        public let device: DeviceInfo
        public let backend: EmulatorBackend?
        public let compatibility: Compatibility
    }

    public let rows: [Row]

    /// The best runnable (device, backend) pair, preferring fully supported ones.
    public var best: Row? {
        rows.first { $0.compatibility == .supported } ?? rows.first { $0.compatibility.isRunnable }
    }
}

public final class BackendRegistry {
    public static let shared = BackendRegistry(backends: [
        InfernoBackend(machine: .t8030), InfernoBackend(machine: .s8000), IPodTouchBackend(),
    ])

    public private(set) var backends: [EmulatorBackend]

    public init(backends: [EmulatorBackend]) { self.backends = backends }

    public func register(_ backend: EmulatorBackend) { backends.append(backend) }

    public func backend(id: String) -> EmulatorBackend? { backends.first { $0.id == id } }

    public func report(for ipsw: IPSW) -> CompatibilityReport {
        var rows: [CompatibilityReport.Row] = []
        for device in ipsw.devices {
            let results = backends.map { ($0, $0.compatibility(device: device, ipsw: ipsw)) }
            if let hit = results.first(where: { $0.1 == .supported }) ?? results.first(where: { $0.1.isRunnable }) {
                rows.append(.init(device: device, backend: hit.0, compatibility: hit.1))
            } else {
                rows.append(.init(device: device, backend: nil,
                                  compatibility: .unsupported(Self.reason(for: device))))
            }
        }
        return CompatibilityReport(rows: rows)
    }

    /// Explains why nothing can run a device, so the user sees what is missing rather than a bare "no".
    static func reason(for device: DeviceInfo) -> String {
        guard let soc = device.soc else {
            return "unknown product type \(device.productType)"
        }
        return "no QEMU machine model exists yet for \(soc.marketingName) (\(soc.id)); "
            + "a backend needs the SoC's interrupt controller, timers, PMGR, SEP and display pipeline emulated"
    }
}
