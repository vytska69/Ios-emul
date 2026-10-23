import SwiftUI
import EmulatorKit

@MainActor
final class DisplayModel: ObservableObject {
    @Published var frame: CGImage?
    @Published var status = "Starting QEMU…"
    @Published var vmState: QEMURunner.State = .running
    /// Display frames received in the last second (experimental frame counter).
    @Published var fps = 0
    private var framesThisSecond = 0
    private var fpsTimer: Timer?

    let runner: QEMURunner
    private var vnc: VNCClient?
    private var attempts = 0

    init(runner: QEMURunner) {
        self.runner = runner
        runner.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.vmState = state
                if case .stopped(let code) = state { self?.status = "Machine stopped (exit \(code))" }
            }
        }
        connect()
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

    /// QEMU needs a moment before its VNC server listens, so retry for ~15 s.
    private func connect() {
        let client = VNCClient(port: runner.configuration.vncPort)
        client.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .connected(let w, let h, _):
                self.status = "\(w)×\(h)"
            case .frame(let image):
                self.frame = image
                self.framesThisSecond += 1
            case .disconnected:
                guard case .running = self.vmState, self.attempts < 30 else { return }
                self.attempts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.connect() }
            }
        }
        client.connect()
        vnc = client
    }

    func touch(at point: CGPoint, in size: CGSize, pressed: Bool) {
        guard let frame, size.width > 0, size.height > 0 else { return }
        vnc?.pointer(x: Int(point.x / size.width * CGFloat(frame.width)),
                     y: Int(point.y / size.height * CGFloat(frame.height)), pressed: pressed)
    }

    func key(_ keysym: UInt32) { vnc?.key(keysym) }

    func shutdown() {
        fpsTimer?.invalidate()
        vnc?.disconnect()
        runner.stop()
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
            } else {
                VStack(spacing: 18) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.08), lineWidth: 6).frame(width: 84, height: 84)
                        ProgressView().tint(theme.accent).scaleEffect(1.4)
                    }
                    Text(display.status).font(.headline).foregroundStyle(.white)
                    Text("Kernel output goes to serial.log in the machine folder (Files app).")
                        .font(.caption).foregroundStyle(.white.opacity(0.45)).multilineTextAlignment(.center)
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
                    SerialConsole(log: display.runner.configuration.workingDirectory.appendingPathComponent("serial.log"))
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

/// Last lines of the guest's serial output, refreshed every second (experimental).
private struct SerialConsole: View {
    let log: URL
    @State private var text = ""
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "(no serial output yet)" : text)
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
        .onReceive(timer) { _ in text = Self.tail(of: log) }
        .onAppear { text = Self.tail(of: log) }
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
