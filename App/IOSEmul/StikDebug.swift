import SwiftUI
import EmulatorKit

/// Asks StikDebug to enable JIT for this app, with the script iOS 26+ (TXM) devices need, then
/// prepares the JIT memory as soon as it has attached.
@MainActor
final class StikDebug: ObservableObject {
    static let shared = StikDebug()

    enum Phase: Equatable { case idle, waiting, ready, failed(String) }
    @Published private(set) var phase = Phase.idle

    /// On iOS 26 and later StikDebug runs a script that maps JIT memory when the app asks for it
    /// (qemu/patches/inferno/0016); universal.js is the one for apps that implement that protocol.
    private var needsScript: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 }

    private var url: URL? {
        var c = URLComponents()
        c.scheme = "stikdebug"
        c.host = "enable-jit"
        c.queryItems = [URLQueryItem(name: "bundle-id", value: Bundle.main.bundleIdentifier),
                        URLQueryItem(name: "pid", value: String(getpid()))]
        if needsScript { c.queryItems?.append(URLQueryItem(name: "script-name", value: "universal.js")) }
        return c.url
    }

    func enableJIT() {
        guard let url else { return }
        phase = .waiting
        UIApplication.shared.open(url) { [weak self] opened in
            Task { @MainActor in
                guard let self else { return }
                if !opened {
                    self.phase = .failed("StikDebug is not installed, or could not be opened.")
                    return
                }
                await self.waitForDebugger()
            }
        }
    }

    private func waitForDebugger() async {
        let megabytes = Pref.defaults.integer(forKey: Pref.translationCacheMB)
        for _ in 0..<240 {   // up to 2 minutes, while the user pairs or confirms in StikDebug
            if QEMURunner.jitAvailable {
                // TXM: the script waits, attached, for the JIT request; elsewhere this does nothing.
                if QEMURunner.debuggerAttached { QEMURunner.prepareJITAtLaunch(megabytes: megabytes) }
                phase = .ready
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        phase = .failed("StikDebug did not enable JIT. Check its VPN and pairing file, then try again.")
    }
}

/// A button that enables JIT through StikDebug, with its progress.
struct StikDebugButton: View {
    @ObservedObject private var stik = StikDebug.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { stik.enableJIT() } label: {
                Label(stik.phase == .waiting ? "Waiting for StikDebug…" : "Enable JIT with StikDebug",
                      systemImage: "bolt.badge.automatic")
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(stik.phase == .waiting)
            switch stik.phase {
            case .ready:
                Label(QEMURunner.preparedJITMB > 0 ? "JIT enabled; \(QEMURunner.preparedJITMB) MB prepared." : "JIT enabled.",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            default:
                EmptyView()
            }
        }
    }
}
