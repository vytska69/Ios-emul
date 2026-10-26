import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reads property lists in IOKit's XML dialect (OSUnserializeXML): plist elements without the
/// <plist> wrapper, where an element with ID="n" may be repeated later as an empty element with
/// IDREF="n", and integers carry a size attribute. CFPropertyList rejects both.
enum IOKitXML {
    static func parse(_ data: Data) -> Any? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), reader.failed == false else { return nil }
        return reader.root
    }

    private final class Reader: NSObject, XMLParserDelegate {
        /// An open element: its name, ID or IDREF, collected text and, for containers, children.
        private final class Frame {
            let name: String
            let id: String?
            let ref: String?
            var text = ""
            var items: [Any] = []
            var keys: [String] = []
            init(name: String, id: String?, ref: String?) { self.name = name; self.id = id; self.ref = ref }
        }

        var root: Any?
        var failed = false
        private var stack: [Frame] = []
        private var shared: [String: Any] = [:]

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            if name == "plist" { return }
            stack.append(Frame(name: name, id: attributes["ID"], ref: attributes["IDREF"]))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "plist" { return }
            guard let frame = stack.popLast() else { failed = true; return }
            if name == "key" {
                guard let parent = stack.last, parent.name == "dict" else { failed = true; return }
                parent.keys.append(frame.text)
                return
            }
            var value: Any?
            if let ref = frame.ref {
                value = shared[ref]
            } else {
                switch name {
                case "dict":
                    guard frame.keys.count == frame.items.count else { failed = true; return }
                    value = Dictionary(zip(frame.keys, frame.items), uniquingKeysWith: { _, last in last })
                case "array", "set": value = frame.items
                case "string": value = frame.text
                case "integer": value = Self.integer(frame.text)
                case "data": value = Data(base64Encoded: frame.text.filter { !$0.isWhitespace })
                case "true": value = true
                case "false": value = false
                default: value = nil
                }
            }
            guard let value else { failed = true; return }
            if let id = frame.id { shared[id] = value }
            if let parent = stack.last { parent.items.append(value) } else { root = value }
        }

        private static func integer(_ text: String) -> NSNumber? {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = t.hasPrefix("0x") || t.hasPrefix("0X") ? UInt64(t.dropFirst(2), radix: 16) : UInt64(t)
            guard let value else { return Int64(t).map { NSNumber(value: $0) } }
            return value <= UInt64(Int64.max) ? NSNumber(value: Int64(value)) : NSNumber(value: value)
        }
    }
}
