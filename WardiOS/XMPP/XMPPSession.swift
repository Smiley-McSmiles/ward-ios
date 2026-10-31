import Foundation

/// High-level XMPP session for one account. It owns the wire connection, translates stanzas into
/// the same entities the Android app stores, and keeps the local database in sync.
@MainActor
final class XMPPSession {
    let accountId: Int64
    var account: Account
    private let password: String
    let database: WardDatabase
    let settings: SettingsStore

    var connection: XMPPConnection?
    private(set) var state = ConnectionState(state: "offline", step: "Offline")
    private(set) var isOnline = false
    private var manualStop = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var processing: Task<Void, Never>?
    private var pendingIQs: [String: PendingIQ] = [:]
    var roster: [String: Contact] = [:]
    var joinedRooms: Set<String> = []
    var occupants: [String: [String: RoomOccupant]] = [:]
    var ourNicks: [String: String] = [:]
    var activeChatId: Int64?
    var appForeground = true
    var warnedAboutEncryption = false
    var uploadService: UploadService?
    var discoCommands: [AdminCommand] = []
    private var lastPresenceShow = "online"
    private var lastPresenceStatus = ""
    var vcardRequested: Set<String> = []
    var activeCall: CallState?

    // Event callbacks. The app model installs these once and reacts on the main actor.
    var onStateChange: ((ConnectionState) -> Void)?
    var onChatChanged: ((Chat) -> Void)?
    var onChatsChanged: (() -> Void)?
    var onMessage: ((Message, Chat) -> Void)?
    var onMessageChanged: ((Message) -> Void)?
    var onContactChanged: ((Contact) -> Void)?
    var onRequest: ((ContactRequest) -> Void)?
    var onTyping: ((Int64, String) -> Void)?
    var onMembers: ((String, [RoomOccupant]) -> Void)?
    var onDevicesChanged: ((String) -> Void)?
    var onCallChanged: ((CallState?) -> Void)?
    var onXml: ((Bool, String) -> Void)?
    var onToast: ((String, Bool) -> Void)?
    var onCommands: (([AdminCommand]) -> Void)?

    init(account: Account, password: String, database: WardDatabase, settings: SettingsStore) {
        self.accountId = account.id
        self.account = account
        self.password = password
        self.database = database
        self.settings = settings
    }

    // MARK: - Lifecycle

    func start() {
        manualStop = false
        guard !password.isEmpty else {
            updateState(ConnectionState(state: "error", step: "Password required", error: "Enter your password to connect."))
            return
        }
        connect()
    }

    func stop() {
        manualStop = true
        reconnectTask?.cancel(); reconnectTask = nil
        processing?.cancel(); processing = nil
        for (_, pending) in pendingIQs { pending.complete(nil) }
        pendingIQs.removeAll()
        connection?.disconnect()
        connection = nil
        isOnline = false
        updateState(ConnectionState(state: "offline", step: "Offline"))
    }

    func setActiveChat(_ id: Int64?) { activeChatId = id }
    func setForeground(_ value: Bool) { appForeground = value }

    private func connect() {
        reconnectTask?.cancel(); reconnectTask = nil
        connection?.disconnect()
        let host = account.options["host"].flatMap { $0.isEmpty ? nil : $0 } ?? account.domain
        let port = account.options["port"].flatMap { UInt16($0) }
        let tls = account.options["tls"] ?? "auto"
        let configuration = XMPPConfiguration(
            jid: account.jid,
            password: password,
            host: host,
            port: port,
            tlsMode: tls == "starttls" ? "required" : tls,
            resource: "Ward",
            allowPlain: true,
            allowInvalidCertificates: true,
            keepalive: TimeInterval(max(30, settings.int("advanced.keepalive")))
        )
        let connection = XMPPConnection(configuration: configuration)
        self.connection = connection
        connection.onState = { [weak self] state in self?.updateState(state) }
        connection.onStanza = { [weak self] node in self?.handleStanza(node) }
        connection.onReady = { [weak self] in self?.becameReady() }
        connection.onError = { [weak self] message in self?.connectionFailed(message) }
        connection.onRawIn = { [weak self] xml in self?.onXml?(true, xml) }
        connection.onRawOut = { [weak self] xml in self?.onXml?(false, xml) }
        connection.connect()
    }

    private func updateState(_ value: ConnectionState) {
        state = value
        isOnline = value.state == "online"
        if isOnline { reconnectAttempt = 0 }
        onStateChange?(value)
    }

