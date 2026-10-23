import Foundation
import IPSWKit
import EmulatorKit

// Command-line front end used by the CI boot-test harness (and handy on a Mac):
//
//   ipsw-emu inspect <file.ipsw>
//   ipsw-emu dt <file.ipsw> [--product iPhone11,8] --path /filesystems/fstab
//   ipsw-emu boot <file.ipsw> --work <dir> [--product iPhone12,1] [--seconds 600]
//                 [--monitor "x /32wx 0xfffffff007000000; info mtree -f"]  (run at the time limit)
//                 [--memory 4096] [--cpus 4] [--mode auto] [--asset id=path ...]
//                 [--force-backend inferno-t8030] [--qemu-debug guest_errors]
//   ipsw-emu apfs-add-volume <disk image> [--offset 0] [--name Preboot] [--role preboot|data|xart]
//                            [--dirs a/b,c] [--files a/f=text] [--owners a/b=501:501:755]
//
// --force-backend runs a firmware on a machine its compatibility check rejects. That is how a new
// SoC is brought up: boot it on the closest existing model and fix whatever it trips over first.
//
// `boot` prepares the machine exactly like the app, runs QEMU for at most --seconds, then prints
// the tail of the serial log and the furthest boot milestone reached.

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: ipsw-emu inspect|boot <file.ipsw> [options]") }
args.removeFirst()
guard let path = args.first else { fail("missing IPSW path") }
args.removeFirst()

var options: [String: String] = [:]
var assets: [String: URL] = [:]
while !args.isEmpty {
    let key = args.removeFirst()
    guard key.hasPrefix("--"), !args.isEmpty else { fail("bad option \(key)") }
    let value = args.removeFirst()
    if key == "--asset" {
        let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { fail("--asset expects id=path") }
        assets[parts[0]] = URL(fileURLWithPath: parts[1])
    } else {
        options[String(key.dropFirst(2))] = value
    }
}

// Adds a Preboot volume to a raw APFS container, the step direct installs use instead of a
// restore. CI runs it on a fresh macOS-made image and checks the result with fsck_apfs.
if command == "apfs-dump" {
    do {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        let container = try APFSContainer(handle: handle, offset: UInt64(options["offset"] ?? "0") ?? 0)
        try container.dump().forEach { print($0) }
    } catch { fail("\(error)") }
    exit(0)
}
if command == "apfs-add-volume" {
    do {
        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let container = try APFSContainer(handle: handle, offset: UInt64(options["offset"] ?? "0") ?? 0)
        print("roles before: \(try container.roles().map { String(format: "0x%x", $0) })")
        let dirs = (options["dirs"] ?? "usr/standalone/firmware").split(separator: ",").map(String.init)
        // --files "a/b.txt=hello,c.bin=" writes small text files.
        var files: [String: Data] = [:]
        for spec in (options["files"] ?? "").split(separator: ",") {
            let parts = spec.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            files[String(parts[0])] = Data((parts.count > 1 ? String(parts[1]) : "").utf8)
        }
        // --owners "a/b=501:501:755" sets owner, group and octal permissions.
        var attributes: [String: APFSContainer.Attributes] = [:]
        for spec in (options["owners"] ?? "").split(separator: ",") {
            let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
            let ids = parts.count == 2 ? parts[1].split(separator: ":").map(String.init) : []
            guard ids.count == 3, let uid = UInt32(ids[0]), let gid = UInt32(ids[1]), let mode = UInt16(ids[2], radix: 8) else {
                fail("--owners expects path=uid:gid:mode")
            }
            attributes[parts[0]] = APFSContainer.Attributes(uid: uid, gid: gid, mode: mode)
        }
        let roles: [String: APFSContainer.Role] = ["preboot": .preboot, "data": .data, "xart": .xart]
        guard let role = roles[options["role"] ?? "preboot"] else { fail("--role expects preboot, data or xart") }
        try container.addVolume(name: options["name"] ?? "Preboot", role: role,
                                tree: APFSContainer.Tree(directories: dirs, files: files, attributes: attributes))
        print("roles after: \(try container.roles().map { String(format: "0x%x", $0) })")
    } catch { fail("\(error)") }
    exit(0)
}

let ipsw: IPSW
do { ipsw = try IPSW(url: URL(fileURLWithPath: path)) } catch { fail("\(error)") }
let report = BackendRegistry.shared.report(for: ipsw)

