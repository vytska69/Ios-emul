import Foundation

/// Tiny DER reader sufficient for IMG4 / IM4P / IM4M containers.
public struct DERNode {
    public let tag: UInt8
    public let content: Data

    public var isConstructed: Bool { tag & 0x20 != 0 }

    public static func parse(_ data: Data) throws -> (node: DERNode, length: Int) {
        let b = [UInt8](data.prefix(10))
        guard b.count >= 2 else { throw IMG4Error.malformed("DER header") }
        var len = Int(b[1])
        var header = 2
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n > 0, n <= 8, b.count >= 2 + n else { throw IMG4Error.malformed("DER length") }
            len = 0
            for k in 0..<n { len = len << 8 | Int(b[2 + k]) }
            header += n
        }
        guard header + len <= data.count else { throw IMG4Error.malformed("DER truncated") }
        let start = data.startIndex + header
        return (DERNode(tag: b[0], content: data.subdata(in: start..<(start + len))), header + len)
    }

    public func children() throws -> [DERNode] {
        var out: [DERNode] = []
        var rest = content
        while !rest.isEmpty {
            let (node, used) = try DERNode.parse(rest)
            out.append(node)
            rest = rest.dropFirst(used)
        }
        return out
    }

    public var string: String? { String(data: content, encoding: .ascii) }

    public var integer: Int {
        content.reduce(0) { $0 << 8 | Int($1) }
    }
}

public enum IMG4Error: Error, CustomStringConvertible {
    case malformed(String)
    case encrypted(String)

    public var description: String {
        switch self {
        case .malformed(let s): return "Malformed IMG4 payload: \(s)"
        case .encrypted(let t): return "Payload '\(t)' is encrypted (KBAG present); decryption keys are required"
        }
    }
}

/// An IM4P payload: `SEQUENCE { "IM4P", type, description, OCTET STRING data, [kbag], [compression] }`.
public struct IM4P {
    public let type: String
    public let description: String
    public let payload: Data
    public let keybag: Data?
    public let uncompressedSize: Int?

    public var isEncrypted: Bool { keybag != nil }

    public init(_ data: Data) throws {
        var (root, _) = try DERNode.parse(data)
        var items = try root.children()
        // A full IMG4 wraps the IM4P as its second element.
        if items.first?.string == "IMG4", items.count >= 2 {
            root = items[1]
            items = try root.children()
        }
        guard items.count >= 4, items[0].string == "IM4P" else { throw IMG4Error.malformed("not an IM4P") }
        type = items[1].string ?? "????"
        description = items[2].string ?? ""
        payload = items[3].content
        var kbag: Data?
        var usize: Int?
        for extra in items.dropFirst(4) {
            if extra.tag == 0x04 {
                kbag = extra.content
            } else if extra.tag == 0x30, let fields = try? extra.children(), fields.count == 2 {
                usize = fields[1].integer
            }
        }
        keybag = kbag
        uncompressedSize = usize
    }

    /// Returns the decoded payload (LZFSE / LZSS stripped), refusing encrypted blobs.
    public func decodedPayload() throws -> Data {
        if isEncrypted { throw IMG4Error.encrypted(type) }
        return try Decompressor.auto(payload, expectedSize: uncompressedSize)
    }

    public static func looksLikeIMG4(_ data: Data) -> Bool {
        guard data.count > 16, data.first == 0x30 else { return false }
        return data.prefix(32).range(of: Data("IM4P".utf8)) != nil
            || data.prefix(32).range(of: Data("IMG4".utf8)) != nil
    }
}

/// Builds IMG4 containers, the form in which a device keeps personalised firmware on disk
/// (for example `sep-firmware.img4` in Preboot's firmware folder).
public enum IMG4 {
    /// SEQUENCE { IA5String "IMG4", IM4P, [0] EXPLICIT IM4M }. The manifest is optional: without a
    /// personalised ticket the container holds only the payload.
    public static func wrap(payload im4p: Data, manifest im4m: Data? = nil) -> Data {
        var body = der(tag: 0x16, Data("IMG4".utf8))
        body.append(im4p)
        if let im4m { body.append(der(tag: 0xA0, im4m)) }
        return der(tag: 0x30, body)
    }

    static func der(tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let n = content.count
        if n < 0x80 {
            out.append(UInt8(n))
        } else {
            var bytes: [UInt8] = []
            var v = n
            while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(content)
        return out
    }
}