    private func connectionFailed(_ message: String) {
        guard !manualStop else { return }
        isOnline = false
        updateState(ConnectionState(state: "error", step: "Reconnecting…", error: message))
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !manualStop, reconnectTask == nil else { return }
        reconnectAttempt += 1
        let cap = max(1, settings.int("advanced.reconnect_cap")) * 60
        let base = min(pow(2.0, Double(reconnectAttempt - 1)) * 3, Double(cap))
        let delay = base + Double.random(in: 0...1.5)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }

    private func becameReady() {
        reconnectAttempt = 0
        isOnline = true
        Task { await bootstrap() }
    }

    // MARK: - Bootstrap

    private func bootstrap() async {
        sendPresence(show: lastPresenceShow, status: lastPresenceStatus)
        await syncRoster()
        enableCarbons()
        await fetchBlockList()
        await syncRecentArchive()
        await discoverUploadService()
        await loadBookmarks()
        Task { await self.discoverCommands() }
    }

    private func syncRoster() async {
        guard let result = await iqRequest("<query xmlns='\(NS.roster)'/>", timeout: 25) else { return }
        var seen: Set<String> = []
        for item in result.child("query", xmlns: NS.roster)?.children("item") ?? [] {
            guard let jid = item.attr("jid"), !jid.isEmpty else { continue }
            let bare = JID.bare(jid)
            seen.insert(bare)
            let stored = await storedContact(bare)
            var contact = roster[bare] ?? stored ?? Contact(accountId: accountId, jid: bare)
            contact.rosterName = item.attr("name", "")
            contact.subscription = item.attr("subscription", "none")
            contact.ask = item.attr("ask", "")
            contact.groups = item.children("group").map { $0.trimmedText }.filter { !$0.isEmpty }
            contact.inRoster = true
            contact.accountId = accountId
            roster[bare] = contact
            try? await database.saveContact(contact)
            onContactChanged?(contact)
            if contact.avatar.isEmpty { requestVCardAvatar(bare) }
        }
        let existing = (try? await database.contacts(accountId: accountId)) ?? []
        for contact in existing where !seen.contains(contact.jid) && contact.inRoster && !contact.isGateway {
            try? await database.deleteContact(accountId: accountId, jid: contact.jid)
        }
        onChatsChanged?()
    }

    private func enableCarbons() {
        _ = connection?.send("<iq type='set' id='ward-carbons'><enable xmlns='\(NS.carbons)'/></iq>")
    }

    private func fetchBlockList() async {
        guard let result = await iqRequest("<blocklist xmlns='\(NS.blocklist)'/>", timeout: 12),
              let list = result.child("blocklist", xmlns: NS.blocklist) else { return }
        let blocked = Set(list.children("item").compactMap { $0.attr("jid") }.map(JID.bare))
        let contacts = (try? await database.contacts(accountId: accountId)) ?? []
        for var contact in contacts {
            contact.blocked = blocked.contains(contact.jid)
            try? await database.saveContact(contact)
            roster[contact.jid] = contact
            onContactChanged?(contact)
        }
    }

    func sendPresence(show: String, status: String) {
        lastPresenceShow = show
        lastPresenceStatus = status
        if show == "offline" {
            _ = connection?.send("<presence type='unavailable'/>")
            return
        }
        var children: [String] = []
        if show != "online" && !show.isEmpty { children.append("<show>\(show)</show>") }
        if !status.isEmpty { children.append("<status>\(XML.escape(status))</status>") }
        children.append("<c xmlns='http://jabber.org/protocol/caps' hash='sha-1' node='https://ward.chat/ios' ver='0.1'/>")
        let stanza = "<presence>\(children.joined())</presence>"
        _ = connection?.send(stanza)
    }

    func setPresence(show: String, status: String = "") {
        sendPresence(show: show, status: status)
    }

    // MARK: - Inbound routing

    private func handleStanza(_ node: XMLNode) {
        switch node.name {
        case "message":
            if let sent = node.child("sent", xmlns: NS.carbons) ?? node.child("received", xmlns: NS.carbons),
               let forwarded = sent.child("forwarded", xmlns: NS.forward),
               let inner = forwarded.child("message") {
                enqueue { await self.processMessage(inner, directionOverride: node.child("sent", xmlns: NS.carbons) != nil ? 1 : 0, timestampOverride: Date.fromXMPP(forwarded.child("delay")?.attr("stamp")), mam: false) }
                return
            }
            if let result = node.child("result", xmlns: NS.mam),
               let forwarded = result.child("forwarded", xmlns: NS.forward),
               let inner = forwarded.child("message") {
                enqueue { await self.processMessage(inner, directionOverride: nil, timestampOverride: Date.fromXMPP(forwarded.child("delay")?.attr("stamp")), mam: true) }
                return
            }
            enqueue { await self.processMessage(node) }
        case "presence":
            processPresence(node)
        case "iq":
            handleIQ(node)
        default:
            break
        }
    }

