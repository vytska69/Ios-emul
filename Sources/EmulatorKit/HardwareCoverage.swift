import Foundation
import IPSWKit

/// How much of a firmware's hardware, as its DeviceTree describes it, an emulated machine models.
///
/// This turns "can it boot?" into a concrete work list: every missing node is a peripheral model
/// that has to be written before XNU stops panicking on it.
public struct HardwareCoverage {
    public struct Peripheral: Hashable {
        public let path: String
        public let name: String
        public let compatible: [String]
        public let emulated: Bool
        /// XNU panics early without these, so they gate any boot attempt.
        public let bootCritical: Bool
    }

    public let machine: String
    public let peripherals: [Peripheral]

    public var emulatedCount: Int { peripherals.filter(\.emulated).count }

    public var fraction: Double {
        peripherals.isEmpty ? 0 : Double(emulatedCount) / Double(peripherals.count)
    }

    public var missingBootCritical: [Peripheral] { peripherals.filter { $0.bootCritical && !$0.emulated } }

    /// Node names (instance numbers stripped) whose absence stops XNU before userspace.
    static let bootCriticalNames: Set<String> = [
        "aic", "aic-timebase", "uart", "pmgr", "wdt", "ans", "sart-ans", "iop-ans-nub", "nvme-mmu", "sio",
        "dart-sio", "spmi", "gpio", "i2c", "aes", "sep", "dart-sep", "smc", "iop-smc-nub", "apcie",
    ]

    /// Emulated DeviceTree node names per Inferno machine (`scripts/gen-inferno-coverage.py`).
    public static let knownNodes: [String: Set<String>] = {
        struct File: Decodable { let machines: [String: [String]] }
        guard let url = Bundle.module.url(forResource: "inferno-nodes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [:] }
        return file.machines.mapValues(Set.init)
    }()

    /// Scores `tree` against every known machine and returns the best match first.
    public static func analyze(_ tree: DeviceTreeNode,
                               machines: [String: Set<String>] = knownNodes) -> [HardwareCoverage] {
        let nodes = peripheralNodes(tree)
        return machines.map { machine, known in
            HardwareCoverage(machine: machine, peripherals: nodes.map { node in
                Peripheral(path: node.path, name: node.name, compatible: node.compatible,
                           emulated: known.contains(node.name),
                           bootCritical: bootCriticalNames.contains(baseName(node.name)))
            })
        }
        .sorted { ($0.fraction, $1.machine) > ($1.fraction, $0.machine) }
    }

    /// Hardware lives under `arm-io`; a node counts if it has registers or a driver match.
    static func peripheralNodes(_ tree: DeviceTreeNode) -> [DeviceTreeNode] {
        guard let armIO = tree.child("arm-io") else { return [] }
        var out: [DeviceTreeNode] = []
        for child in armIO.children {
            child.walk { node in
                if node.properties["reg"] != nil || !node.compatible.isEmpty { out.append(node) }
            }
        }
        return out
    }

    /// "uart3" → "uart", "spmi0" → "spmi", "smc-i2c1" → "smc-i2c"
    static func baseName(_ name: String) -> String {
        String(name.reversed().drop { $0.isNumber }.reversed())
    }
}
