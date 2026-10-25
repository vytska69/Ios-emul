import SwiftUI
import EmulatorKit

@MainActor
final class DisplayModel: ObservableObject {
    @Published var frame: CGImage?
    @Published var status = "Starting QEMU…"
    /// Where the emulated CPU 0 is, sampled every few seconds while the display is not up, so a
    /// guest that is running can be told apart from one that is stuck (e.g. "0xfffffff007a1b2c4 · moving").
    @Published var cpuTrace: String?
    private var lastPC: String?
    @Published var vmState: QEMURunner.State = .running
    /// Display frames received in the last second (experimental frame counter).
    @Published var fps = 0
    /// How far the boot has got, read from the kernel's serial output, until the screen shows
    /// something: after the display connects it stays black for minutes while iOS starts.
    @Published var milestone: BootMilestone?
    @Published var milestoneSince = Date()
    @Published var panicLine: String?
    @Published var screenLit = false
    private var serialOffset: UInt64 = 0
    private var serialCarry = ""
    private var scanning = false
    private var framesThisSecond = 0
    private var fpsTimer: Timer?
    private var waitTimer: Timer?

    let runner: QEMURunner
    private var vnc: VNCClient?
    private var connected = false
    /// QEMU answers its monitor only once machine creation (loading and patching the kernel,
    /// building the device tree) is done and the main loop runs; until then it prints nothing.
    @Published private(set) var machineBuilt = false
    private var checking = false
    let started = Date()

    init(runner: QEMURunner) {
        self.runner = runner
        runner.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.vmState = state
                if case .stopped(let code) = state {
                    self?.status = "Machine stopped (exit \(code))"
                    BackgroundRunner.shared.stop()
                }
            }
        }
        connect()
        if Pref.defaults.bool(forKey: Pref.runInBackground) { BackgroundRunner.shared.start() }
        waitTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.screenLit, case .running = self.vmState else { return }
                let seconds = Int(Date().timeIntervalSince(self.started))
                if !self.connected {
                    self.status = self.machineBuilt
                        ? "Machine running, waiting for the display · \(seconds) s"
                        : "Building the machine · \(seconds) s"
                }
                if let frame = self.frame, Self.isLit(frame) { self.screenLit = true }
                if seconds % 3 == 0 {
                    self.checkMachine()
                    self.scanSerial()
                }
            }
        }
        if Pref.experimentalBool(Pref.fpsCounter) {
            fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.fps = self.framesThisSecond
                    self.framesThisSecond = 0
                }
            }
        }
    }

    /// QEMU opens its VNC server only once the machine is built (kernel loaded and patched), which
    /// on a phone can take well over a minute, so keep retrying while the machine runs.
    private func connect() {
        let client = VNCClient(port: runner.configuration.vncPort)
        client.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .connected(let w, let h, _):
                self.connected = true
                self.status = "\(w)×\(h)"
            case .frame(let image):
                self.frame = image
                self.framesThisSecond += 1
            case .disconnected:
                guard case .running = self.vmState else { return }
                self.connected = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.connect() }
            }
        }
        client.connect()
        vnc = client
    }

    private func checkMachine() {
        guard !checking else { return }
        checking = true
        let monitor = QEMUMonitor(port: runner.configuration.monitorPort)
        let built = machineBuilt
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let answer = monitor.query(built ? "info registers" : "info status") ?? ""
            // "info registers" starts with CPU 0: " PC=fffffff0071c3a58 X00=..."
            let pc = answer.range(of: #"PC=[0-9a-f]+"#, options: .regularExpression).map { String(answer[$0].dropFirst(3)) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                if answer.contains("VM status") { self.machineBuilt = true }
                if let pc {
                    let moving = self.lastPC.map { $0 != pc } ?? true
                    self.cpuTrace = "CPU 0 at 0x\(pc) · " + (moving ? "running" : "not moving")
                    self.lastPC = pc
                }
            }
        }
    }

    /// Reads what the kernel printed since the last look and moves the boot milestone forward.
    private func scanSerial() {
        guard !scanning else { return }
        scanning = true
        let url = runner.configuration.workingDirectory.appendingPathComponent("serial.log")
        let start = serialOffset
        let carry = serialCarry
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var offset = start
            var text = ""
            if let handle = try? FileHandle(forReadingFrom: url) {
                let size = (try? handle.seekToEnd()) ?? 0
                if size < offset { offset = 0 }      // a new boot started the log over
                try? handle.seek(toOffset: offset)
                let data = (try? handle.read(upToCount: 4 << 20)) ?? Data()
                try? handle.close()
                offset += UInt64(data.count)
                text = String(decoding: data, as: UTF8.self)
            }
            // Markers can straddle two reads.
            let chunk = carry + text
            let reached = BootMilestone.furthest(in: chunk)
            let panic = BootMilestone.panic(in: chunk)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                self.serialOffset = offset
                self.serialCarry = String(chunk.suffix(256))
                if let reached, self.milestone.map({ reached > $0 }) ?? true {
                    self.milestone = reached
                    self.milestoneSince = Date()
                }
                if let panic, self.panicLine == nil { self.panicLine = panic }
            }
        }
    }

    /// Whether a frame shows more than a black screen (a few lit pixels do not count).
    static func isLit(_ image: CGImage) -> Bool {
        let w = 18, h = 39
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return true }
        var lit = 0
        for i in stride(from: 0, to: pixels.count, by: 4) where max(pixels[i], pixels[i + 1], pixels[i + 2]) > 24 { lit += 1 }
        return lit * 10 > w * h
    }

    func touch(at point: CGPoint, in size: CGSize, pressed: Bool) {
        guard let frame, size.width > 0, size.height > 0 else { return }
        vnc?.pointer(x: Int(point.x / size.width * CGFloat(frame.width)),
                     y: Int(point.y / size.height * CGFloat(frame.height)), pressed: pressed)
    }

    func key(_ keysym: UInt32) { vnc?.key(keysym) }

    func shutdown() {
        fpsTimer?.invalidate()
        waitTimer?.invalidate()
        vnc?.disconnect()
        runner.stop()
        BackgroundRunner.shared.stop()
    }
}

