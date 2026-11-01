import Foundation
import SwiftUI

enum SettingKind: String, Codable { case bool, choice, int, text, list, timeRange }

struct SettingChoice: Identifiable, Hashable {
    let value: String
    let label: String
    var id: String { value }
}

struct SettingSpec: Identifiable, Hashable {
    var key: String
    var title: String
    var subtitle: String = ""
    var page: String
    var group: String
    var kind: SettingKind
    var defaultValue: String
    var choices: [SettingChoice] = []
    var min: Int? = nil
    var max: Int? = nil
    var step: Int = 1
    var unit: String = ""
    var advanced: Bool = false
    var id: String { key }

    static func == (lhs: SettingSpec, rhs: SettingSpec) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

enum SettingsSchema {
    static let pages: [(key: String, title: String)] = [
        ("general", "General"), ("appearance", "Appearance"), ("chats", "Chats"),
        ("calls", "Calls"), ("attachments", "Attachments"), ("notifications", "Notifications"),
        ("encryption", "Encryption"), ("privacy", "Privacy"), ("security", "Security"),
        ("accounts", "Accounts"), ("storage", "Storage"), ("advanced", "Advanced")
    ]

    static let defaultReactions = ["👍", "❤️", "😂", "😮", "😢", "🎉"]

    private static func b(_ key: String, _ title: String, _ sub: String = "", _ page: String, _ group: String, _ def: Bool = false) -> SettingSpec {
        SettingSpec(key: key, title: title, subtitle: sub, page: page, group: group, kind: .bool, defaultValue: def ? "true" : "false")
    }
    private static func c(_ key: String, _ title: String, _ sub: String = "", _ page: String, _ group: String, _ def: String, _ choices: [(String, String)]) -> SettingSpec {
        SettingSpec(key: key, title: title, subtitle: sub, page: page, group: group, kind: .choice, defaultValue: def,
                    choices: choices.map { SettingChoice(value: $0.0, label: $0.1) })
    }
    private static func i(_ key: String, _ title: String, _ sub: String = "", _ page: String, _ group: String, _ def: Int, _ min: Int, _ max: Int, _ step: Int = 1, _ unit: String = "") -> SettingSpec {
        SettingSpec(key: key, title: title, subtitle: sub, page: page, group: group, kind: .int, defaultValue: "\(def)",
                    min: min, max: max, step: step, unit: unit)
    }
    private static func t(_ key: String, _ title: String, _ sub: String = "", _ page: String, _ group: String, _ def: String = "") -> SettingSpec {
        SettingSpec(key: key, title: title, subtitle: sub, page: page, group: group, kind: .text, defaultValue: def)
    }
    private static func l(_ key: String, _ title: String, _ sub: String = "", _ page: String, _ group: String, _ def: [String] = []) -> SettingSpec {
        SettingSpec(key: key, title: title, subtitle: sub, page: page, group: group, kind: .list, defaultValue: def.joined(separator: "\n"))
    }

