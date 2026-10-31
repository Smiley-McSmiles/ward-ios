import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: - Lightweight XML tree

struct XMLNode: Hashable {
    var name: String
    var prefix: String?
    var uri: String?
    var attributes: [String: String]
    var children: [XMLNode]
    var text: String

    init(name: String, prefix: String? = nil, uri: String? = nil,
         attributes: [String: String] = [:], children: [XMLNode] = [], text: String = "") {
        self.name = name; self.prefix = prefix; self.uri = uri
        self.attributes = attributes; self.children = children; self.text = text
    }

    func child(_ local: String, xmlns: String? = nil) -> XMLNode? {
        children.first { $0.name == local && (xmlns == nil || $0.uri == xmlns) }
    }
    func children(_ local: String) -> [XMLNode] { children.filter { $0.name == local } }
    func child(_ local: String, in namespace: String) -> XMLNode? {
        children.first { $0.name == local && $0.uri == namespace }
    }
    func attr(_ key: String) -> String? { attributes[key] }
    func attr(_ key: String, _ fallback: String) -> String { attributes[key] ?? fallback }
    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var allText: String {
        var result = text
        for child in children { result += child.allText }
        return result
    }

    /// Serializes a node for the XML console. Namespace declarations from the original document
    /// are not reconstructed, but the stanza itself stays readable and round-trippable.
    func xmlString(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let name = prefix.map { "\($0):\(self.name)" } ?? self.name
        var out = pad + "<" + name
        for (key, value) in attributes.sorted(by: { $0.key < $1.key }) {
            out += " \(key)=\"\(XML.escape(value))\""
        }
        if children.isEmpty && text.isEmpty {
            return out + "/>"
        }
        out += ">"
        if !text.isEmpty { out += XML.escape(text) }
        if !children.isEmpty {
            out += "\n"
            out += children.map { $0.xmlString(indent: indent + 1) }.joined(separator: "\n")
            out += "\n" + pad
        }
        out += "</" + name + ">"
        return out
    }
}

enum XML {
    static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }

    static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func parse(_ string: String) -> XMLNode? {
        guard let data = string.data(using: .utf8) else { return nil }
        let delegate = TreeParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return delegate.root }
        return delegate.root
    }

    static func stanza(_ name: String, _ attributes: [String: String] = [:], _ children: [String] = [], text: String? = nil) -> String {
        var out = "<" + name
        for (key, value) in attributes.sorted(by: { $0.key < $1.key }) {
            out += " \(key)=\"\(escape(value))\""
        }
        if children.isEmpty, text == nil { return out + "/>" }
        out += ">"
        if let text { out += escape(text) }
        out += children.joined()
        out += "</" + name + ">"
        return out
    }
}

private final class TreeParser: NSObject, XMLParserDelegate {
    var root: XMLNode?
    private var stack: [XMLNode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.contains(":") ? String(elementName.split(separator: ":").last ?? "") : elementName
        let prefix = elementName.contains(":") ? String(elementName.split(separator: ":").first ?? "") : nil
        let node = XMLNode(name: local, prefix: prefix, uri: namespaceURI,
                           attributes: attributeDict, children: [], text: "")
        if var parent = stack.last {
            parent.children.append(node)
            stack[stack.count - 1] = parent
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !stack.isEmpty, let string = String(data: CDATABlock, encoding: .utf8) else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard !stack.isEmpty else { return }
        let node = stack.removeLast()
        if !stack.isEmpty {
            // The child was appended on start; nothing else to do.
            _ = node
        }
    }
}

// MARK: - Incremental stream splitter

/// Network reads arrive in arbitrary chunks. This splitter hands back complete top-level XML
/// elements (or the stream header/footer) while preserving the rest for the next read.
final class XMLStreamSplitter {
    private var buffer = ""
    private var started = false

    func feed(_ chunk: String) -> [String] {
        buffer += chunk
        var output: [String] = []
        while true {
            let trimmed = buffer.drop(while: { $0.isWhitespace })
            if trimmed.isEmpty { buffer = ""; break }
            let startOffset = buffer.count - trimmed.count
            if startOffset > 0 { buffer.removeFirst(startOffset) }

            if buffer.hasPrefix("<?xml") {
                guard let end = findTagEnd(buffer, from: buffer.startIndex) else { break }
                buffer.removeSubrange(buffer.startIndex...end)
                continue
            }
            if buffer.hasPrefix("<stream:stream") || buffer.hasPrefix("<stream:stream ") {
                guard let end = findTagEnd(buffer, from: buffer.startIndex) else { break }
                output.append(String(buffer[buffer.startIndex...end]))
                buffer.removeSubrange(buffer.startIndex...end)
                started = true
                continue
            }
            if buffer.hasPrefix("</stream:stream") {
                guard let end = findTagEnd(buffer, from: buffer.startIndex) else { break }
                output.append(String(buffer[buffer.startIndex...end]))
                buffer.removeSubrange(buffer.startIndex...end)
                continue
            }
            if let (element, end) = scanElement(buffer) {
                output.append(element)
                buffer.removeSubrange(buffer.startIndex...end)
            } else {
                break
            }
        }
        return output
    }

    private func findTagEnd(_ string: String, from index: String.Index) -> String.Index? {
        var i = index
        var quote: Character? = nil
        while i < string.endIndex {
            let c = string[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ">" {
                return i
            }
            i = string.index(after: i)
        }
        return nil
    }

    /// Scans a full element and returns it together with its final `>` index.
    private func scanElement(_ string: String) -> (String, String.Index)? {
        var i = string.startIndex
        var depth = 0
        var seenOpen = false
        while i < string.endIndex {
            guard let open = string[i...].firstIndex(of: "<") else { return nil }
            i = open
            if string[i...].hasPrefix("<!--") {
                guard let end = string[i...].range(of: "-->") else { return nil }
                i = end.upperBound
                continue
            }
            if string[i...].hasPrefix("<![CDATA[") {
                guard let end = string[i...].range(of: "]]>") else { return nil }
                i = end.upperBound
                continue
            }
            guard let end = findTagEnd(string, from: i) else { return nil }
            let tag = String(string[i...end])
            if tag.hasPrefix("</") {
                depth -= 1
                if depth == 0 { return (String(string[string.startIndex...end]), end) }
            } else if tag.hasPrefix("<?") || tag.hasPrefix("<!") {
                // Processing instruction or doctype: ignore.
            } else {
                depth += 1
                seenOpen = true
                if tag.hasSuffix("/>") {
                    depth -= 1
                    if depth == 0 && seenOpen { return (String(string[string.startIndex...end]), end) }
                }
            }
            i = string.index(after: end)
        }
        return nil
    }
}
