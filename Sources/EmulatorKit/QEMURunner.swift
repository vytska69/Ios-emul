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

        public var description: String {
            switch self {
            case .binaryNotFound(let b): return "QEMU binary/framework not found: \(b)"
            case .symbolMissing(let s): return "QEMU framework does not export \(s)"
            case .alreadyUsed: return "QEMU already ran in this process; relaunch the app to start another machine"
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

    private func startInProcess() throws {
        guard !Self.used else { throw RunnerError.alreadyUsed }
        // qemu-system-aarch64 → qemu-aarch64-softmmu.framework
        let target = configuration.qemuBinary.replacingOccurrences(of: "qemu-system-", with: "")
        let name = "qemu-\(target)-softmmu"
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
        Self.used = true

        // QEMU's data files (VNC keymaps, firmware blobs) ship in the app as a QEMUData folder.
        var dataArgs: [String] = []
        if let data = Bundle.main.url(forResource: "QEMUData", withExtension: nil) {
            dataArgs = ["-L", data.path]
        }
        let argv = [configuration.qemuBinary] + dataArgs + configuration.arguments
        let cwd = configuration.workingDirectory.path
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
}