switch command {
case "inspect":
    print("iOS \(ipsw.version) (\(ipsw.build)), image format \(ipsw.imageFormat)")
    for row in report.rows {
        print("  \(row.device.productType) \(row.device.name) [\(row.device.soc?.id ?? "?")]: "
              + "\(row.backend?.id ?? "-") — \(row.compatibility.summary)")
    }
    if let identity = ipsw.manifest.identity(), let tree = try? ipsw.deviceTree(identity: identity) {
        for c in HardwareCoverage.analyze(tree) {
            print(String(format: "  coverage vs %@: %d/%d (%.0f%%), missing boot-critical: %@", c.machine,
                         c.emulatedCount, c.peripherals.count, c.fraction * 100,
                         c.missingBootCritical.map(\.name).joined(separator: ",")))
        }
    }

case "boot":
    let rows = report.rows.filter { options["product"] == nil || $0.device.productType == options["product"] }
    let row: CompatibilityReport.Row
    let backend: EmulatorBackend
    if let forced = options["force-backend"] {
        guard let b = BackendRegistry.shared.backend(id: forced) else { fail("unknown backend \(forced)") }
        guard let first = rows.first else { fail("product not in this IPSW") }
        row = CompatibilityReport.Row(device: first.device, backend: b,
                                      compatibility: .experimental("forced onto \(forced)"))
        backend = b
    } else {
        guard let r = rows.first(where: { $0.compatibility.isRunnable }), let b = r.backend else {
            fail("no runnable backend: " + rows.map { "\($0.device.productType): \($0.compatibility.summary)" }
                .joined(separator: "; "))
        }
        row = r
        backend = b
    }
    guard let identity = ipsw.identity(forProduct: row.device.productType) else { fail("no build identity") }

    let work = URL(fileURLWithPath: options["work"] ?? "vm")
    let ctx = PrepareContext(
        ipsw: ipsw, identity: identity, device: row.device, workDirectory: work, externalAssets: assets,
        bootMode: BootMode(rawValue: options["mode"] ?? "auto") ?? .auto,
        memoryMB: Int(options["memory"] ?? "") ?? backend.defaultMemoryMB,
        cpuCount: Int(options["cpus"] ?? "") ?? backend.defaultCPUCount)
    print("==> \(row.device.name) iOS \(ipsw.version) on \(backend.displayName) [\(row.compatibility.summary)]")

    var config: MachineConfiguration
    do { config = try backend.prepare(ctx) } catch { fail("prepare: \(error)") }
    // QEMU's own debug log, e.g. --qemu-debug guest_errors,unimp: the simulated SEP reports every
    // message the guest sends it there, which is what SEP bring-up works from.
    let debugLog = work.appendingPathComponent("qemu-debug.log")
    if let flags = options["qemu-debug"], !flags.isEmpty {
        config.arguments += ["-d", flags, "-D", debugLog.path]
    }
    print("==> qemu \(config.arguments.joined(separator: " "))")

    let runner = QEMURunner(configuration: config)
    let done = DispatchSemaphore(value: 0)
    runner.onStateChange = { state in
        if case .running = state { return }
        print("==> QEMU state: \(state)")
        done.signal()
    }
    do { try runner.start() } catch { fail("start: \(error)") }

    let seconds = Double(options["seconds"] ?? "") ?? 600
    let deadline = Date().addingTimeInterval(seconds)
    // The termination handler hops to the main queue, so keep the main run loop turning.
    while Date() < deadline && done.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(1))
    }
    if Date() >= deadline {
        print("==> time limit reached, stopping")
        // A boot that hangs without printing anything is found by where its CPUs are spinning.
        let monitor = QEMUMonitor(port: runner.configuration.monitorPort)
        if let regs = monitor.query("info registers -a") {
            print("==> CPU state at the time limit:")
            regs.split(separator: "\n").prefix(400).forEach { print("  | \($0)") }
            // The code CPU0 is spinning in (virtual addresses, so x rather than xp). Raw words: this
            // QEMU has no disassembler, /i trips an assertion; llvm-mc decodes them.
            if let field = regs.split(whereSeparator: { $0 == " " || $0 == "\n" }).first(where: { $0.hasPrefix("PC=") }),
               let pc = UInt64(field.dropFirst(3), radix: 16), pc >= 0x80,
               let code = monitor.query(String(format: "x /64wx 0x%llx", pc - 0x80)) {
                print("==> code around CPU0 PC 0x\(String(pc, radix: 16)):")
                code.split(separator: "\n").prefix(40).forEach { print("  | \($0)") }
            }
        }
        // Extra monitor commands from --monitor "cmd; cmd" (e.g. x /32wx at an exception's ELR).
        for command in (options["monitor"] ?? "").split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) })
            where !command.isEmpty {
            if let out = monitor.query(command, idleSeconds: 2) {
                print("==> \(command):")
                out.split(separator: "\n").prefix(80).forEach { print("  | \($0)") }
            }
        }
        // What the kernel's first instructions are in guest memory (Inferno logs the entry point).
        let qemuLog = (try? String(contentsOf: work.appendingPathComponent("qemu.log"), encoding: .utf8)) ?? ""
        if let line = qemuLog.split(separator: "\n").first(where: { $0.contains("Kernel Entry Point:") }),
           let entry = line.split(separator: " ").last {
            // (xp /i is not supported for physical addresses and trips an assertion in QEMU.)
            for command in ["xp /16wx \(entry)"] {
                if let out = monitor.query(command) {
                    print("==> \(command):")
                    out.split(separator: "\n").prefix(40).forEach { print("  | \($0)") }
                }
            }
            // Which memory regions cover the entry point: a device window mapped over DRAM reads
            // back as 0xffffffff instead of the kernel.
            if let address = UInt64(entry.dropFirst(2), radix: 16),
               let tree = monitor.query("info mtree -f", idleSeconds: 2) {
                let covering = tree.split(separator: "\n").filter { line in
                    let range = line.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? ""
                    let ends = range.split(separator: "-").compactMap { UInt64($0, radix: 16) }
                    return ends.count == 2 && ends[0] <= address && address <= ends[1]
                }
                print("==> memory regions at \(entry):")
                covering.prefix(40).forEach { print("  | \($0)") }
            }
        }
        runner.stop()
    }

    let serial = (try? String(contentsOf: work.appendingPathComponent("serial.log"), encoding: .utf8)) ?? ""
    let milestone = BootMilestone.furthest(in: serial)
    print("==> milestone: \(milestone.map { "\($0.rawValue) — \($0.title)" } ?? "none")")
    if let panic = BootMilestone.panic(in: serial) { print("==> panic: \(panic)") }
    // The lines that say why a boot stopped, wherever they are in a log that may span reboots.
    let keyPatterns = ["panic(", "Still waiting for root device", "BSD root", "rooting", "apfs", "APFS",
                       "mount", "Mount", "AppleNVMe", "disk0", "launchd", "SpringBoard", "backboardd",
                       "restored_external", "CHECKPOINT", "Kernel version", "cannot find", "failed"]
    let keyLines = serial.split(separator: "\n").filter { line in keyPatterns.contains { line.contains($0) } }
    print("==> key serial lines (\(keyLines.count)):")
    keyLines.prefix(120).forEach { print("  | \($0)") }
    print("==> serial tail:")
    serial.split(separator: "\n", omittingEmptySubsequences: false).suffix(60).forEach { print($0) }
    // QEMU's own errors (bad options, missing files, machine init failures) go to qemu.log.
    if let qemuLog = try? String(contentsOf: work.appendingPathComponent("qemu.log"), encoding: .utf8),
       !qemuLog.isEmpty {
        print("==> qemu log tail:")
        qemuLog.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).forEach { print($0) }
    }

    if options["qemu-debug"] != nil {
        let size = (try? FileManager.default.attributesOfItem(atPath: debugLog.path)[.size] as? Int) ?? -1
        print("==> qemu debug log: \(size) bytes")
    }
    // -d int can write gigabytes once a guest loops on exceptions; the start is what matters.
    if let file = try? FileHandle(forReadingFrom: debugLog), let data = try? file.read(upToCount: 64 << 20),
       !data.isEmpty {
        let debug = String(decoding: data, as: UTF8.self)
        print("==> qemu debug log head:")
        debug.split(separator: "\n").prefix(40).forEach { print("  | \($0)") }
        let sep = debug.split(separator: "\n").filter { line in
            ["SEP", "EP_", "KeyStore", "XART", "sks", "Keystore"].contains { line.contains($0) }
        }
        print("==> SEP messages (\(sep.count)):")
        sep.prefix(300).forEach { print("  | \($0)") }
    }
    // With -d exec / in_asm, what ran just before the first exception (streamed: the log can be huge).
    if let file = try? FileHandle(forReadingFrom: debugLog) {
        var window: [Substring] = []
        var pending = Data()
        var found = false
        scan: while let chunk = try? file.read(upToCount: 8 << 20), !chunk.isEmpty {
            pending.append(chunk)
            guard let cut = pending.lastIndex(of: UInt8(ascii: "\n")) else { continue }
            let text = String(decoding: pending[..<cut], as: UTF8.self)
            pending = Data(pending[pending.index(after: cut)...])
            for line in text.split(separator: "\n") {
                if line.hasPrefix("Taking exception") { found = true; break scan }
                window.append(line)
                if window.count > 120 { window.removeFirst(window.count - 120) }
            }
        }
        if found, !window.isEmpty {
            print("==> last debug log lines before the first exception:")
            window.forEach { print("  | \($0)") }
        }
    }

case "dt":
    guard let identity = ipsw.identity(forProduct: options["product"]) else { fail("no build identity") }
    let tree: DeviceTreeNode
    do { tree = try ipsw.deviceTree(identity: identity) } catch { fail("\(error)") }
    let path = options["path"] ?? "/"
    guard let node = path == "/" ? tree : tree.node(at: String(path.drop { $0 == "/" })) else {
        fail("no node \(path)")
    }
    DeviceTree.describe(node).forEach { print($0) }

default:
    fail("unknown command \(command)")
}
