import Foundation

public enum SCE {
    /// Builds the OMEMO Stanza Content Encryption envelope. `contentXML` must be one or more
    /// complete child elements (for example `<body xmlns='jabber:client'>…</body>`).
    public static func envelope(contentXML: String, from: String, to: String? = nil) throws -> String {
        let padding = try CryptoPrimitives.randomBytes(Int.random(in: 24...72)).base64
        let toElement = to.map { "<to jid='\(escape($0))'/>" } ?? ""
        return "<envelope xmlns='urn:xmpp:sce:1'><content>\(contentXML)</content><rpad>\(padding)</rpad><from jid='\(escape(from))'/>\(toElement)</envelope>"
    }

    public static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
