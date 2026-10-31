import Foundation

enum NS {
    static let client = "jabber:client"
    static let stream = "http://etherx.jabber.org/streams"
    static let sasl = "urn:ietf:params:xml:ns:xmpp-sasl"
    static let tls = "urn:ietf:params:xml:ns:xmpp-tls"
    static let bind = "urn:ietf:params:xml:ns:xmpp-bind"
    static let session = "urn:ietf:params:xml:ns:xmpp-session"
    static let roster = "jabber:iq:roster"
    static let sm = "urn:xmpp:sm:3"
    static let ping = "urn:xmpp:ping"
    static let delay = "urn:xmpp:delay"
    static let carbons = "urn:xmpp:carbons:2"
    static let forward = "urn:xmpp:forward:0"
    static let mam = "urn:xmpp:mam:2"
    static let rsm = "http://jabber.org/protocol/rsm"
    static let data = "jabber:x:data"
    static let receipts = "urn:xmpp:receipts"
    static let markers = "urn:xmpp:chat-markers:0"
    static let chatstates = "http://jabber.org/protocol/chatstates"
    static let hints = "urn:xmpp:hints"
    static let sid = "urn:xmpp:sid:0"
    static let reply = "urn:xmpp:reply:0"
    static let fallback = "urn:xmpp:fallback:0"
    static let correct = "urn:xmpp:message-correct:0"
    static let retract = "urn:xmpp:message-retract:1"
    static let retract0 = "urn:xmpp:message-retract:0"
    static let reactions = "urn:xmpp:reactions:0"
    static let markdown = "urn:xmpp:ward:markdown:0"
    static let oob = "jabber:x:oob"
    static let sfs = "urn:xmpp:sfs:0"
    static let file = "urn:xmpp:file:metadata:0"
    static let thumbs = "urn:xmpp:thumbs:1"
    static let hashes = "urn:xmpp:hashes:2"
    static let occupantId = "urn:xmpp:occupant-id:0"
    static let muc = "http://jabber.org/protocol/muc"
    static let mucUser = "http://jabber.org/protocol/muc#user"
    static let discoItems = "http://jabber.org/protocol/disco#items"
    static let discoInfo = "http://jabber.org/protocol/disco#info"
    static let commands = "http://jabber.org/protocol/commands"
    static let admin = "http://jabber.org/protocol/admin#"
    static let blocklist = "urn:xmpp:blocking"
    static let vcard = "vcard-temp"
    static let privateStorage = "jabber:iq:private"
    static let bookmarks = "storage:bookmarks"
    static let conference = "jabber:x:conference"
    static let upload = "urn:xmpp:http:upload:0"
    static let uploadLegacy = "urn:xmpp:http:upload"
    static let jingleMessage = "urn:xmpp:jingle-message:0"
    static let jingle = "urn:xmpp:jingle:1"
    static let jingleApps = "urn:xmpp:jingle:apps:rtp:1"
    static let jingleTransport = "urn:xmpp:jingle:transports:ice-udp:1"
    static let eme = "urn:xmpp:eme:0"
    static let omemo = "eu.siacs.conversations.axolotl"
    static let omemo2 = "urn:xmpp:omemo:2"
    static let openpgp = "urn:xmpp:openpgp:0"
    static let avatarData = "urn:xmpp:avatar:data"
    static let avatarMetadata = "urn:xmpp:avatar:metadata"
}

extension String {
    static func wardID() -> String { UUID().uuidString.lowercased() }
}

extension Date {
    static func fromXMPP(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
