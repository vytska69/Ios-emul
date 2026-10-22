import Foundation

/// Apple's flattened DeviceTree as shipped in IPSWs (`DeviceTree.*.im4p`, IM4P type `dtre`).
///
/// Layout (little-endian): a node is `u32 propertyCount, u32 childCount`, then its properties
/// (`char name[32]`, `u32 length` with bit 31 marking a placeholder, value padded to 4 bytes),
/// then its children, recursively.
public final class DeviceTreeNode {
    public let properties: [String: Data]
    public let placeholders: Set<String>
    public let children: [DeviceTreeNode]
    public private(set) weak var parent: DeviceTreeNode?

    public var name: String { string("name") ?? "" }

    public var path: String {
        guard let parent else { return "/" }
        let base = parent.path
        return (base == "/" ? "" : base) + "/" + name
    }

    /// `compatible` is a NUL-separated string list.
    public var compatible: [String] { strings("compatible") }

    public var deviceType: String? { string("device_type") }

    init(properties: [String: Data], placeholders: Set<String>, children: [DeviceTreeNode]) {
        self.properties = properties
        self.placeholders = placeholders
        self.children = children
        children.forEach { $0.parent = self }
    }

    public func string(_ key: String) -> String? {
        strings(key).first
    }

    public func strings(_ key: String) -> [String] {
        guard let data = properties[key] else { return [] }
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { !$0.isEmpty }
    }

    public func u32(_ key: String) -> UInt32? {
        guard let d = properties[key], d.count >= 4 else { return nil }
        return ByteReader(d).u32(at: 0)
    }

    public func child(_ name: String) -> DeviceTreeNode? { children.first { $0.name == name } }

    /// Looks up a node by slash-separated path relative to this node, e.g. "arm-io/uart0".
    public func node(at path: String) -> DeviceTreeNode? {
        path.split(separator: "/").reduce(self as DeviceTreeNode?) { $0?.child(String($1)) }
    }

    /// Depth-first walk including this node.
    public func walk(_ visit: (DeviceTreeNode) -> Void) {
        visit(self)
        children.forEach { $0.walk(visit) }
    }
}

public enum DeviceTree {
    public enum Error: Swift.Error, CustomStringConvertible {
        case truncated(Int)
        case implausible(String)

        public var description: String {
            switch self {
            case .truncated(let at): return "DeviceTree truncated at offset \(at)"
            case .implausible(let what): return "Not a DeviceTree: \(what)"
            }
        }
    }

    /// Parses a raw DeviceTree blob, or an IM4P/IMG4 wrapping one.
    public static func parse(_ data: Data) throws -> DeviceTreeNode {
        let raw = IM4P.looksLikeIMG4(data) ? try IM4P(data).decodedPayload() : data
        var offset = 0
        return try node(ByteReader(raw), count: raw.count, offset: &offset, depth: 0)
    }

    private static func node(_ r: ByteReader, count: Int, offset: inout Int, depth: Int) throws -> DeviceTreeNode {
        guard depth < 64 else { throw Error.implausible("nesting deeper than 64") }
        guard offset + 8 <= count else { throw Error.truncated(offset) }
        let propCount = Int(r.u32(at: offset))
        let childCount = Int(r.u32(at: offset + 4))
        offset += 8
        guard propCount < 4096, childCount < 4096 else { throw Error.implausible("\(propCount) properties") }

        var props: [String: Data] = [:]
        var placeholders = Set<String>()
        for _ in 0..<propCount {
            guard offset + 36 <= count else { throw Error.truncated(offset) }
            let nameBytes = r.data.subdata(in: (r.data.startIndex + offset)..<(r.data.startIndex + offset + 32))
            let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
            var length = r.u32(at: offset + 32)
            offset += 36
            if length & 0x8000_0000 != 0 {
                placeholders.insert(name)
                length &= 0x7FFF_FFFF
            }
            let len = Int(length)
            guard offset + len <= count else { throw Error.truncated(offset) }
            props[name] = r.data.subdata(in: (r.data.startIndex + offset)..<(r.data.startIndex + offset + len))
            offset += (len + 3) & ~3
        }
        var children: [DeviceTreeNode] = []
        children.reserveCapacity(childCount)
        for _ in 0..<childCount {
            children.append(try node(r, count: count, offset: &offset, depth: depth + 1))
        }
        return DeviceTreeNode(properties: props, placeholders: placeholders, children: children)
    }
}

extension IPSW {
    /// The DeviceTree for a build identity (the one the device boots, not the restore one).
    public func deviceTree(identity: BuildManifest.Identity) throws -> DeviceTreeNode {
        try DeviceTree.parse(rawComponent("DeviceTree", identity: identity))
    }
}
