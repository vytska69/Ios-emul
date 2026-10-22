import SwiftUI
import EmulatorKit

@MainActor
final class DisplayModel: ObservableObject {
    @Published var frame: CGImage?
    @Published var status = "Starting QEMU…"
    @Published var vmState: QEMURunner.State = .running

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
        vnc?.disconnect()
        runner.stop()
    }
}

struct MachineView: View {
    @StateObject private var display: DisplayModel
    @Environment(\.dismiss) private var dismiss

    init(runner: QEMURunner) {
        _display = StateObject(wrappedValue: DisplayModel(runner: runner))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let frame = display.frame {
                    let aspect = CGFloat(frame.width) / CGFloat(max(frame.height, 1))
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(aspect, contentMode: .fit)
                        .overlay(TouchSurface(display: display))
                } else {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text(display.status).foregroundStyle(.white).font(.footnote)
                        Text("Serial output: serial.log in the machine folder")
                            .foregroundStyle(.gray).font(.caption2)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(display.status).font(.caption).foregroundStyle(.secondary)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { display.key(0xFF50) } label: { Label("Home", systemImage: "circle") }
                    Button { display.key(0xFF1B) } label: { Label("Lock", systemImage: "lock") }
                    Spacer()
                    Button(role: .destructive) {
                        display.shutdown()
                        dismiss()
                    } label: { Label("Stop", systemImage: "stop.fill") }
                }
            }
        }
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
