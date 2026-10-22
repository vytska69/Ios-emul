import Foundation

/// Stages of an XNU boot recognisable from the serial console, in the order they happen.
/// Used by the boot-test harness to measure how far each firmware gets.
public enum BootMilestone: Int, CaseIterable, Comparable {
    case kernel = 1
    case iokit
    case rootMounted
    case launchd
    case restoreDaemon
    case userInterface

    public var title: String {
        switch self {
        case .kernel: return "XNU started"
        case .iokit: return "IOKit matching drivers"
        case .rootMounted: return "root filesystem mounted"
        case .launchd: return "launchd running"
        case .restoreDaemon: return "restore daemon waiting for host"
        case .userInterface: return "SpringBoard / backboardd"
        }
    }

    /// Substrings XNU and early userspace print when a stage is reached.
    var markers: [String] {
        switch self {
        case .kernel: return ["Darwin Kernel Version", "@(#)VERSION:"]
        case .iokit: return ["IOKit Component Version", "IOPlatformExpert", "AppleARMPE"]
        case .rootMounted: return ["BSD root:", "root on disk", "rooting from"]
        case .launchd: return ["launchd[1]", "/sbin/launchd", "com.apple.xpc.launchd"]
        case .restoreDaemon: return ["restored_external", "waiting for host to trigger", "RestoreDaemon"]
        case .userInterface: return ["SpringBoard", "backboardd"]
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public static func furthest(in log: String) -> BootMilestone? {
        allCases.last { stage in stage.markers.contains { log.contains($0) } }
    }

    /// The first kernel panic line, if the boot ended in one.
    public static func panic(in log: String) -> String? {
        log.split(separator: "\n").first { $0.contains("panic(cpu") }.map(String.init)
    }
}