    func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = processing
        processing = Task { @MainActor in
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    private func handleIQ(_ node: XMLNode) {
        let id = node.attr("id", "")
        if node.attr("type") == "get", node.child("ping", xmlns: NS.ping) != nil {
            _ = connection?.send("<iq type='result' id='\(XML.escape(id))' from='\(XML.escape(account.bareJID))'/>")
            return
        }
        if !id.isEmpty, let pending = pendingIQs[id] {
            pending.complete(node)
            return
        }
        if node.attr("type") == "set", node.child("query", xmlns: NS.roster) != nil {
            if let item = node.child("query", xmlns: NS.roster)?.child("item"), let jid = item.attr("jid") {
                enqueue { await self.applyRosterPush(item, jid: JID.bare(jid)) }
            }
            _ = connection?.send("<iq type='result' id='\(XML.escape(id))'/>")
            return
        }
        if node.attr("type") == "get" || node.attr("type") == "set" {
            _ = connection?.send("<iq type='error' id='\(XML.escape(id))' from='\(XML.escape(account.bareJID))'><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
        }
    }

    private func applyRosterPush(_ item: XMLNode, jid: String) async {
        if item.attr("subscription") == "remove" {
            try? await database.deleteContact(accountId: accountId, jid: jid)
            roster.removeValue(forKey: jid)
            onChatsChanged?()
            return
        }
        let stored = await storedContact(jid)
        var contact = roster[jid] ?? stored ?? Contact(accountId: accountId, jid: jid)
        contact.rosterName = item.attr("name", "")
        contact.subscription = item.attr("subscription", contact.subscription)
        contact.ask = item.attr("ask", "")
        contact.groups = item.children("group").map { $0.trimmedText }
        contact.inRoster = true
        roster[jid] = contact
        try? await database.saveContact(contact)
        onContactChanged?(contact)
    }

    func processPresence(_ node: XMLNode) {
        guard let from = node.attr("from") else { return }
        let bare = JID.bare(from)
        let type = node.attr("type", "available")
        if joinedRooms.contains(bare), JID.resource(from) != nil {
            processRoomPresence(node, room: bare)
            return
        }
        if type == "subscribe" {
            enqueue { await self.receiveSubscription(from: bare) }
            return
        }
        if type == "unsubscribe" {
            return
        }
        if type == "subscribed" {
            enqueue { await self.subscriptionApproved(bare) }
            return
        }
        if type == "unsubscribed" {
            return
        }
        enqueue { await self.updatePresence(bare: bare, node: node, unavailable: type == "unavailable") }
    }

    private func updatePresence(bare: String, node: XMLNode, unavailable: Bool) async {
        let stored = await storedContact(bare)
        let existing = roster[bare] ?? stored
        if existing == nil && unavailable { return }
        var contact = existing ?? Contact(accountId: accountId, jid: bare, inRoster: false)
        let show = unavailable ? "offline" : (node.child("show")?.trimmedText ?? "online")
        contact.presence = show == "" ? "online" : show
        contact.status = node.child("status")?.trimmedText ?? ""
        if unavailable { contact.lastSeen = Date().millis }
        try? await database.saveContact(contact)
        roster[bare] = contact
        onContactChanged?(contact)
        if let photo = node.child("x", xmlns: "vcard-temp:x:update")?.child("photo")?.trimmedText, !photo.isEmpty, contact.avatar.isEmpty {
            requestVCardAvatar(bare)
        }
    }

    private func receiveSubscription(from jid: String) async {
        guard jid != account.bareJID else { return }
        let stored = await storedContact(jid)
        var contact = roster[jid] ?? stored ?? Contact(accountId: accountId, jid: jid, inRoster: false)
        if contact.blocked { return }
        contact.ask = "subscribe"
        roster[jid] = contact
        try? await database.saveContact(contact)
        let chat = await ensureChat(jid: jid, type: .chat, name: contact.name)
        var updated = chat
        updated.isRequest = true
        updated = (try? await database.saveChat(updated)) ?? updated
        let request = ContactRequest(accountId: accountId, jid: jid, kind: "subscription",
                                     text: "wants to add you to their contact list", chatId: updated.id)
        try? await database.saveRequest(request)
        onChatChanged?(updated)
        onRequest?(request)
        onContactChanged?(contact)
    }

    private func subscriptionApproved(_ jid: String) async {
        if var contact = roster[jid] {
            contact.subscription = "to"
            roster[jid] = contact
            try? await database.saveContact(contact)
            onContactChanged?(contact)
        }
        try? await database.deleteRequest(accountId: accountId, jid: jid)
        onChatsChanged?()
    }

    // MARK: - IQ plumbing

    private final class PendingIQ {
        private var continuation: CheckedContinuation<XMLNode?, Never>?
        private var finished = false
        var timeoutTask: Task<Void, Never>?
        init(_ continuation: CheckedContinuation<XMLNode?, Never>) { self.continuation = continuation }
        func complete(_ value: XMLNode?) {
            guard !finished else { return }
            finished = true
            timeoutTask?.cancel()
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    func iqRequest(_ inner: String, to: String? = nil, type: String = "get", timeout: TimeInterval = 20) async -> XMLNode? {
        guard isOnline, let connection else { return nil }
        let id = "ward-\(UUID().uuidString.lowercased())"
        let toAttribute = to.map { " to='\(XML.escape($0))'" } ?? ""
        let xml = "<iq type='\(type)' id='\(id)'\(toAttribute)>\(inner)</iq>"
        return await withCheckedContinuation { continuation in
            let pending = PendingIQ(continuation)
            pendingIQs[id] = pending
            pending.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finishIQ(id, nil)
            }
            if !connection.send(xml) { finishIQ(id, nil) }
        }
    }

    private func finishIQ(_ id: String, _ value: XMLNode?) {
        guard let pending = pendingIQs.removeValue(forKey: id) else { return }
        pending.complete(value)
    }

    func sendRaw(_ xml: String) -> Bool {
        connection?.send(xml) ?? false
    }

    // MARK: - Chat helpers

    func storedContact(_ jid: String) async -> Contact? {
        (try? await database.contacts(accountId: accountId))?.first { $0.jid == jid }
    }

    func ensureChat(jid: String, type: ChatType = .chat, name: String = "") async -> Chat {
        if let existing = try? await database.chat(accountId: accountId, jid: jid) { return existing }
        let contact = roster[jid]
        let chatName = name.isEmpty ? (contact?.name ?? JID.local(jid)) : name
        let chat = Chat(accountId: accountId, jid: jid, type: type.rawValue, name: chatName,
                        lastActivity: Date().millis, joined: type == .groupchat ? false : true)
        let saved = (try? await database.saveChat(chat)) ?? chat
        onChatChanged?(saved)
        return saved
    }

    func contactName(_ jid: String) -> String {
        if let contact = roster[JID.bare(jid)] { return contact.name }
        return JID.local(jid)
    }

    func touchChat(_ chat: Chat, message: Message, outgoing: Bool) async -> Chat {
        var updated = chat
        updated.lastActivity = message.timestamp
        updated.previewSender = outgoing ? "You" : message.senderName
        if message.retracted {
            updated.preview = "Message deleted"
        } else if !message.attachments.isEmpty {
            updated.preview = message.body.isEmpty ? "📎 Attachment" : message.body
        } else if message.kind == MessageKind.system.rawValue {
            updated.preview = message.body
        } else {
            updated.preview = message.body.replacingOccurrences(of: "\n", with: " ")
        }
        if !outgoing {
            if activeChatId == chat.id && appForeground {
                updated.unread = 0
                updated.mentions = 0
                updated.lastReadId = message.id
            } else {
                updated.unread += 1
                if message.mentionsMe { updated.mentions += 1 }
            }
            updated.archived = false
        }
        updated = (try? await database.saveChat(updated)) ?? updated
        onChatChanged?(updated)
        return updated
    }

    func setDraft(_ chat: Chat, draft: String) async {
        var value = chat
        value.draft = draft
        let saved = (try? await database.saveChat(value)) ?? value
        onChatChanged?(saved)
    }

    func markRead(_ chat: Chat) async {
        guard var current = try? await database.chat(id: chat.id) else { return }
        current.unread = 0
        current.mentions = 0
        let messages = (try? await database.messages(chatId: current.id, limit: 600)) ?? []
        if let last = messages.last(where: { !$0.isOutgoing }) {
            current.lastReadId = last.id
            sendDisplayed(chat: current, message: last)
            sendReceipt(chat: current, stanzaId: last.stanzaId)
        }
        let saved = (try? await database.saveChat(current)) ?? current
        onChatChanged?(saved)
    }
}
