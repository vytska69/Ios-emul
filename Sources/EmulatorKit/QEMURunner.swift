import Foundation

/// Starts QEMU for a prepared machine.
///
/// - On macOS QEMU runs as a child process (`qemu-system-*` on `PATH` or bundled next to the app).
/// - On iOS processes cannot be spawned, so QEMU is built as a framework (see `scripts/build-qemu-ios.sh`)
///   and its `qemu_init` / `qemu_main_loop` entry points are called on a dedicated thread, the same
///   approach UTM uses. QEMU keeps global state, so only one machine can run per app launch.
public final class QEMURunner {
    public enum State: Equatable {
        case idle, running, stopped(Int32), failed(String)
    }

    public enum RunnerError: Error, CustomStringConvertible {
        case binaryNotFound(String)
        case symbolMissing(String)
        case alreadyUsed
        case jitUnavailable
        case missingData(String)

        public var description: String {
            switch self {
            case .binaryNotFound(let b): return "QEMU binary/framework not found: \(b)"
            case .symbolMissing(let s): return "QEMU framework does not export \(s)"
            case .alreadyUsed: return "QEMU already ran in this process; relaunch the app to start another machine"
            case .missingData(let what):
                return "This build of the app is missing QEMU's \(what), and QEMU would exit at start-up. Install a newer build."
            case .jitUnavailable:
                return "JIT is not enabled for this app, and iOS closes an app that runs the emulator without it. "
                    + "Tap Enable JIT with StikDebug below (or in Settings → Emulator), or in TrollStore use "
                    + "\"Open with JIT\". Then boot again. "
                    + "Or choose Interpreter under Settings → Emulator → Engine (slower, no JIT needed)."
            }
        }
    }

    public let configuration: MachineConfiguration
    public private(set) var state: State = .idle { didSet { onStateChange?(state) } }
    public var onStateChange: ((State) -> Void)?

    #if os(macOS)
    private var process: Process?
    #endif

    public init(configuration: MachineConfiguration) {
        self.configuration = configuration
    }

    /// Present while a machine runs in this app's process. QEMU ends the whole process on fatal
    /// errors (`exit`, `abort`), so finding it at the next launch means the last run ended that way.
    public static let runningMarker = "qemu.running"

    /// Default TCG translation cache for in-process runs on iOS (`-accel tcg,tb-size=`); the app's
    /// settings can change it per boot (PrepareContext.translationCacheMB).
    /// Booting iOS translates more code than a small cache holds: QEMU then flushes the whole cache
    /// and translates everything again. In 15 minutes of an iOS 14 CI boot that happened 29 times
    /// with 256 MB and 6 times with 512 MB.
    public static let defaultTranslationCacheMB = 1024

    /// Memory an in-process VM needs besides guest RAM: the translation cache plus QEMU's own
    /// allocations (device models, display buffers, block caches).
    public static func requiredMemoryMB(guestMB: Int, translationCacheMB: Int = defaultTranslationCacheMB) -> Int {
        guestMB + translationCacheMB + 384
    }

