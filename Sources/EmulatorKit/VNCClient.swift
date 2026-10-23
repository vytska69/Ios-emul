import Foundation
import Network
import CoreGraphics

/// Minimal RFB 3.8 client: no authentication, raw encoding, DesktopSize pseudo-encoding.
/// QEMU's built-in VNC server is the guest display; touches are forwarded as absolute pointer events.
public final class VNCClient {
    public enum Event {
        case connected(width: Int, height: Int, name: String)
        case frame(CGImage)
        case disconnected(Error?)
    }

    public var onEvent: ((Event) -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "vnc.client")
    private var width = 0
    private var height = 0
    private var pixels = [UInt8]()
    private var buttonMask: UInt8 = 0

    public init(host: String = "127.0.0.1", port: UInt16) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    public func connect() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: Task { await self?.run() }
            // Nothing listening yet (QEMU has not opened its VNC server) leaves the connection in
            // .waiting, where it would sit until the network changes; report it so the caller retries.
            case .failed(let e), .waiting(let e):
                self?.connection.cancel()
                self?.emit(.disconnected(e))
            default: break
            }
        }
        connection.start(queue: queue)
    }

    public func disconnect() { connection.cancel() }

    // MARK: Input

    /// Sends a pointer event in framebuffer coordinates; `pressed` maps to the left button (a touch).
    public func pointer(x: Int, y: Int, pressed: Bool) {
        buttonMask = pressed ? 1 : 0
        var msg = Data([5, buttonMask])
        msg.appendBE(UInt16(clamping: max(0, min(x, width - 1))))
        msg.appendBE(UInt16(clamping: max(0, min(y, height - 1))))
        send(msg)
    }

    /// Sends an X11 keysym press+release (e.g. 0xff0d Return, 0xff1b Escape, ASCII for printable keys).
    public func key(_ keysym: UInt32) {
        for down in [UInt8(1), UInt8(0)] {
            var msg = Data([4, down, 0, 0])
            msg.appendBE(keysym)
            send(msg)
        }
    }

    // MARK: Protocol

    private func run() async {
        do {
            let version = try await read(12)
            guard String(decoding: version, as: UTF8.self).hasPrefix("RFB ") else { throw VNCError.protocolError("banner") }
            send(Data("RFB 003.008\n".utf8))

            let count = Int(try await read(1)[0])
            if count == 0 { throw VNCError.protocolError("server refused connection") }
            let types = try await read(count)
            guard types.contains(1) else { throw VNCError.protocolError("server requires authentication") }
            send(Data([1]))
            guard try await readU32() == 0 else { throw VNCError.protocolError("security handshake failed") }

            send(Data([1])) // ClientInit, shared session
            width = Int(try await readU16())
            height = Int(try await readU16())
            _ = try await read(16) // server pixel format, overridden below
            let name = String(decoding: try await read(Int(try await readU32())), as: UTF8.self)
            pixels = [UInt8](repeating: 0, count: width * height * 4)

            // 32bpp little-endian true colour, R<<16 G<<8 B → BGRA bytes in memory.
            send(Data([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]))
            var enc = Data([2, 0])
            enc.appendBE(UInt16(2))
            enc.appendBE(UInt32(0))                       // Raw
            enc.appendBE(UInt32(bitPattern: -223))        // DesktopSize
            send(enc)
            emit(.connected(width: width, height: height, name: name))
            requestUpdate(incremental: false)

            while true { try await handleMessage() }
        } catch {
            emit(.disconnected(error))
        }
    }

    private func handleMessage() async throws {
        let type = try await read(1)[0]
        switch type {
        case 0:
            _ = try await read(1)
            let rects = Int(try await readU16())
            for _ in 0..<rects {
                let x = Int(try await readU16()), y = Int(try await readU16())
                let w = Int(try await readU16()), h = Int(try await readU16())
                let encoding = Int32(bitPattern: try await readU32())
                switch encoding {
                case 0:
                    let data = try await read(w * h * 4)
                    blit(data, x: x, y: y, w: w, h: h)
                case -223:
                    width = w; height = h
                    pixels = [UInt8](repeating: 0, count: w * h * 4)
                default:
                    throw VNCError.protocolError("unexpected encoding \(encoding)")
                }
            }
            if let image = makeImage() { emit(.frame(image)) }
            requestUpdate(incremental: true)
        case 1:
            _ = try await read(3)
            let n = Int(try await readU16())
            _ = try await read(n * 6)
        case 2:
            break
        case 3:
            _ = try await read(3)
            _ = try await read(Int(try await readU32()))
        default:
            throw VNCError.protocolError("unknown server message \(type)")
        }
    }

    private func blit(_ data: Data, x: Int, y: Int, w: Int, h: Int) {
        guard x + w <= width, y + h <= height else { return }
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            pixels.withUnsafeMutableBytes { dst in
                for row in 0..<h {
                    let s = row * w * 4
                    let d = ((y + row) * width + x) * 4
                    dst.baseAddress!.advanced(by: d).copyMemory(from: src.baseAddress!.advanced(by: s), byteCount: w * 4)
                }
            }
        }
    }

    private func makeImage() -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func requestUpdate(incremental: Bool) {
        var msg = Data([3, incremental ? 1 : 0])
        msg.appendBE(UInt16(0)); msg.appendBE(UInt16(0))
        msg.appendBE(UInt16(clamping: width)); msg.appendBE(UInt16(clamping: height))
        send(msg)
    }

    // MARK: I/O helpers

    private func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func read(_ n: Int) async throws -> Data {
        if n == 0 { return Data() }
        var out = Data()
        while out.count < n {
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: n - out.count) { data, _, done, error in
                    if let error { cont.resume(throwing: error) }
                    else if let data, !data.isEmpty { cont.resume(returning: data) }
                    else if done { cont.resume(throwing: VNCError.closed) }
                    else { cont.resume(returning: Data()) }
                }
            }
            out.append(chunk)
        }
        return out
    }

    private func readU16() async throws -> UInt16 {
        let d = try await read(2)
        return UInt16(d[d.startIndex]) << 8 | UInt16(d[d.startIndex + 1])
    }

    private func readU32() async throws -> UInt32 {
        let d = try await read(4)
        return d.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { self.onEvent?(event) }
    }
}

public enum VNCError: Error, CustomStringConvertible {
    case protocolError(String)
    case closed

    public var description: String {
        switch self {
        case .protocolError(let s): return "VNC protocol error: \(s)"
        case .closed: return "VNC connection closed"
        }
    }
}

extension Data {
    mutating func appendBE(_ v: UInt16) { append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }
    mutating func appendBE(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
}