    static let specs: [SettingSpec] = [
        // General
        b("general.background", "Run in the background", "Stay connected when Ward is not on screen so messages and calls still arrive", "general", "Background", true),
        b("general.autostart", "Reconnect after a restart", "Reconnect automatically when the app is opened again", "general", "Background"),
        b("general.update_check", "Check for updates", "Ask GitHub once a day for a newer Ward release", "general", "Updates", true),

        // Appearance
        c("appearance.style", "Theme", "Follow the system, or always use light or dark", "appearance", "Colours", "system",
          [("system", "Follow system"), ("light", "Light"), ("dark", "Dark")]),
        c("appearance.accent", "Accent colour", "Used for buttons, switches, links and selected items", "appearance", "Colours", "blue",
          [("blue", "Blue"), ("teal", "Teal"), ("green", "Green"), ("yellow", "Yellow"), ("orange", "Orange"),
           ("red", "Red"), ("pink", "Pink"), ("purple", "Purple"), ("slate", "Slate")]),
        i("appearance.text_scale", "Text size", "Scales every screen in Ward", "appearance", "Text", 100, 80, 200, 10, "%"),
        b("appearance.large_emoji", "Large emoji in emoji-only messages", "", "appearance", "Text", true),
        c("appearance.layout", "Message layout", "How conversation bubbles are drawn", "appearance", "Messages", "cozy",
          [("bubbles", "Bubbles"), ("cozy", "Cozy: names and avatars"), ("compact", "Compact: like IRC")]),
        b("appearance.message_animations", "Animate new messages", "New messages spring into the conversation", "appearance", "Messages", true),
        c("appearance.avatars", "Avatars in chats", "", "appearance", "Messages", "always",
          [("always", "Always"), ("groups", "Groups only"), ("never", "Never")]),
        c("appearance.avatar_shape", "Avatar shape", "", "appearance", "Messages", "circle",
          [("circle", "Circle"), ("rounded", "Rounded square")]),
        c("appearance.time_format", "Time format", "", "appearance", "Messages", "system",
          [("system", "Follow system"), ("12", "12-hour"), ("24", "24-hour")]),
        b("appearance.time_seconds", "Show seconds in message times", "", "appearance", "Messages"),
        c("appearance.list_density", "Chat list density", "", "appearance", "Chat list", "comfortable",
          [("comfortable", "Comfortable"), ("compact", "Compact")]),
        b("appearance.list_previews", "Message previews", "Show the last message under each chat", "appearance", "Chat list", true),

        // Chats
        c("chats.send_with", "Send with", "Choose whether Return sends or starts a new line", "chats", "Writing", "enter",
          [("enter", "Return sends"), ("newline", "Return adds a new line")]),
        l("chats.quick_reactions", "Quick reactions", "The emoji shown in the reaction bar, one per line", "chats", "Messages", defaultReactions),
        c("chats.reaction_skin_tone", "Reaction skin tone", "Used for hand and people reactions", "chats", "Messages", "",
          [("", "Default"), ("🏻", "Light"), ("🏼", "Medium light"), ("🏽", "Medium"), ("🏾", "Medium dark"), ("🏿", "Dark")]),
        b("chats.confirm_delete", "Confirm “Delete for everyone”", "Ask before retracting a message for the other person", "chats", "Messages", true),
        b("chats.link_previews", "Link previews", "Fetch a small Open Graph card for links in messages", "chats", "Sharing", true),
        b("chats.send_typing", "Send typing indicators", "", "chats", "Sharing", true),
        b("chats.show_typing", "Show typing indicators", "", "chats", "Sharing", true),
        b("chats.send_markers", "Send read markers", "", "chats", "Sharing", true),
        b("chats.send_receipts", "Send delivery receipts", "", "chats", "Sharing", true),

        // Calls
        b("calls.enabled", "Audio and video calls", "Jingle signalling is prepared, but audio/video media is not available in this build", "calls", "Calls", true),
        i("calls.speaker_gain", "Speaker volume", "Applied to the other person's audio during calls", "calls", "Audio", 100, 50, 200, 5, "%"),
        b("calls.discover", "Discover STUN/TURN from the server", "Use XEP-0215 external service discovery for call relay servers", "calls", "Network", true),
        t("calls.stun", "STUN servers", "Space-separated stun:host:port addresses", "calls", "Network"),
        t("calls.turn", "TURN servers", "Space-separated turn:host:port addresses; add ?transport=tcp for TCP", "calls", "Network"),
        t("calls.turn_user", "TURN username", "", "calls", "Network"),
        t("calls.turn_password", "TURN password", "", "calls", "Network"),
        t("calls.turn_secret", "TURN shared secret", "For time-limited credentials, as used by coturn and eturnal", "calls", "Network"),
        i("calls.turn_ttl", "TURN credential lifetime", "Seconds; used with the shared secret", "calls", "Network", 86400, 300, 604800, 3600, "seconds"),
        b("calls.relay_only", "Always relay calls", "Use TURN even when a direct connection is possible", "calls", "Network", true),
        c("calls.ringtone", "Ringtone", "Played while an incoming call is ringing", "calls", "Sounds", "ward",
          [("ward", "Ward default"), ("system", "System default"), ("none", "Silent")]),
        c("calls.ringback", "Calling tone", "Played while an outgoing call is ringing", "calls", "Sounds", "ward",
          [("ward", "Ward default"), ("system", "System default"), ("none", "Silent")]),

        // Attachments
        c("attachments.image_compression", "Image compression", "Compress outgoing photos before upload", "attachments", "Sending", "large",
          [("off", "Off"), ("large", "Large images only"), ("always", "Always")]),
        c("attachments.video_quality", "Video quality", "Quality used when preparing outgoing videos", "attachments", "Sending", "medium",
          [("low", "Low (240p)"), ("medium", "Medium (360p)"), ("high", "High (720p)"), ("original", "Original")]),
        c("attachments.auto_download", "Automatic download", "Maximum file size downloaded automatically", "attachments", "Receiving", "1024",
          [("0", "Never"), ("256", "256 KiB"), ("1024", "1024 KiB"), ("5120", "5 MiB"), ("20480", "20 MiB")]),
        b("attachments.accept_unmetered", "Always accept when unmetered", "Don't use the size limit on Wi-Fi and other unmetered networks", "attachments", "Receiving", true),
        b("attachments.hide_gallery", "Hide media from the gallery", "Keep received and sent media out of the Photos library", "attachments", "Receiving"),

        // Notifications
        b("notify.enabled", "Notifications", "Show a notification when a message arrives", "notifications", "Notifications", true),
        c("notify.content", "Show in notification", "", "notifications", "Notifications", "full",
          [("full", "Sender and text"), ("sender", "Sender only"), ("nothing", "Nothing")]),
        b("notify.hide_encrypted", "Hide text for encrypted chats", "", "notifications", "Notifications", true),
        c("notify.groups", "Group chats", "", "notifications", "Notifications", "mentions",
          [("all", "All messages"), ("mentions", "Mentions and replies"), ("none", "None")]),
        l("notify.highlight_words", "Highlight words", "Your nickname always counts; one word per line", "notifications", "Highlights"),
        SettingSpec(key: "notify.quiet_hours", title: "Daily quiet hours", subtitle: "Silence notifications in this range, for example 22:00-07:00", page: "notifications", group: "Quiet hours", kind: .timeRange, defaultValue: ""),
        b("notify.badge", "Unread count on the app icon", "", "notifications", "Notifications", true),
        b("notify.sounds", "Notification sounds", "Play a sound for new messages outside quiet hours", "notifications", "Sounds", true),

        // Encryption
        c("encryption.default", "Default encryption", "Used for new chats; each chat can override it. This build does not yet implement OMEMO", "encryption", "Encryption", "off",
          [("always", "Always (recommended)"), ("available", "When available"), ("off", "Off")]),
        c("encryption.trust", "Trust new devices", "What Ward does the first time a contact adds a device", "encryption", "Encryption", "btbv",
          [("btbv", "Blind trust before verification"), ("manual", "Ask every time")]),
        b("encryption.legacy_omemo", "Allow OMEMO (legacy 0.3)", "Not available in this build yet; explicit OMEMO chats are blocked", "encryption", "Encryption", false),
        b("pgp.enabled", "OpenPGP", "Optional end-to-end encryption with GnuPG keys (XEP-0373)", "encryption", "OpenPGP"),

        // Privacy
        b("privacy.strip_metadata", "Strip photo location and camera data", "Remove EXIF metadata before sending an image", "privacy", "Photos", true),
        c("privacy.strangers", "Messages from strangers", "What to do when someone you have not added writes to you", "privacy", "Strangers", "requests",
          [("requests", "Requests folder"), ("block", "Block"), ("allow", "Allow")]),

        // Security
        b("security.block_screenshots", "Block screenshots and screen recording",
          "Also hides Ward in the app switcher. QR codes and media cannot be captured while this is on.", "security", "Screen privacy"),

        // Advanced
        i("advanced.keepalive", "Keepalive ping interval", "Seconds between pings that keep the connection alive", "advanced", "Connection", 60, 30, 600, 30, "seconds"),
        i("advanced.reconnect_cap", "Reconnect delay cap", "Longest wait between reconnection attempts", "advanced", "Connection", 5, 1, 30, 1, "minutes")
    ]

