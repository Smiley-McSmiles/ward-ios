import Foundation

// MARK: - Helpers

extension Date {
    var millis: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
    init(millis: Int64) { self.init(timeIntervalSince1970: Double(millis) / 1000) }
}

enum JID {
    static func local(_ jid: String) -> String { String(jid.split(separator: "@", maxSplits: 1).first ?? "") }
    static func domain(_ jid: String) -> String {
        let parts = jid.split(separator: "@", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]).split(separator: "/").first.map(String.init) ?? "" : ""
    }
    static func resource(_ jid: String) -> String? {
        guard let slash = jid.firstIndex(of: "/") else { return nil }
        return String(jid[jid.index(after: slash)...])
    }
    static func bare(_ jid: String) -> String { jid.split(separator: "/").first.map(String.init) ?? jid }
    static func normalize(_ raw: String, domain: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.contains("@") ? trimmed : "\(trimmed)@\(domain)"
    }
    static func valid(_ jid: String) -> Bool {
        let parts = jid.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return false }
        return !parts[0].isEmpty && !parts[1].isEmpty
    }
}

// MARK: - Account

struct Account: Codable, Identifiable, Hashable {
    var id: Int64 = 0
    var jid: String
    var label: String = ""
    var color: String = "#3584E4"
    var enabled: Bool = true
    var encryptedPassword: String = ""
    var options: [String: String] = [:]
    var isAdmin: Bool = false
    var nickname: String = ""
    var avatar: String = ""
    var createdAt: Int64 = Date().millis

    var domain: String { JID.domain(jid) }
    var localpart: String { JID.local(jid) }
    var displayName: String { label.isEmpty ? (nickname.isEmpty ? jid : nickname) : label }
    var bareJID: String { JID.bare(jid) }
}

// MARK: - Contact

struct Contact: Codable, Identifiable, Hashable {
    var accountId: Int64
    var jid: String
    var rosterName: String = ""
    var nickname: String = ""
    var groups: [String] = []
    var subscription: String = "none"
    var ask: String = ""
    var inRoster: Bool = true
    var blocked: Bool = false
    var presence: String = "offline"
    var status: String = ""
    var avatar: String = ""
    var lastSeen: Int64 = 0
    var isGateway: Bool = false

    var id: String { "\(accountId)-\(jid)" }
    var name: String {
        if !nickname.isEmpty { return nickname }
        if !rosterName.isEmpty { return rosterName }
        return JID.local(jid)
    }
    var isOnline: Bool { presence != "offline" && presence != "unavailable" }
}

// MARK: - Chat

enum ChatType: String, Codable, CaseIterable { case chat, groupchat, pm }
enum EncryptionMode: String, Codable, CaseIterable {
    case `default`, omemo, pgp, off
    var label: String {
        switch self {
        case .default: return "Default"
        case .omemo: return "OMEMO"
        case .pgp: return "OpenPGP"
        case .off: return "Off"
        }
    }
}

struct Chat: Codable, Identifiable, Hashable {
    var id: Int64 = 0
    var accountId: Int64
    var jid: String
    var type: String = "chat"
    var name: String = ""
    var pinned: Bool = false
    var mutedUntil: Int64 = 0
    var archived: Bool = false
    var isRequest: Bool = false
    var draft: String = ""
    var unread: Int = 0
    var mentions: Int = 0
    var lastActivity: Int64 = Date().millis
    var lastReadId: Int64 = 0
    var clearedAt: Int64 = 0
    var preview: String = ""
    var previewSender: String = ""
    var encryption: String = "default"
    var notify: String = "default"
    var subject: String = ""
    var memberCount: Int = 0
    var joined: Bool = false
    var open: Bool = true
    var joinError: String = ""
    var ourNick: String = ""
    var ourRole: String = ""
    var ourAffiliation: String = ""
    var avatar: String = ""
    var options: [String: String] = [:]

    var isGroup: Bool { type == ChatType.groupchat.rawValue }
    var displayName: String { name.isEmpty ? jid : name }
    var isMuted: Bool { mutedUntil > Date().millis }
    var encryptionMode: EncryptionMode { EncryptionMode(rawValue: encryption) ?? .default }
}

// MARK: - Message

enum MessageKind: String, Codable { case text, me, file, status, system }

struct Attachment: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var url: String = ""
    var name: String = ""
    var mime: String = ""
    var size: Int64 = 0
    var width: Double = 0
    var height: Double = 0
    var duration: Double = 0
    var encrypted: Bool = false
    var localPath: String? = nil
    var downloading: Bool = false
    var failed: Bool = false
    var isVoice: Bool = false
}

struct Reaction: Codable, Identifiable, Hashable {
    var emoji: [String] = []
    var who: String = ""
    var mine: Bool = false
    var id: String { who }
}

struct Message: Codable, Identifiable, Hashable {
    var id: Int64 = 0
    var chatId: Int64
    var stanzaId: String = ""
    var originId: String = ""
    var msgId: String = ""
    var sender: String = ""
    var senderJid: String = ""
    var senderName: String = ""
    var occupantId: String = ""
    var direction: Int = 0
    var timestamp: Int64 = Date().millis
    var body: String = ""
    var isMarkdown: Bool = false
    var kind: String = "text"
    var encryption: String = ""
    var senderDevice: Int64 = 0
    var trust: String = ""
    var edited: Bool = false
    var retracted: Bool = false
    var replyTo: String = ""
    var replyPreview: String = ""
    var replyAuthor: String = ""
    var status: Int = 0
    var error: String = ""
    var mentionsMe: Bool = false
    var reactions: [Reaction] = []
    var attachments: [Attachment] = []
    var raw: String = ""
    var scheduledAt: Int64? = nil

