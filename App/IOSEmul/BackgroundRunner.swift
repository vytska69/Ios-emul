import AVFoundation

/// Keeps the app, and with it the emulated phone, running while it is in the background: iOS
/// suspends an app within seconds of leaving it unless it is playing audio, so this plays silence
/// for as long as a machine runs (as UTM does). Mixes with other apps' audio and is not heard.
@MainActor
final class BackgroundRunner {
    static let shared = BackgroundRunner()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var active = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        engine.attach(player)
        let center = NotificationCenter.default
        // A call or another app taking the audio session stops the engine; resume afterwards.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            guard type == .ended else { return }
            Task { @MainActor in self?.restart() }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restart() }
        })
    }

    func start() {
        guard !active else { return }
        active = true
        restart()
    }

    func stop() {
        guard active else { return }
        active = false
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func restart() {
        guard active else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
            let format = engine.outputNode.inputFormat(forBus: 0)
            let silenceFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate > 0 ? format.sampleRate : 44100, channels: 1)!
            engine.connect(player, to: engine.mainMixerNode, format: silenceFormat)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: silenceFormat, frameCapacity: AVAudioFrameCount(silenceFormat.sampleRate)) else { return }
            buffer.frameLength = buffer.frameCapacity      // zero-filled: one second of silence
            if !engine.isRunning { try engine.start() }
            player.stop()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
        } catch {
            // Without audio the app is suspended in the background as before; nothing else breaks.
        }
    }
}