struct MachineView: View {
    @StateObject private var display: DisplayModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @AppStorage(Pref.keepAwake) private var keepAwake = true
    @State private var controlsVisible = true
    @State private var confirmStop = false
    @State private var consoleVisible = Pref.experimentalSerialConsole
    @State private var toolsVisible = false

    init(runner: QEMURunner) {
        _display = StateObject(wrappedValue: DisplayModel(runner: runner))
    }

    private var running: Bool {
        if case .running = display.vmState { return true }
        return false
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let frame = display.frame {
                let aspect = CGFloat(frame.width) / CGFloat(max(frame.height, 1))
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(aspect, contentMode: .fit)
                    .overlay(TouchSurface(display: display))
                    .accessibilityLabel("Emulated screen")
                    .accessibilityHint("Touches are sent to the emulated device")
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: theme.colors.0.opacity(0.25), radius: 30)
                    .padding(.vertical, 56)
                    // At the top, small: the boot logo sits in the middle of the screen.
                    .overlay(alignment: .top) {
                        if !display.screenLit && running {
                            BootProgress(display: display, compact: true).padding(12)
                        }
                    }
            } else {
                VStack(spacing: 18) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.08), lineWidth: 6).frame(width: 84, height: 84)
                        ProgressView().tint(theme.accent).scaleEffect(1.4)
                    }
                    Text(display.status).font(.headline).foregroundStyle(.white)
                    if let trace = display.cpuTrace {
                        Text(trace).font(.caption.monospaced()).foregroundStyle(theme.accent)
                            .textSelection(.enabled)
                    }
                    if running { BootProgress(display: display) }
                    if !consoleVisible {
                        SerialConsole(directory: display.runner.configuration.workingDirectory)
                    }
                }
                .padding(32)
            }

            VStack {
                statusPill
                Spacer()
                if toolsVisible {
                    MachineToolsPanel(display: display)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if consoleVisible {
                    SerialConsole(directory: display.runner.configuration.workingDirectory)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if controlsVisible {
                    controls.transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Button { withAnimation(.spring(response: 0.3)) { controlsVisible = true } } label: {
                        Image(systemName: "chevron.up").font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 44, height: 22)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show controls")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .statusBarHidden()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = keepAwake }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .confirmationDialog("Stop this machine?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive) {
                display.shutdown()
                dismiss()
            }
        } message: {
            Text("QEMU can run once per app launch; reopen the app to boot again.")
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle().fill(running ? Color.green : Color.orange).frame(width: 8, height: 8)
                .shadow(color: running ? .green : .orange, radius: 4)
            Text(display.status).font(.caption.weight(.semibold).monospacedDigit())
            if Pref.experimentalBool(Pref.fpsCounter) {
                Text("\(display.fps) fps").font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
    }

    private var controls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ControlButton(symbol: "circle.circle", title: "Home") { display.key(0xFF50) }
                ControlButton(symbol: "lock.fill", title: "Lock") { display.key(0xFF1B) }
                if Pref.experimentalBool(Pref.machineTools) {
                    ControlButton(symbol: "wrench.and.screwdriver", title: "Tools") {
                        withAnimation(.spring(response: 0.3)) { toolsVisible.toggle() }
                    }
                }
                if Pref.experimentalSerialConsole {
                    ControlButton(symbol: "terminal", title: "Serial") {
                        withAnimation(.spring(response: 0.3)) { consoleVisible.toggle() }
                    }
                }
                ControlButton(symbol: "eye.slash", title: "Hide") {
                    withAnimation(.spring(response: 0.3)) { controlsVisible = false }
                }
                ControlButton(symbol: "power", title: "Stop", tint: .red) {
                    if running { confirmStop = true } else { dismiss() }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
    }
}

/// The steps of a boot, ticked off as the kernel reports them, so the minutes of black screen
/// while iOS starts read as progress rather than as a machine that hangs.
private struct BootProgress: View {
    @ObservedObject var display: DisplayModel
    /// Over the emulated screen: one line with the current step; tapping it lists the steps.
    var compact = false
    @State private var expanded = false
    @Environment(\.theme) private var theme
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    private struct Step { let title: String; let hint: String; let done: Bool }

    private var steps: [Step] {
        let m = display.milestone
        func past(_ stage: BootMilestone) -> Bool { m.map { $0 >= stage } ?? false }
        return [
            Step(title: "Building the machine", hint: "Unpacking and patching the kernel; QEMU prints nothing meanwhile. Can take several minutes on a phone.",
                 done: display.machineBuilt || m != nil),
            Step(title: "Kernel started", hint: "Waiting for the kernel's first output.", done: past(.kernel)),
            Step(title: "Loading drivers", hint: "The kernel is starting the emulated hardware.", done: past(.iokit)),
            Step(title: "System disk mounted", hint: "Mounting the iOS system volume.", done: past(.rootMounted)),
            Step(title: "iOS starting", hint: "The kernel is handing over to launchd.", done: past(.launchd)),
            Step(title: "Waiting for the first screen", hint: "iOS draws its screen on the emulated processor, which is slow: after a fresh install this takes 20 minutes or more, after a restart several minutes. The machine is working; leave it running.",
                 done: display.screenLit),
        ]
    }

    private var timing: String {
        let since = display.milestone == nil ? display.started : display.milestoneSince
        return "This step \(Self.duration(now.timeIntervalSince(since))) · total \(Self.duration(now.timeIntervalSince(display.started)))"
    }

    var body: some View {
        Group {
            if compact { compactBody } else { list(hints: true) }
        }
        .onReceive(timer) { now = $0 }
    }

    private var compactBody: some View {
        let steps = self.steps
        let current = steps.firstIndex { !$0.done }
        return VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.spring(response: 0.3)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(current.map { "Step \($0 + 1) of \(steps.count): \(steps[$0].title)" } ?? "Starting")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                        Text(timing).font(.caption2.monospacedDigit()).foregroundStyle(theme.accent).lineLimit(1)
                        // Whether the guest is doing anything while the logo stays up.
                        if let trace = display.cpuTrace {
                            Text(trace).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { list(hints: false, padded: false) }
            if let panic = display.panicLine {
                Label("Kernel panic: \(panic)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: 340, alignment: .leading)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }

    @ViewBuilder
    private func list(hints: Bool, padded: Bool = true) -> some View {
        let steps = self.steps
        let current = steps.firstIndex { !$0.done }
        let content = VStack(alignment: .leading, spacing: hints ? 10 : 7) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Group {
                        if step.done {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent)
                        } else if index == current {
                            ProgressView().controlSize(.small).tint(theme.accent)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.white.opacity(0.25))
                        }
                    }
                    .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title).font((hints ? Font.subheadline : .caption).weight(index == current ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(step.done || index == current ? 1 : 0.4))
                        if index == current && hints {
                            Text(step.hint).font(.caption).foregroundStyle(.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(timing).font(.caption2.monospacedDigit()).foregroundStyle(theme.accent)
                        }
                    }
                }
            }
            if hints, let panic = display.panicLine {
                Label("The kernel panicked: \(panic)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
        }
        if padded {
            content
                .padding(16)
                .frame(maxWidth: 360, alignment: .leading)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
        } else {
            content
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s < 60 ? "\(s) s" : "\(s / 60) min \(s % 60) s"
    }
}

/// Round button in the floating control bar.
private struct ControlButton: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let title: String
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(tint ?? theme.accent)
            .frame(width: 56, height: 52)
            .background((tint ?? theme.accent).opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The kernel's serial output; until the kernel prints anything, QEMU's own log, so a machine that
/// is still being built (or failed to build) is not just a blank box.
private struct SerialConsole: View {
    let directory: URL
    @State private var text = ""
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "(no output yet)" : text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .id("end")
            }
            .onChange(of: text) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(height: 180)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .onReceive(timer) { _ in text = current() }
        .onAppear { text = current() }
    }

    private func current() -> String {
        let serial = Self.tail(of: directory.appendingPathComponent("serial.log"))
        if !serial.isEmpty { return serial }
        let qemu = Self.tail(of: directory.appendingPathComponent("qemu.log"))
        return qemu.isEmpty ? "" : "[QEMU — no kernel output yet]\n" + qemu
    }

    /// The last 6 KB of the log, starting at a line boundary.
    static func tail(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > 6144 ? size - 6144 : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return text
    }
}

/// Forwards drags/taps to the guest as absolute pointer events.
private struct TouchSurface: View {
    @ObservedObject var display: DisplayModel

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { display.touch(at: $0.location, in: geo.size, pressed: true) }
                        .onEnded { display.touch(at: $0.location, in: geo.size, pressed: false) }
                )
        }
    }
}