    /// What QEMU printed during the last in-process run in `directory`, if that run ended the app;
    /// clears the marker so it is reported once.
    public static func unexpectedExit(in directory: URL) -> String? {
        let fm = FileManager.default
        let marker = directory.appendingPathComponent(runningMarker)
        guard fm.fileExists(atPath: marker.path) else { return nil }
        try? fm.removeItem(at: marker)
        let log = (try? String(contentsOf: directory.appendingPathComponent("qemu.log"), encoding: .utf8)) ?? ""
        let tail = log.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n")
        return tail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func start() throws {
        #if os(macOS)
        try startProcess()
        #else
        try startInProcess()
        #endif
    }

    public func stop() {
        #if os(macOS)
        process?.terminate()
        #else
        // Ask QEMU to quit through its monitor; there is no safe way to kill an in-process VM.
        QEMUMonitor(port: configuration.monitorPort).send("quit")
        #endif
    }

    #if os(macOS)
    private func startProcess() throws {
        guard let binary = Self.locate(configuration.qemuBinary) else {
            throw RunnerError.binaryNotFound(configuration.qemuBinary)
        }
        let p = Process()
        p.executableURL = binary
        p.arguments = configuration.arguments
        p.currentDirectoryURL = configuration.workingDirectory
        let log = configuration.workingDirectory.appendingPathComponent("qemu.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let out = try FileHandle(forWritingTo: log)
        p.standardOutput = out
        p.standardError = out
        p.terminationHandler = { [weak self] proc in
            try? out.close()
            DispatchQueue.main.async { self?.state = .stopped(proc.terminationStatus) }
        }
        try p.run()
        process = p
        state = .running
    }

    static func locate(_ name: String) -> URL? {
        let fm = FileManager.default
        var dirs = [Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS").path]
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { fm.isExecutableFile(atPath: $0.path) }
    }
    #else
    private static var used = false

    private typealias InitFn = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
    private typealias LoopFn = @convention(c) () -> Int32
    private typealias CleanupFn = @convention(c) (Int32) -> Void

    /// How guest code is run. The IPA carries QEMU twice: the JIT build (fast, needs JIT enabled
    /// for the app) and the TCG interpreter (several times slower, runs anywhere) as
    /// qemu-aarch64-softmmu-tci.framework.
    public enum Engine: String, CaseIterable {
        /// JIT when this process may run generated code, otherwise the interpreter.
        case automatic, jit, interpreter
    }

    /// Set by the app from its settings before a machine is prepared.
    public static var preferredEngine = Engine.automatic

    private static func bundled(_ framework: String) -> Bool {
        guard let dir = Bundle.main.privateFrameworksURL else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(framework).framework/\(framework)").path)
    }
    /// Older single-engine interpreter builds were marked with this Info.plist key.
    private static var interpreterOnly: Bool {
        Bundle.main.object(forInfoDictionaryKey: "IOSEmulQEMUInterpreter") as? Bool ?? false
    }
    public static var interpreterBundled: Bool { interpreterOnly || bundled("qemu-aarch64-softmmu-tci") }
    public static var jitBundled: Bool { !interpreterOnly && bundled("qemu-aarch64-softmmu") }

    /// The engine the next machine runs on: .jit or .interpreter.
    public static var activeEngine: Engine {
        switch preferredEngine {
        case .jit: return jitBundled || !interpreterBundled ? .jit : .interpreter
        case .interpreter: return interpreterBundled ? .interpreter : .jit
        case .automatic: return (jitAvailable && jitBundled) || !interpreterBundled ? .jit : .interpreter
        }
    }

    public static var needsJIT: Bool { activeEngine == .jit }

    /// Whether a debugger is attached right now (P_TRACED). StikDebug's iOS 26+ (TXM) script stays
    /// attached after launch until the app has asked it for its JIT memory.
    public static var debuggerAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
        return info.kp_proc.p_flag & P_TRACED != 0
    }

    /// Size of the JIT region prepared at launch (0: none), which machines then use as their
    /// translation cache.
    public private(set) static var preparedJITMB = 0

    /// On devices with TXM (iOS 26+ on A15 and later) the process cannot make memory executable
    /// itself even with JIT enabled; StikDebug maps it when asked through `brk #0xf00d`, which
    /// qemu/patches/inferno/0016 implements. Call this right after launch, while the debugger is
    /// still attached; without one it does nothing.
    public static func prepareJITAtLaunch(megabytes: Int) {
        guard preparedJITMB == 0, jitBundled, jitAvailable, debuggerAttached,
              let dir = Bundle.main.privateFrameworksURL else { return }
        let name = "qemu-aarch64-softmmu"
        guard let handle = dlopen(dir.appendingPathComponent("\(name).framework/\(name)").path, RTLD_NOW | RTLD_LOCAL),
              let sym = dlsym(handle, "qemu_ios_jit_prepare") else { return }
        typealias PrepareFn = @convention(c) (Int) -> Int32
        let prepare = unsafeBitCast(sym, to: PrepareFn.self)
        if prepare(megabytes << 20) == 0 { preparedJITMB = megabytes }
    }

    /// Whether this process may run generated code: on iOS that needs a debugger to have attached
    /// (CS_DEBUGGED), which is what SideStore's JIT enablers and TrollStore's "Open with JIT" do.
    public static var jitAvailable: Bool {
        var flags: UInt32 = 0
        guard csops(getpid(), 0 /* CS_OPS_STATUS */, &flags, MemoryLayout<UInt32>.size) == 0 else { return false }
        return flags & 0x1000_0000 /* CS_DEBUGGED */ != 0
    }

    private func startInProcess() throws {
        guard !Self.used else { throw RunnerError.alreadyUsed }
        // Without JIT the first translated block kills the app before QEMU can report anything.
        if Self.needsJIT && !Self.jitAvailable { throw RunnerError.jitUnavailable }
        // qemu-system-aarch64 → qemu-aarch64-softmmu.framework
        let target = configuration.qemuBinary.replacingOccurrences(of: "qemu-system-", with: "")
        var name = "qemu-\(target)-softmmu"
        if Self.activeEngine == .interpreter && !Self.interpreterOnly { name += "-tci" }
        let path = Bundle.main.privateFrameworksURL!.appendingPathComponent("\(name).framework/\(name)").path
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw RunnerError.binaryNotFound(String(cString: dlerror()))
        }
        func sym<T>(_ s: String, _: T.Type) throws -> T {
            guard let p = dlsym(handle, s) else { throw RunnerError.symbolMissing(s) }
            return unsafeBitCast(p, to: T.self)
        }
        let qemuInit = try sym("qemu_init", InitFn.self)
        let qemuLoop = try sym("qemu_main_loop", LoopFn.self)
        let qemuCleanup = try sym("qemu_cleanup", CleanupFn.self)

        // QEMU's data files (VNC keymaps, firmware blobs) ship in the app as a QEMUData folder.
        var dataArgs: [String] = []
        if let data = Bundle.main.url(forResource: "QEMUData", withExtension: nil) {
            dataArgs = ["-L", data.path]
        }
        // The VNC server loads the en-us keymap at start-up and exits QEMU (and so the app) without it.
        let keymap = Bundle.main.url(forResource: "QEMUData", withExtension: nil)?.appendingPathComponent("keymaps/en-us")
        if configuration.arguments.contains("-vnc"),
           keymap.map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
            throw RunnerError.missingData("VNC keyboard layouts (QEMUData/keymaps)")
        }
        Self.used = true
        let argv = [configuration.qemuBinary] + dataArgs + configuration.arguments
        let cwd = configuration.workingDirectory.path

        // QEMU reports errors on stdout/stderr, which an app does not show; keep them in qemu.log
        // next to the machine, and mark the run so a fatal exit can be explained on the next launch.
        let logPath = configuration.workingDirectory.appendingPathComponent("qemu.log").path
        let log = open(logPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if log >= 0 {
            dup2(log, STDOUT_FILENO)
            dup2(log, STDERR_FILENO)
            close(log)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        let marker = configuration.workingDirectory.appendingPathComponent(Self.runningMarker)
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        let thread = Thread { [weak self] in
            FileManager.default.changeCurrentDirectoryPath(cwd)
            var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
            let status: Int32 = cargs.withUnsafeMutableBufferPointer { buf in
                qemuInit(Int32(argv.count), buf.baseAddress)
                let s = qemuLoop()
                qemuCleanup(s)
                return s
            }
            cargs.forEach { free($0) }
            try? FileManager.default.removeItem(at: marker)
            DispatchQueue.main.async { self?.state = .stopped(status) }
        }
        thread.name = "qemu-main"
        thread.stackSize = 8 << 20
        thread.start()
        state = .running
    }
    #endif
}

/// Fire-and-forget access to the QEMU human monitor over TCP.
public struct QEMUMonitor {
    public let port: UInt16

    public init(port: UInt16) { self.port = port }

    public func send(_ command: String) {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("127.0.0.1", String(port), &hints, &res) == 0, let ai = res else { return }
        defer { freeaddrinfo(res) }
        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else { return }
        let line = command + "\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
    }

    /// Runs a monitor command and returns what QEMU printed, read until it goes quiet for `idleSeconds`.
    public func query(_ command: String, idleSeconds: Int = 1) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("127.0.0.1", String(port), &hints, &res) == 0, let ai = res else { return nil }
        defer { freeaddrinfo(res) }
        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else { return nil }
        var timeout = timeval()
        timeout.tv_sec = idleSeconds
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        func drain() -> Data {
            var out = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 { break }
                out.append(contentsOf: buffer[0..<n])
            }
            return out
        }
        _ = drain()                                     // banner and telnet negotiation
        let line = command + "\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
        // Telnet option bytes (IAC sequences) and the echoed prompt are not part of the answer.
        let text = String(decoding: drain().filter { $0 < 0x80 }, as: UTF8.self)
        return text.replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("(qemu)") && !$0.contains("\u{1B}") }   // prompt and echoed command line
            .joined(separator: "\n")
    }
}

#if os(iOS)
@_silgen_name("csops")
private func csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32
#endif
