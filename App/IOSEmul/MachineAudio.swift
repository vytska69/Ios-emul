import AVFoundation
import UIKit
import EmulatorKit

/// Plays the emulated phone's sound while a machine runs, and keeps the app running in the
/// background.
///
/// The iOS QEMU build has no audio driver of its own; the guest's output is kept in a ring by
/// qemu/patches/inferno/0025, read here with qemu_ios_audio_read and played through AVAudioEngine.
/// With nothing to play the node plays silence, which is also what keeps iOS from suspending the
/// app in the background (as UTM does), when "Run in background" is on.
@MainActor
final class MachineAudio {
    static let shared = MachineAudio()

    private typealias ReadFn = @convention(c) (UnsafeMutableRawPointer?, Int) -> Int
    private typealias FormatFn = @convention(c) (UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
                                                 UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    /// Whether the source was made with QEMU's functions (the library loads when the machine starts).
    private var sourceReadsGuest = false
    private var active = false
    private var keepInBackground = true
    private var observers: [NSObjectProtocol] = []
    /// A standalone engine for the test tone, kept alive while it plays.
    private var toneEngine: AVAudioEngine?

    /// Diagnostics for the Settings "Sound" card, to tell an app-output problem from a guest that
    /// makes no sound. Updated on the audio thread, read on the main one; a stale read is harmless.
    public nonisolated(unsafe) static var totalGuestBytesRead = 0
    /// Whether the guest's read function was found and its source is attached (not the silent one).
    public var guestSourceAttached: Bool { sourceReadsGuest }
    /// Whether the audio engine is running.
    public var engineRunning: Bool { engine.isRunning }
    /// The last error starting the audio, if any, and how often the watchdog restarted it.
    public private(set) var lastError: String?
    public private(set) var restarts = 0
    /// The guest's output format once it has played anything (qemu_ios_audio_format), else nil:
    /// tells "the emulated phone made no sound" from "the app did not play it".
    public var guestPlayedFormat: String? {
        guard let fn = QEMURunner.library.flatMap({ dlsym($0, "qemu_ios_audio_format") })
            .map({ unsafeBitCast($0, to: FormatFn.self) }) else { return nil }
        var freq: Int32 = 0, channels: Int32 = 0, bits: Int32 = 0, isFloat: Int32 = 0
        guard fn(&freq, &channels, &bits, &isFloat) == 0 else { return nil }
        return "\(freq) Hz, \(channels) ch, \(bits)-bit\(isFloat != 0 ? " float" : "")"
    }
    private var watchdog: Timer?

    private init() {
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
        // Without "Run in background" the app should be suspended as usual when left.
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active, !self.keepInBackground else { return }
                self.engine.pause()
            }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restart() }
        })
    }

    func start(keepInBackground: Bool) {
        self.keepInBackground = keepInBackground
        guard !active else { return }
        active = true
        restart()
        // The engine can stop on its own (a route or configuration change, another engine
        // starting) and the QEMU library loads only after the machine view appears; check every
        // second that the guest's source is attached and the engine runs.
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active else { return }
                if !self.engine.isRunning || (!self.sourceReadsGuest && QEMURunner.library != nil) {
                    self.restarts += 1
                    self.restart()
                }
            }
        }
    }

    func stop() {
        guard active else { return }
        active = false
        watchdog?.invalidate()
        watchdog = nil
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Plays a 1.5 s 440 Hz tone through the app's own audio, with no emulator involved. If it is
    /// heard, the app can output sound on this device and silence is the guest making none; if it
    /// is not, the app's audio output (session, routing) is the problem.
    func playTestTone() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
        } catch {}
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 2, interleaved: false) else { return }
        let step = 2.0 * Double.pi * 440.0 / sampleRate
        var phase = 0.0
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let value = Float(sin(phase)) * 0.2
                phase += step
                if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
                for buffer in buffers {
                    if let out = buffer.mData?.assumingMemoryBound(to: Float.self) { out[frame] = value }
                }
            }
            return noErr
        }
        let tone = AVAudioEngine()
        tone.attach(node)
        tone.connect(node, to: tone.mainMixerNode, format: format)
        do { try tone.start() } catch { return }
        toneEngine = tone
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            tone.stop()
            if self.toneEngine === tone { self.toneEngine = nil }
        }
    }

    private func restart() {
        guard active else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
            if source == nil || (!sourceReadsGuest && QEMURunner.library != nil) {
                // Change the graph with the engine stopped; started again just below.
                engine.stop()
                attachSource()
            }
            if !engine.isRunning { try engine.start() }
            lastError = nil
        } catch {
            // Without audio the machine is silent and suspended in the background; nothing else
            // breaks. The watchdog tries again; the error is shown in Settings → Emulator → Sound.
            lastError = error.localizedDescription
        }
    }

    private func attachSource() {
        let read = QEMURunner.library.flatMap { dlsym($0, "qemu_ios_audio_read") }.map { unsafeBitCast($0, to: ReadFn.self) }
        let format = QEMURunner.library.flatMap { dlsym($0, "qemu_ios_audio_format") }.map { unsafeBitCast($0, to: FormatFn.self) }
        if let old = source {
            engine.disconnectNodeOutput(old)
            engine.detach(old)
        }
        guard let made = Self.makeSource(read: read, format: format) else { return }
        let (node, nodeFormat) = made
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: nodeFormat)
        source = node
        sourceReadsGuest = read != nil
    }

    /// The render callback runs on the audio thread, so it is built outside the main actor.
    /// The guest plays 16-bit stereo at 44.1 kHz (Inferno's MCA); the mixer converts to the output.
    nonisolated private static func makeSource(read: ReadFn?, format: FormatFn?) -> (AVAudioSourceNode, AVAudioFormat)? {
        let sampleRate = 44_100.0
        let frameCapacity = 8192
        let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: frameCapacity * 2)
        var guestIs16BitStereo = true
        var checkedFormat = false

        guard let nodeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                             channels: 2, interleaved: false) else { return nil }
        let node = AVAudioSourceNode(format: nodeFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = min(Int(frameCount), frameCapacity)
            var got = 0
            if let read {
                if !checkedFormat, let format {
                    var freq: Int32 = 0, channels: Int32 = 0, bits: Int32 = 0, isFloat: Int32 = 0
                    if format(&freq, &channels, &bits, &isFloat) == 0 {
                        guestIs16BitStereo = channels == 2 && bits == 16 && isFloat == 0
                        checkedFormat = true
                    }
                }
                if guestIs16BitStereo {
                    got = read(scratch, frames * 4) / 4
                    MachineAudio.totalGuestBytesRead &+= got * 4
                }
            }
            for (channel, buffer) in buffers.enumerated() {
                guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let c = min(channel, 1)
                for i in 0..<Int(frameCount) {
                    out[i] = i < got ? Float(scratch[i * 2 + c]) / 32768 : 0
                }
            }
            return noErr
        }
        return (node, nodeFormat)
    }
}
