import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var contacts: [Contact] = []
    @Published private(set) var chats: [Chat] = []
    @Published private(set) var requests: [ContactRequest] = []
    @Published private(set) var messages: [Int64: [Message]] = [:]
    @Published private(set) var devices: [String: [Device]] = [:]
    @Published private(set) var members: [String: [RoomOccupant]] = [:]
    @Published private(set) var commands: [AdminCommand] = []
    @Published private(set) var states: [Int64: ConnectionState] = [:]
    @Published private(set) var typing: [Int64: String] = [:]
    @Published private(set) var xmlLog: [XmlLogEntry] = []
    @Published var selectedChatId: Int64? = nil
    @Published var call: CallState? = nil
    @Published var toast: String? = nil
    @Published var toastIsError = false
    @Published var isReady = false
    @Published var startupError: String? = nil
    @Published var isForeground = true

    let settings: SettingsStore
    private(set) var database: WardDatabase?
    private var sessions: [Int64: XMPPSession] = [:]
    private var passwords: [Int64: String] = [:]
    private var typingTasks: [Int64: Task<Void, Never>] = [:]
    private var toastTask: Task<Void, Never>?
    private var scheduledTasks: [Int64: Task<Void, Never>] = [:]
    private var started = false

    init() {
        settings = SettingsStore()
    }

    // MARK: - Startup

    func start() {
        guard !started else { return }
        started = true
        Task {
            do {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                let url = support.appendingPathComponent("ward.sqlite")
                database = try WardDatabase(url: url)
                await reloadAll()
                isReady = true
                for account in accounts where account.enabled {
                    connect(account)
                }
                await resumeScheduledMessages()
            } catch {
                startupError = error.localizedDescription
                isReady = true
            }
        }
    }

    func reloadAll() async {
        guard let database else { return }
        accounts = (try? await database.accounts()) ?? []
        contacts = (try? await database.contacts()) ?? []
        chats = (try? await database.chats()) ?? []
        requests = (try? await database.requests()) ?? []
        if let id = selectedChatId, chats.first(where: { $0.id == id }) == nil {
            selectedChatId = nil
        }
    }

    // MARK: - Sessions

    func connect(_ account: Account) {
        guard let database else { return }
        let password = passwords[account.id] ?? SecureStore.shared.get("password.\(account.jid)") ?? ""
        if let existing = sessions[account.id] { existing.stop() }
        guard !password.isEmpty else {
            states[account.id] = ConnectionState(state: "error", step: "Password required", error: "Sign in again to reconnect this account.")
            return
        }
        let session = XMPPSession(account: account, password: password, database: database, settings: settings)
        wire(session)
        sessions[account.id] = session
        session.start()
    }

    func disconnect(_ account: Account) {
        sessions[account.id]?.stop()
        sessions.removeValue(forKey: account.id)
        states[account.id] = ConnectionState(state: "offline", step: "Offline")
    }

    private func wire(_ session: XMPPSession) {
        let accountId = session.accountId
        session.onStateChange = { [weak self] state in
            self?.states[accountId] = state
        }
        session.onChatChanged = { [weak self] chat in self?.upsert(chat: chat) }
        session.onChatsChanged = { [weak self] in
            Task { await self?.reloadChats() }
        }
        session.onMessage = { [weak self] message, chat in
            self?.receive(message: message, chat: chat)
        }
        session.onMessageChanged = { [weak self] message in
            self?.replace(message: message)
        }
        session.onContactChanged = { [weak self] contact in
            self?.upsert(contact: contact)
        }
        session.onRequest = { [weak self] request in
            guard let self else { return }
            if !self.requests.contains(where: { $0.id == request.id }) { self.requests.insert(request, at: 0) }
        }
        session.onTyping = { [weak self] chatId, who in
            guard let self else { return }
            if who.isEmpty { self.typing.removeValue(forKey: chatId) }
            else { self.typing[chatId] = who }
        }
        session.onMembers = { [weak self] room, list in self?.members[room] = list }
        session.onDevicesChanged = { [weak self] jid in
            Task { await self?.reloadDevices(accountId: accountId, jid: jid) }
        }
        session.onCallChanged = { [weak self] call in self?.call = call }
        session.onXml = { [weak self] incoming, xml in
            guard let self else { return }
            self.xmlLog.append(XmlLogEntry(time: Date(), accountId: accountId, incoming: incoming, text: xml))
            if self.xmlLog.count > 600 { self.xmlLog.removeFirst(self.xmlLog.count - 600) }
        }
        session.onToast = { [weak self] text, error in self?.showToast(text, error: error) }
        session.onCommands = { [weak self] commands in self?.commands = commands }
    }

    func session(for accountId: Int64) -> XMPPSession? { sessions[accountId] }

    func setForeground(_ value: Bool) {
        isForeground = value
        for session in sessions.values { session.setForeground(value) }
    }

    func reply(to chatId: Int64, text: String) {
        guard let chat = chat(id: chatId), let session = sessions[chat.accountId] else { return }
        Task { await session.sendText(chat: chat, text: text) }
    }

    func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "xmpp" else { return }
        let raw = url.absoluteString.replacingOccurrences(of: "xmpp:", with: "")
        let target = raw.split(separator: "?").first.map(String.init) ?? raw
        guard target.contains("@"), let account = accounts.first else { return }
        let jid = target.contains("/") || target.contains(":") ? String(target.split(separator: "/").first ?? "") : target
        guard JID.valid(jid) else { return }
        Task { await openChat(accountId: account.id, jid: JID.bare(jid)) }
    }

    // MARK: - Accounts

    @discardableResult
    func addAccount(jid rawJID: String, password: String, remember: Bool,
                    host: String = "", port: String = "", tls: String = "auto",
                    label: String = "") async throws -> Account {
        guard let database else { throw WardError.database("The database is not ready.") }
        let trimmed = rawJID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@"), JID.valid(trimmed) else {
            throw WardError.authentication("Enter an address like you@example.org.")
        }
        let jid = JID.bare(trimmed)
        guard !accounts.contains(where: { $0.jid.caseInsensitiveCompare(jid) == .orderedSame }) else {
            throw WardError.authentication("This account is already added.")
        }
        let colors = ["#3584E4", "#9141AC", "#26A269", "#E66100", "#C88800", "#2190A4"]
        var options: [String: String] = [:]
        if !host.trimmingCharacters(in: .whitespaces).isEmpty { options["host"] = host.trimmingCharacters(in: .whitespaces) }
        if let value = UInt16(port), value != 0 { options["port"] = String(value) }
        if tls != "auto" { options["tls"] = tls }
        var account = Account(jid: jid, color: colors[accounts.count % colors.count],
                              options: options, nickname: accounts.first?.nickname ?? "",
                              createdAt: Date().millis)
        account.label = label
        account = try await database.saveAccount(account)
        accounts.append(account)
        passwords[account.id] = password
        if remember { SecureStore.shared.set(password, for: "password.\(jid)") }
        connect(account)
        NotificationManager.shared.requestAuthorization()
        return account
    }

    func deleteAccount(_ account: Account) async {
        guard let database else { return }
        disconnect(account)
        SecureStore.shared.remove("password.\(account.jid)")
        try? await database.deleteAccount(id: account.id)
        accounts.removeAll { $0.id == account.id }
        contacts.removeAll { $0.accountId == account.id }
        chats.removeAll { $0.accountId == account.id }
        sessions.removeValue(forKey: account.id)
    }

    func updateAccount(_ account: Account) async {
        guard let database else { return }
        if let saved = try? await database.saveAccount(account) {
            if let index = accounts.firstIndex(where: { $0.id == saved.id }) { accounts[index] = saved }
        }
    }

    func setAccountOption(_ account: Account, key: String, value: String) async {
        guard var updated = self.account(id: account.id) else { return }
        updated.options[key] = value
        await updateAccount(updated)
    }

    func publishAvatar(accountId: Int64, data: Data) {
        guard let account = account(id: accountId) else { return }
        Task {
            await sessions[accountId]?.publishAvatar(data, mime: "image/jpeg")
            var updated = account
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Avatars", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("own-avatar-\(accountId).jpg")
            try? data.write(to: file)
            updated.avatar = file.path
            await updateAccount(updated)
            showToast("Profile photo updated.")
        }
    }

    func registerAccount(jid rawJID: String, password: String,
                         host: String = "", port: String = "", tls: String = "auto") async throws -> Account {
        let trimmed = rawJID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@"), JID.valid(trimmed) else {
            throw WardError.authentication("Enter an address like you@example.org.")
        }
        let jid = JID.bare(trimmed)
        guard !accounts.contains(where: { $0.jid.caseInsensitiveCompare(jid) == .orderedSame }) else {
            throw WardError.authentication("This account is already added.")
        }
        guard password.count >= 4 else { throw WardError.authentication("Choose a password with at least four characters.") }
        let domain = JID.domain(jid)
        let configuration = XMPPConfiguration(
            jid: jid, password: password,
            host: host.trimmingCharacters(in: .whitespaces).isEmpty ? domain : host.trimmingCharacters(in: .whitespaces),
            port: UInt16(port), tlsMode: tls == "starttls" ? "required" : tls,
            resource: "Ward", registration: XMPPRegistrationRequest(username: JID.local(jid), password: password))
        let connection = XMPPConnection(configuration: configuration)
        let waiter = RegistrationWaiter()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiter.continuation = continuation
            connection.onRegistered = { waiter.finish($0) }
            connection.onError = { message in
                waiter.finish(.failure(WardError.authentication(message)))
            }
            connection.connect()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 35_000_000_000)
                waiter.finish(.failure(WardError.network("The server did not answer the account request. It may require a captcha or another registration method.")))
            }
        }
        connection.disconnect()
        return try await addAccount(jid: jid, password: password, remember: true,
                                    host: host, port: port, tls: tls)
    }

    // MARK: - Chats

    func chat(id: Int64) -> Chat? { chats.first { $0.id == id } }
    var selectedChat: Chat? { selectedChatId.flatMap { self.chat(id: $0) } }
    func contact(jid: String, accountId: Int64) -> Contact? {
        contacts.first { $0.accountId == accountId && $0.jid == JID.bare(jid) }
    }
    func account(id: Int64) -> Account? { accounts.first { $0.id == id } }
    func messages(for chatId: Int64) -> [Message] { messages[chatId] ?? [] }

    func selectChat(_ id: Int64?) {
        selectedChatId = id
        for session in sessions.values {
            session.setActiveChat(nil)
        }
        guard let id, let chat = chat(id: id) else { return }
        sessions[chat.accountId]?.setActiveChat(id)
        Task {
            await loadMessages(chatId: id)
            sessions[chat.accountId]?.setActiveChat(id)
            await markRead(chat: chat)
        }
    }

    func searchAllMessages(_ query: String) async -> [Message] {
        guard let database else { return [] }
        return (try? await database.search(chatId: nil, query: query)) ?? []
    }

    func loadMessages(chatId: Int64) async {
        guard let database else { return }
        messages[chatId] = (try? await database.messages(chatId: chatId)) ?? []
    }

    func openChat(accountId: Int64, jid: String, type: ChatType = .chat, name: String = "") async {
        guard let session = sessions[accountId] else {
            showToast("Connect this account first.", error: true); return
        }
        let bare = JID.bare(jid)
        var chat = await session.ensureChat(jid: bare, type: type, name: name)
        chat.isRequest = false
        if let database, let saved = try? await database.saveChat(chat) { chat = saved }
        upsert(chat: chat)
        if let request = requests.first(where: { $0.accountId == accountId && $0.jid == bare }) {
            try? await database?.deleteRequest(accountId: accountId, jid: bare)
            requests.removeAll { $0.accountId == accountId && $0.jid == bare }
            _ = request
        }
        selectChat(chat.id)
    }

    func ensureChat(accountId: Int64, jid: String, type: ChatType = .chat, name: String = "") async -> Chat? {
        await openChat(accountId: accountId, jid: jid, type: type, name: name)
        return selectedChat
    }

    func send(_ text: String, replyTo: Message? = nil) {
        guard let chat = selectedChat, let session = sessions[chat.accountId] else {
            showToast("Not connected.", error: true); return
        }
        Task {
            await session.sendText(chat: chat, text: text, replyTo: replyTo)
            await session.setDraft(chat, draft: "")
        }
    }

    func sendFiles(_ urls: [URL], caption: String = "") {
        guard let chat = selectedChat, let session = sessions[chat.accountId] else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let name = url.lastPathComponent
            let mime = Self.mimeType(for: url)
            var imageSize = CGSize.zero
            if let image = UIImage(data: data) { imageSize = image.size }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
            try? data.write(to: temp)
            Task {
                await session.sendAttachment(chat: chat, fileURL: temp, name: name, mime: mime,
                                             caption: caption, width: Double(imageSize.width), height: Double(imageSize.height))
                try? FileManager.default.removeItem(at: temp)
            }
        }
    }

    func sendPhoto(_ data: Data, name: String = "photo.jpg", caption: String = "") {
        guard let chat = selectedChat, let session = sessions[chat.accountId] else { return }
        let image = UIImage(data: data)
        let prepared = Self.prepareImage(data, settings: settings)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
        try? prepared.write(to: temp)
        Task {
            await session.sendAttachment(chat: chat, fileURL: temp, name: name, mime: "image/jpeg",
                                         caption: caption, width: Double(image?.size.width ?? 0), height: Double(image?.size.height ?? 0))
            try? FileManager.default.removeItem(at: temp)
        }
    }

    func scheduleMessage(_ text: String, at date: Date) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let chat = selectedChat, let database else { return }
        let id = String.wardID()
        var message = Message(chatId: chat.id, stanzaId: id, originId: id,
                              sender: account(id: chat.accountId)?.bareJID ?? "",
                              senderName: "You", direction: 1,
                              timestamp: Date().millis, body: body, isMarkdown: true,
                              kind: "text", status: 0, scheduledAt: max(date.millis, Date().millis + 1000))
        guard let stored = try? await database.insertMessage(message) else { return }
        message = stored
        messages[chat.id, default: []].append(stored)
        messages[chat.id]?.sort { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        var updated = chat
        updated.preview = "Scheduled: \(body)"
        updated.previewSender = "You"
        updated.lastActivity = Date().millis
        if let saved = try? await database.saveChat(updated) { upsert(chat: saved) }
        scheduleFire(message: stored, chat: chat)
        showToast("Message scheduled for \(date.formatted(date: .abbreviated, time: .shortened)).")
    }

    func cancelScheduled(_ message: Message) async {
        scheduledTasks[message.id]?.cancel()
        scheduledTasks.removeValue(forKey: message.id)
        try? await database?.deleteMessage(id: message.id)
        if var list = messages[message.chatId] {
            list.removeAll { $0.id == message.id }
            messages[message.chatId] = list
        }
        if self.chat(id: message.chatId) != nil { await reloadChats() }
    }

    private func resumeScheduledMessages() async {
        guard let database else { return }
        let pending = (try? await database.scheduledMessages()) ?? []
        for message in pending {
            guard let chat = chat(id: message.chatId) else { continue }
            scheduleFire(message: message, chat: chat)
        }
    }

    private func scheduleFire(message: Message, chat: Chat) {
        scheduledTasks[message.id]?.cancel()
        let when = message.scheduledAt ?? Date().millis
        let delay = max(0.2, Double(when - Date().millis) / 1000.0)
        scheduledTasks[message.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.fireScheduled(messageId: message.id, chat: chat)
        }
    }

    private func fireScheduled(messageId: Int64, chat: Chat) async {
        scheduledTasks.removeValue(forKey: messageId)
        guard let database, let latest = try? await database.message(id: messageId),
              latest.scheduledAt != nil else { return }
        guard let session = sessions[chat.accountId], session.isOnline else {
            // Stay scheduled and try again shortly instead of silently losing the message.
            var retry = latest
            retry.scheduledAt = Date().addingTimeInterval(60).millis
            try? await database.updateMessage(retry)
            scheduleFire(message: retry, chat: chat)
            return
        }
        await session.sendScheduled(chat: chat, message: latest)
    }

    func sendVoice(_ url: URL, duration: Double) {
        guard let chat = selectedChat, let session = sessions[chat.accountId] else { return }
        Task {
            await session.sendAttachment(chat: chat, fileURL: url, name: "voice-message.m4a",
                                         mime: "audio/mp4", caption: "", isVoice: true, duration: duration)
        }
    }

    func setDraft(_ text: String) {
        guard let chat = selectedChat, let session = sessions[chat.accountId] else { return }
        Task { await session.setDraft(chat, draft: text) }
    }

    func typing(_ composing: Bool) {
        guard let chat = selectedChat, let session = sessions[chat.accountId] else { return }
        typingTasks[chat.id]?.cancel()
        if composing {
            session.sendTyping(chat: chat, composing: true)
            typingTasks[chat.id] = Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                session.sendTyping(chat: chat, composing: false)
            }
        } else {
            session.sendTyping(chat: chat, composing: false)
        }
    }

    func markRead(chat: Chat) async {
        sessions[chat.accountId]?.setActiveChat(chat.id)
        await sessions[chat.accountId]?.markRead(chat)
    }

    func react(_ message: Message, emoji: String) {
        guard let chat = selectedChat, let session = sessions[chat.accountId] else { return }
        Task { await session.react(chat: chat, message: message, emoji: emoji) }
    }

    func edit(_ message: Message, text: String) {
        guard let chat = selectedChat, let session = sessions[chat.accountId] else { return }
        Task { await session.edit(chat: chat, message: message, text: text) }
    }

    func retract(_ message: Message) {
        guard let chat = selectedChat, let session = sessions[chat.accountId] else { return }
        Task { await session.retract(chat: chat, message: message) }
    }

    func forward(_ message: Message, to chat: Chat) {
        guard let session = sessions[chat.accountId] else { return }
        Task { await session.forward(message, to: chat) }
    }

    func setPinned(_ chat: Chat, _ value: Bool) async { await update(chat) { $0.pinned = value } }
    func setMuted(_ chat: Chat, until: Int64) async { await update(chat) { $0.mutedUntil = until } }
    func setArchived(_ chat: Chat, _ value: Bool) async { await update(chat) { $0.archived = value } }
    func setEncryption(_ chat: Chat, _ value: EncryptionMode) async { await update(chat) { $0.encryption = value.rawValue } }
    func setNotify(_ chat: Chat, _ value: String) async { await update(chat) { $0.notify = value } }

    private func update(_ chat: Chat, _ change: (inout Chat) -> Void) async {
        var value = chat
        change(&value)
        if let database, let saved = try? await database.saveChat(value) { upsert(chat: saved) }
    }

    func exportChat(_ chat: Chat) async -> URL? {
        let all = (try? await database?.messages(chatId: chat.id, limit: 5000)) ?? messages(for: chat.id)
        let contact = self.contact(jid: chat.jid, accountId: chat.accountId)
        do {
            return try ChatExport.write(chat: chat, messages: all, contact: contact)
        } catch {
            showToast("Could not export this chat.", error: true)
            return nil
        }
    }

    func clearHistory(_ chat: Chat) async {
        guard let database else { return }
        try? await database.clearMessages(chatId: chat.id)
        messages[chat.id] = []
        var value = chat
        value.preview = ""
        value.previewSender = ""
        value.unread = 0
        value.mentions = 0
        if let saved = try? await database.saveChat(value) { upsert(chat: saved) }
    }

    func closeChat(_ chat: Chat) async {
        if chat.isGroup, let session = sessions[chat.accountId] { await session.leaveRoom(chat) }
        var value = chat
        value.open = false
        if let database, let saved = try? await database.saveChat(value) { upsert(chat: saved) }
        if selectedChatId == chat.id { selectChat(nil) }
    }

    func deleteChat(_ chat: Chat) async {
        if chat.isGroup, let session = sessions[chat.accountId] { await session.leaveRoom(chat) }
        try? await database?.deleteChat(id: chat.id)
        chats.removeAll { $0.id == chat.id }
        messages.removeValue(forKey: chat.id)
        if selectedChatId == chat.id { selectChat(nil) }
    }

    func markAllRead() async {
        for chat in chats where chat.unread > 0 {
            var value = chat
            value.unread = 0
            value.mentions = 0
            if let database, let saved = try? await database.saveChat(value) { upsert(chat: saved) }
        }
    }

    // MARK: - Groups & contacts

    func addContact(accountId: Int64, jid rawJID: String, name: String = "") async {
        guard let session = sessions[accountId] else { return }
        let domain = account(id: accountId)?.domain ?? ""
        let jid = JID.normalize(rawJID, domain: domain)
        guard JID.valid(jid) else { showToast("Enter a valid address.", error: true); return }
        await session.addContact(jid: jid, name: name)
        await openChat(accountId: accountId, jid: jid)
    }

    func removeContact(_ contact: Contact) async {
        await sessions[contact.accountId]?.removeContact(contact.jid)
        contacts.removeAll { $0.id == contact.id }
        if let chat = chats.first(where: { $0.accountId == contact.accountId && $0.jid == contact.jid }) {
            chats.removeAll { $0.id == chat.id }
            messages.removeValue(forKey: chat.id)
            if selectedChatId == chat.id { selectedChatId = nil }
        }
    }

    func renameContact(_ contact: Contact, name: String) async {
        var value = contact
        value.nickname = name
        try? await database?.saveContact(value)
        upsert(contact: value)
    }

    func block(_ contact: Contact, blocked: Bool) async {
        await sessions[contact.accountId]?.setBlocked(jid: contact.jid, blocked: blocked)
        var value = contact
        value.blocked = blocked
        upsert(contact: value)
    }

    func acceptRequest(_ request: ContactRequest) async {
        await sessions[request.accountId]?.acceptSubscription(request.jid)
        requests.removeAll { $0.id == request.id }
        await openChat(accountId: request.accountId, jid: request.jid)
    }

    func declineRequest(_ request: ContactRequest, block: Bool = false) async {
        await sessions[request.accountId]?.declineSubscription(request.jid)
        if block { await sessions[request.accountId]?.setBlocked(jid: request.jid, blocked: true) }
        requests.removeAll { $0.id == request.id }
    }

    func setPresence(_ show: String, status: String = "") {
        for session in sessions.values { session.setPresence(show: show, status: status) }
    }

    func joinGroup(_ chat: Chat, nick: String = "", password: String = "") async {
        await sessions[chat.accountId]?.joinRoom(chat, nick: nick, password: password)
    }

    func leaveGroup(_ chat: Chat) async {
        await sessions[chat.accountId]?.leaveRoom(chat)
    }

    func setSubject(_ chat: Chat, subject: String) async {
        await sessions[chat.accountId]?.setSubject(chat, subject: subject)
    }

    func createGroup(accountId: Int64, room: String, name: String, isPrivate: Bool,
                     description: String, invitees: [String]) async -> Chat? {
        guard let session = sessions[accountId] else { return nil }
        let chat = await session.createGroup(room: room, name: name, isPrivate: isPrivate,
                                             description: description, invitees: invitees)
        if let chat { upsert(chat: chat); selectChat(chat.id) }
        return chat
    }

    func invite(_ chat: Chat, jid: String, reason: String = "") {
        sessions[chat.accountId]?.invite(chat, jid: jid, reason: reason)
    }

    func kick(_ chat: Chat, nick: String, reason: String = "") {
        sessions[chat.accountId]?.kick(chat, nick: nick, reason: reason)
    }

    func ban(_ chat: Chat, jid: String, reason: String = "") {
        sessions[chat.accountId]?.ban(chat, jid: jid, reason: reason)
    }

    func setRole(_ chat: Chat, nick: String, role: String) {
        sessions[chat.accountId]?.setRole(chat, nick: nick, role: role)
    }

    func setAffiliation(_ chat: Chat, jid: String, affiliation: String) {
        sessions[chat.accountId]?.setAffiliation(chat, jid: jid, affiliation: affiliation)
    }

    // MARK: - Devices & maintenance

    func loadDevices(accountId: Int64, jid: String) async {
        await sessions[accountId]?.loadDevices(jid: jid)
        await reloadDevices(accountId: accountId, jid: jid)
    }

    private func reloadDevices(accountId: Int64, jid: String) async {
        guard let database else { return }
        devices[jid] = (try? await database.devices(accountId: accountId, jid: jid)) ?? []
    }

    func trustDevice(_ device: Device, trusted: Bool) async {
        await sessions[device.accountId]?.trustDevice(jid: device.jid, deviceId: device.deviceId,
                                                      fingerprint: device.fingerprint, trusted: trusted,
                                                      protocolName: device.protocolName)
        await loadDevices(accountId: device.accountId, jid: device.jid)
    }

    func forgetDevice(_ device: Device) async {
        await sessions[device.accountId]?.forgetDevice(jid: device.jid, deviceId: device.deviceId,
                                                       protocolName: device.protocolName)
        await loadDevices(accountId: device.accountId, jid: device.jid)
    }

    func resyncHistory(accountId: Int64? = nil) async -> String {
        if let accountId, let session = sessions[accountId] { return await session.resyncAll() }
        var lines: [String] = []
        for account in accounts {
            guard let session = sessions[account.id] else { continue }
            lines.append(await session.resyncAll())
        }
        return lines.isEmpty ? "No connected accounts." : lines.joined(separator: "\n")
    }

    func cleanUpKeys() async -> String {
        guard let database else { return "Not ready." }
        for account in accounts {
            for device in (try? await database.devices(accountId: account.id)) ?? [] where !device.thisDevice {
                try? await database.deleteDevice(accountId: device.accountId, jid: device.jid,
                                                 deviceId: device.deviceId, protocolName: device.protocolName)
            }
        }
        return "Removed cached device lists. They will be fetched again on the next connection."
    }

    func wipeEncryptionAndHistory() async {
        try? await database?.wipeEncryptionAndHistory()
        messages = [:]
        await reloadAll()
    }

    func sendRawXml(_ xml: String) -> Bool {
        sessions.values.contains { $0.sendRaw(xml) }
    }

    func clearXML() { xmlLog.removeAll() }

    func executeCommand(_ command: AdminCommand) async -> AdminForm? {
        guard let session = sessions.values.first(where: { $0.isOnline }) else { return nil }
        return await session.executeCommand(command)
    }

    func submitForm(_ form: AdminForm, action: String) async -> AdminForm? {
        guard let session = sessions.values.first(where: { $0.isOnline }) else { return nil }
        return await session.submitForm(form, action: action)
    }

    func loadCommands() async {
        for session in sessions.values { await session.discoverCommands() }
    }

    func discoInfo(accountId: Int64, jid: String) async -> String {
        guard let result = await sessions[accountId]?.discoInfo(jid) else { return "No response." }
        return result.xmlString()
    }

    func discoItems(accountId: Int64, jid: String) async -> [DiscoItem] {
        guard let result = await sessions[accountId]?.discoItems(jid),
              let query = result.child("query", xmlns: NS.discoItems) else { return [] }
        return query.children("item").compactMap { item in
            guard let jid = item.attr("jid") else { return nil }
            return DiscoItem(jid: jid, name: item.attr("name", jid), node: item.attr("node", ""))
        }
    }

    // MARK: - Calls

    func startCall(_ chat: Chat, video: Bool) {
        Task { await sessions[chat.accountId]?.startCall(chat: chat, video: video) }
    }
    func acceptCall() { Task { await sessions.values.first { $0.activeCall != nil }?.acceptCall() } }
    func rejectCall() { Task { await sessions.values.first { $0.activeCall != nil }?.rejectCall() } }
    func endCall() { Task { await sessions.values.first { $0.activeCall != nil }?.endCall() } }
    func toggleMute() { sessions.values.first { $0.activeCall != nil }?.toggleMute() }
    func toggleSpeaker() { sessions.values.first { $0.activeCall != nil }?.toggleSpeaker() }
    func toggleCamera() { sessions.values.first { $0.activeCall != nil }?.toggleCamera() }

    // MARK: - Live updates

    private func upsert(chat: Chat) {
        if let index = chats.firstIndex(where: { $0.id == chat.id }) { chats[index] = chat }
        else { chats.append(chat) }
        sortChats()
        updateBadge()
    }

    private func updateBadge() {
        let unread = chats.filter { !$0.archived }.reduce(0) { $0 + $1.unread }
        NotificationManager.shared.updateBadge(settings: settings, unread: unread)
    }

    private func upsert(contact: Contact) {
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) { contacts[index] = contact }
        else { contacts.append(contact) }
    }

    private func sortChats() {
        chats.sort {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.lastActivity > $1.lastActivity
        }
    }

    private func reloadChats() async {
        chats = (try? await database?.chats()) ?? chats
        sortChats()
        updateBadge()
    }

    private func receive(message: Message, chat: Chat) {
        upsert(chat: chat)
        if messages[chat.id] != nil {
            if !(messages[chat.id] ?? []).contains(where: { $0.id == message.id }) {
                messages[chat.id]?.append(message)
                messages[chat.id]?.sort { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
            }
        }
        if message.direction == 0, chat.id != selectedChatId || !isForeground {
            NotificationManager.shared.notify(message: message, chat: chat, settings: settings)
        }
    }

    private func replace(message: Message) {
        guard var list = messages[message.chatId], let index = list.firstIndex(where: { $0.id == message.id }) else { return }
        list[index] = message
        messages[message.chatId] = list
    }

    func showToast(_ text: String, error: Bool = false) {
        toast = text
        toastIsError = error
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self.toast = nil }
        }
    }

    // MARK: - Utilities

    static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    static func prepareImage(_ data: Data, settings: SettingsStore) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let mode = settings.string("attachments.image_compression", "large")
        if mode == "off" {
            if settings.bool("privacy.strip_metadata") {
                return image.jpegData(compressionQuality: 0.95) ?? data
            }
            return data
        }
        let maxDimension: CGFloat = mode == "always" ? 1600 : 2560
        let size = image.size
        guard max(size.width, size.height) > maxDimension else {
            return image.jpegData(compressionQuality: 0.9) ?? data
        }
        let scale = maxDimension / max(size.width, size.height)
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: 0.86) ?? data
    }
}


@MainActor
private final class RegistrationWaiter {
    var continuation: CheckedContinuation<Void, Error>?
    private var done = false
    func finish(_ result: Result<Void, Error>) {
        guard !done else { return }
        done = true
        continuation?.resume(with: result)
        continuation = nil
    }
}