    var isOutgoing: Bool { direction == 1 }
    var isFile: Bool { kind == MessageKind.file.rawValue }
    var date: Date { Date(millis: timestamp) }
    var lastReaction: Reaction? { reactions.last }
}

// MARK: - Devices & keys

enum DeviceProtocol: String, Codable { case omemo, omemo2, pgp }

struct Device: Codable, Identifiable, Hashable {
    var accountId: Int64
    var jid: String
    var deviceId: Int64
    var fingerprint: String = ""
    var label: String = ""
    var trust: String = "undecided"
    var active: Bool = true
    var own: Bool = false
    var thisDevice: Bool = false
    var versions: String = "OMEMO 2, legacy"
    var firstSeen: Int64 = Date().millis
    var lastUsed: Int64 = 0
    var kind: String = "omemo"
    var protocolName: String = "omemo"

    var id: String { "\(accountId)-\(jid)-\(deviceId)-\(protocolName)" }
}

struct PgpKey: Codable, Identifiable, Hashable {
    var accountId: Int64
    var jid: String
    var fingerprint: String
    var armored: String
    var name: String = ""
    var trust: String = "undecided"
    var announced: Bool = true
    var firstSeen: Int64 = Date().millis
    var lastSeen: Int64 = Date().millis
    var id: String { "\(accountId)-\(jid)-\(fingerprint)" }
}

struct Receipt: Codable, Identifiable, Hashable {
    var messageId: Int64
    var recipient: String
    var deliveredAt: Int64 = 0
    var displayedAt: Int64 = 0
    var id: String { "\(messageId)-\(recipient)" }
}

// MARK: - Requests

struct ContactRequest: Codable, Identifiable, Hashable {
    var accountId: Int64
    var jid: String
    var kind: String = "subscription"
    var text: String = ""
    var chatId: Int64 = 0
    var createdAt: Int64 = Date().millis
    var id: String { "\(accountId)-\(jid)-\(kind)" }
}

// MARK: - Live state

struct ConnectionState: Equatable {
    var state: String = "offline" // offline | connecting | online | error
    var step: String = ""
    var error: String = ""
    var since: Date? = nil
    var label: String {
        if state == "online" { return "Online" }
        if state == "connecting" { return step.isEmpty ? "Connecting…" : step }
        if state == "error" { return "Offline" }
        return "Offline"
    }
}

struct XmlLogEntry: Identifiable, Hashable {
    let id = UUID()
    let time: Date
    let accountId: Int64
    let incoming: Bool
    let text: String
}

struct RoomOccupant: Identifiable, Hashable {
    var nick: String
    var jid: String = ""
    var role: String = "participant"
    var affiliation: String = "none"
    var status: String = ""
    var isMe: Bool = false
    var id: String { nick }
    var name: String { jid.isEmpty ? nick : jid }
}

// MARK: - Admin

struct AdminField: Identifiable, Hashable {
    var id: String { "\(varName)-\(type)-\(label)" }
    var varName: String
    var type: String // text-single, text-multi, boolean, list-single, list-multi, jid-single, jid-multi, fixed, hidden
    var label: String
    var value: String = ""
    var options: [(String, String)] = []
    var required: Bool = false
    var desc: String = ""
    var media: String? = nil

    static func == (lhs: AdminField, rhs: AdminField) -> Bool { lhs.id == rhs.id && lhs.value == rhs.value }
    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(value) }
}

struct AdminCommand: Identifiable, Hashable {
    var node: String
    var name: String
    var jid: String
    var id: String { "\(jid)-\(node)" }
}

struct AdminForm {
    var sessionId: String
    var jid: String = ""
    var node: String = ""
    var title: String
    var instructions: String
    var fields: [AdminField]
    var submitLabel: String = "Submit"
    var actions: [String] = ["complete"]
    var notes: [String] = []
    var status: String = "executing"
}

struct DiscoItem: Identifiable, Hashable {
    var jid: String
    var name: String = ""
    var node: String = ""
    var id: String { "\(jid)-\(node)" }
}

// MARK: - Call

enum CallKind: String { case audio, video }
enum CallStatus: String { case outgoing, ringing, connecting, active, ended }

struct CallState: Identifiable, Equatable {
    var id = UUID()
    var peer: String
    var accountId: Int64
    var kind: CallKind = .audio
    var status: CallStatus = .outgoing
    var startedAt: Date? = nil
    var muted = false
    var speaker = false
    var camera = false
    var error: String = ""
    var incoming = false
}

// MARK: - Nav

enum AppTab: String, CaseIterable, Identifiable {
    case chats, contacts, server, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chats: return "Chats"
        case .contacts: return "Contacts"
        case .server: return "Server"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right.fill"
        case .contacts: return "person.2.fill"
        case .server: return "server.rack"
        case .settings: return "gearshape.fill"
        }
    }
}