    static let byKey = Dictionary(uniqueKeysWithValues: specs.map { ($0.key, $0) })
    static func defaults() -> [String: String] {
        Dictionary(uniqueKeysWithValues: specs.map { ($0.key, $0.defaultValue) })
    }
    static func specs(page: String) -> [SettingSpec] { specs.filter { $0.page == page } }
}

final class SettingsStore: ObservableObject {
    @Published private(set) var values: [String: String]
    private let defaults = UserDefaults.standard
    private let prefix = "ward.settings."

    init() {
        var loaded = SettingsSchema.defaults()
        for key in Array(loaded.keys) {
            if let value = defaults.string(forKey: prefix + key) { loaded[key] = value }
        }
        if loaded["appearance.accent"] == "system" { loaded["appearance.accent"] = "blue" }
        if loaded["chats.send_with"] == "ctrl_enter" { loaded["chats.send_with"] = "newline" }
        values = loaded
    }

    func string(_ key: String, _ fallback: String = "") -> String { values[key] ?? fallback }
    func bool(_ key: String) -> Bool { string(key, "false") == "true" }
    func int(_ key: String) -> Int { Int(string(key, "0")) ?? 0 }
    func list(_ key: String) -> [String] {
        string(key).split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    func set(_ key: String, _ value: String) {
        values[key] = value
        defaults.set(value, forKey: prefix + key)
    }
    func setBool(_ key: String, _ value: Bool) { set(key, value ? "true" : "false") }
    func setList(_ key: String, _ value: [String]) { set(key, value.joined(separator: "\n")) }

    var accentName: String { string("appearance.accent", "blue") }
    var accentColor: Color { (WardAccent(rawValue: accentName) ?? .blue).color }
    var isDark: Bool {
        switch string("appearance.style", "system") {
        case "dark": return true
        case "light": return false
        default: return false // resolved against the environment at the view layer
        }
    }
    var textScale: Double { Double(int("appearance.text_scale")) / 100.0 }
}
