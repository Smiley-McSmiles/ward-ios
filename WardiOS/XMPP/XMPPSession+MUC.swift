import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Group chat

extension XMPPSession {
    func joinRoom(_ chat: Chat, nick: String = "", password: String = "") async {
        let room = chat.jid
        let chosen = nick.isEmpty ? (chat.ourNick.isEmpty ? (account.nickname.isEmpty ? account.localpart : account.nickname) : chat.ourNick) : nick
        ourNicks[room] = chosen
        joinedRooms.insert(room)
        occupants[room] = [:]
        var extra = ""
        if !password.isEmpty { extra = "<password>\(XML.escape(password))</password>" }
        _ = connection?.send("<presence to='\(XML.escape(room))/\(XML.escape(chosen))'><x xmlns='\(NS.muc)'>\(extra)</x></presence>")
        var updated = chat
        updated.joined = true
        updated.joinError = ""
        updated.ourNick = chosen
        updated = (try? await database.saveChat(updated)) ?? updated
        onChatChanged?(updated)
        await saveBookmark(updated)
    }

    func leaveRoom(_ chat: Chat) async {
        let nick = ourNicks[chat.jid] ?? chat.ourNick
        if !nick.isEmpty {
            _ = connection?.send("<presence to='\(XML.escape(chat.jid))/\(XML.escape(nick))' type='unavailable'/>")
        }
        joinedRooms.remove(chat.jid)
        occupants.removeValue(forKey: chat.jid)
        ourNicks.removeValue(forKey: chat.jid)
        var updated = chat
        updated.joined = false
        updated = (try? await database.saveChat(updated)) ?? updated
        onChatChanged?(updated)
    }

    func processRoomPresence(_ node: XMLNode, room: String) {
        guard let full = node.attr("from"), let nick = JID.resource(full) else { return }
        var list = occupants[room] ?? [:]
        if node.attr("type") == "unavailable" {
            list.removeValue(forKey: nick)
        } else {
            let item = node.child("x", xmlns: NS.mucUser)?.child("item")
            var occupant = RoomOccupant(nick: nick)
            occupant.jid = item?.attr("jid", "") ?? ""
            occupant.role = item?.attr("role", "participant") ?? "participant"
            occupant.affiliation = item?.attr("affiliation", "none") ?? "none"
            occupant.status = node.child("status")?.trimmedText ?? ""
            occupant.isMe = nick == ourNicks[room]
            list[nick] = occupant
        }
        occupants[room] = list
        onMembers?(room, list.values.sorted { $0.nick.lowercased() < $1.nick.lowercased() })
        let me = list[ourNicks[room] ?? ""]
        var updated = Chat(accountId: accountId, jid: room)
        Task {
            if let existing = try? await database.chat(accountId: accountId, jid: room) { updated = existing }
            updated.memberCount = list.count
            updated.ourRole = me?.role ?? updated.ourRole
            updated.ourAffiliation = me?.affiliation ?? updated.ourAffiliation
            updated.joined = true
            updated = (try? await database.saveChat(updated)) ?? updated
            onChatChanged?(updated)
        }
    }

    func members(room: String) -> [RoomOccupant] {
        (occupants[room] ?? [:]).values.sorted { $0.nick.lowercased() < $1.nick.lowercased() }
    }

    func setSubject(_ chat: Chat, subject: String) async {
        _ = connection?.send("<message to='\(XML.escape(chat.jid))' type='groupchat'><subject>\(XML.escape(subject))</subject></message>")
        var updated = chat
        updated.subject = subject
        updated = (try? await database.saveChat(updated)) ?? updated
        onChatChanged?(updated)
    }

    func changeNick(_ chat: Chat, nick: String) async {
        let current = ourNicks[chat.jid] ?? chat.ourNick
        guard !nick.isEmpty, !current.isEmpty else { return }
        _ = connection?.send("<presence to='\(XML.escape(chat.jid))/\(XML.escape(nick))'/>")
        ourNicks[chat.jid] = nick
        var updated = chat
        updated.ourNick = nick
        updated = (try? await database.saveChat(updated)) ?? updated
        onChatChanged?(updated)
    }

    func invite(_ chat: Chat, jid: String, reason: String = "") {
        let reasonXML = reason.isEmpty ? "" : "<reason>\(XML.escape(reason))</reason>"
        _ = connection?.send("<message to='\(XML.escape(chat.jid))'><x xmlns='\(NS.mucUser)'><invite to='\(XML.escape(jid))'>\(reasonXML)</invite></x></message>")
    }

    func kick(_ chat: Chat, nick: String, reason: String = "") {
        let reasonXML = reason.isEmpty ? "" : "<reason>\(XML.escape(reason))</reason>"
        _ = connection?.send("<iq type='set' to='\(XML.escape(chat.jid))'><query xmlns='http://jabber.org/protocol/muc#admin'><item nick='\(XML.escape(nick))' role='none'>\(reasonXML)</item></query></iq>")
    }

    func ban(_ chat: Chat, jid: String, reason: String = "") {
        let reasonXML = reason.isEmpty ? "" : "<reason>\(XML.escape(reason))</reason>"
        _ = connection?.send("<iq type='set' to='\(XML.escape(chat.jid))'><query xmlns='http://jabber.org/protocol/muc#admin'><item jid='\(XML.escape(jid))' affiliation='outcast'>\(reasonXML)</item></query></iq>")
    }

    func setRole(_ chat: Chat, nick: String, role: String) {
        _ = connection?.send("<iq type='set' to='\(XML.escape(chat.jid))'><query xmlns='http://jabber.org/protocol/muc#admin'><item nick='\(XML.escape(nick))' role='\(XML.escape(role))'/></query></iq>")
    }

    func setAffiliation(_ chat: Chat, jid: String, affiliation: String) {
        _ = connection?.send("<iq type='set' to='\(XML.escape(chat.jid))'><query xmlns='http://jabber.org/protocol/muc#admin'><item jid='\(XML.escape(jid))' affiliation='\(XML.escape(affiliation))'/></query></iq>")
    }

    func createGroup(room: String, name: String, isPrivate: Bool, description: String, invitees: [String]) async -> Chat? {
        guard !room.isEmpty else { return nil }
        let jid = room.contains("@") ? room : "\(room)@conference.\(account.domain)"
        var chat = await ensureChat(jid: jid, type: .groupchat, name: name)
        chat.name = name
        if let saved = try? await database.saveChat(chat) { chat = saved }
        await joinRoom(chat)
        let config = """
        <iq type='set' to='\(XML.escape(jid))' id='ward-room-config'><query xmlns='http://jabber.org/protocol/muc#owner'><x xmlns='\(NS.data)' type='submit'><field var='FORM_TYPE'><value>http://jabber.org/protocol/muc#roomconfig</value></field><field var='muc#roomconfig_roomname'><value>\(XML.escape(name))</value></field><field var='muc#roomconfig_roomdesc'><value>\(XML.escape(description))</value></field><field var='muc#roomconfig_whois'><value>anyone</value></field><field var='muc#roomconfig_membersonly'><value>\((isPrivate ? 1 : 0))</value></field><field var='muc#roomconfig_persistentroom'><value>1</value></field><field var='muc#roomconfig_publicroom'><value>\((isPrivate ? 0 : 1))</value></field></x></query></iq>
        """
        _ = connection?.send(config)
        for invitee in invitees where !invitee.isEmpty { invite(chat, jid: invitee) }
        await saveBookmark(chat)
        return chat
    }

    // MARK: Bookmarks

    func loadBookmarks() async {
        guard let result = await iqRequest("<query xmlns='\(NS.privateStorage)'><storage xmlns='\(NS.bookmarks)'/></query>", timeout: 12),
              let storage = result.child("query", xmlns: NS.privateStorage)?.child("storage", xmlns: NS.bookmarks) else { return }
        for conference in storage.children("conference") {
            guard let jid = conference.attr("jid") else { continue }
            let name = conference.attr("name", JID.local(jid))
            let nick = conference.child("nick")?.trimmedText ?? ""
            let autojoin = conference.attr("autojoin", "false") == "true"
            var chat = await ensureChat(jid: jid, type: .groupchat, name: name)
            chat.name = name
            if !nick.isEmpty { chat.ourNick = nick }
            chat = (try? await database.saveChat(chat)) ?? chat
            onChatChanged?(chat)
            if autojoin { await joinRoom(chat, nick: nick) }
        }
    }

    func saveBookmark(_ chat: Chat) async {
        guard chat.isGroup else { return }
        var xml = ""
        let chats = (try? await database.chats())?.filter { $0.accountId == accountId && $0.isGroup && $0.joined } ?? []
        for room in chats {
            xml += "<conference jid='\(XML.escape(room.jid))' name='\(XML.escape(room.name))' autojoin='true'><nick>\(XML.escape(room.ourNick.isEmpty ? account.localpart : room.ourNick))</nick></conference>"
        }
        _ = connection?.send("<iq type='set' id='ward-bookmarks-\(String.wardID())'><query xmlns='\(NS.privateStorage)'><storage xmlns='\(NS.bookmarks)'>\(xml)</storage></query></iq>")
    }

    // MARK: Avatars

    func requestAvatar(_ jid: String) {
        Task {
            if await fetchPepAvatar(jid) { return }
            requestVCardAvatar(jid)
        }
    }

    @discardableResult
    func fetchPepAvatar(_ jid: String) async -> Bool {
        guard isOnline else { return false }
        let metadataRequest = "<pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:avatar:metadata' max_items='1'/></pubsub>"
        guard let result = await iqRequest(metadataRequest, to: jid, timeout: 15),
              let items = result.child("pubsub")?.child("items"),
              let item = items.children("item").first,
              let hash = item.attr("id"), !hash.isEmpty,
              let metadata = item.child("metadata", xmlns: NS.avatarMetadata),
              let info = metadata.children("info").last else { return false }
        if avatarHashes[jid] == hash, let contact = roster[jid], !contact.avatar.isEmpty { return true }
        let dataRequest = "<pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:avatar:data'><item id='\(XML.escape(hash))'/></items></pubsub>"
        guard let dataResult = await iqRequest(dataRequest, to: jid, timeout: 20),
              let dataNode = dataResult.child("pubsub")?.child("items")?.children("item").first?.child("data", xmlns: NS.avatarData),
              let data = Data(base64Encoded: dataNode.trimmedText.replacingOccurrences(of: "\n", with: "")) else { return false }
        let type = info.attr("type", "image/jpeg")
        let ext = type.contains("png") ? "png" : type.contains("gif") ? "gif" : type.contains("webp") ? "webp" : "jpg"
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("pep-\(jid.hashValue)-\(hash).\(ext)")
        try? data.write(to: file)
        avatarHashes[jid] = hash
        let stored = await storedContact(jid)
        var contact = roster[jid] ?? stored ?? Contact(accountId: accountId, jid: jid)
        contact.avatar = file.path
        roster[jid] = contact
        try? await database.saveContact(contact)
        onContactChanged?(contact)
        if let chat = try? await database.chat(accountId: accountId, jid: jid) {
            var updated = chat
            updated.avatar = file.path
            updated = (try? await database.saveChat(updated)) ?? updated
            onChatChanged?(updated)
        }
        return true
    }

    func requestVCardAvatar(_ jid: String) {
        guard !vcardRequested.contains(jid), isOnline else { return }
        vcardRequested.insert(jid)
        Task {
            defer { self.vcardRequested.remove(jid) }
            guard let result = await iqRequest("<vCard xmlns='\(NS.vcard)'/>", to: jid, timeout: 15),
                  let vcard = result.child("vCard", xmlns: NS.vcard),
                  let base64 = vcard.child("PHOTO")?.child("BIN")?.trimmedText,
                  let data = Data(base64Encoded: base64.replacingOccurrences(of: "\n", with: "")) else { return }
            let type = vcard.child("PHOTO")?.child("TYPE")?.trimmedText ?? "image/jpeg"
            let ext = type.contains("png") ? "png" : "jpg"
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Avatars", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("\(jid.hashValue)-\(base64.hashValue).\(ext)")
            try? data.write(to: file)
            let stored = await self.storedContact(jid)
            var contact = self.roster[jid] ?? stored ?? Contact(accountId: self.accountId, jid: jid)
            contact.avatar = file.path
            self.roster[jid] = contact
            try? await self.database.saveContact(contact)
            self.onContactChanged?(contact)
            if let chat = try? await self.database.chat(accountId: self.accountId, jid: jid) {
                var updated = chat
                updated.avatar = file.path
                updated = (try? await self.database.saveChat(updated)) ?? updated
                self.onChatChanged?(updated)
            }
        }
    }

    func publishAvatar(_ data: Data, mime: String) async {
        let base64 = data.base64EncodedString()
        let xml = "<iq type='set' id='ward-vcard-\(String.wardID())'><vCard xmlns='\(NS.vcard)'><PHOTO><TYPE>\(XML.escape(mime))</TYPE><BIN>\(base64)</BIN></PHOTO></vCard></iq>"
        _ = connection?.send(xml)
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("own-avatar.jpg")
        try? data.write(to: file)
        await publishPepAvatar(data, mime: mime)
        account.avatar = file.path
        if var contact = roster[account.bareJID] {
            contact.avatar = file.path
            roster[account.bareJID] = contact
        }
        try? await database.saveAccount(account)
    }

    private func publishPepAvatar(_ data: Data, mime: String) async {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let base64 = data.base64EncodedString()
        let accessOptions = "<publish-options><x xmlns='\(NS.data)' type='submit'><field var='FORM_TYPE' type='hidden'><value>http://jabber.org/protocol/pubsub#publish-options</value></field><field var='pubsub#access_model'><value>open</value></field><field var='pubsub#max_items'><value>1</value></field></x></publish-options>"
        let dataIQ = "<pubsub xmlns='http://jabber.org/protocol/pubsub'><publish node='\(NS.avatarData)'><item id='\(hash)'><data xmlns='\(NS.avatarData)'>\(base64)</data></item></publish>\(accessOptions)</pubsub>"
        _ = connection?.send("<iq type='set' id='ward-pep-avatar-data-\(String.wardID())'>\(dataIQ)</iq>")
        let metadata = "<metadata xmlns='\(NS.avatarMetadata)'><info id='\(hash)' bytes='\(data.count)' type='\(XML.escape(mime))'/></metadata>"
        let metadataIQ = "<pubsub xmlns='http://jabber.org/protocol/pubsub'><publish node='\(NS.avatarMetadata)'><item id='\(hash)'>\(metadata)</item></publish>\(accessOptions)</pubsub>"
        _ = connection?.send("<iq type='set' id='ward-pep-avatar-meta-\(String.wardID())'>\(metadataIQ)</iq>")
        avatarHashes[account.bareJID] = hash
    }

    func publishNick(_ nick: String) {
        account.nickname = nick
        Task {
            try? await database.saveAccount(account)
            _ = connection?.send("<iq type='set' id='ward-nick-\(String.wardID())'><pubsub xmlns='http://jabber.org/protocol/pubsub'><publish node='http://jabber.org/protocol/nick'><item><nick xmlns='http://jabber.org/protocol/nick'>\(XML.escape(nick))</nick></item></publish></publish></iq>")
        }
    }
}

// MARK: - MAM

extension XMPPSession {
    private func mamQuery(with jid: String?, max: Int, reverse: Bool = true,
                          after: String? = nil, before: String? = nil, start: Date? = nil) -> String {
        var fields = "<field var='FORM_TYPE' type='hidden'><value>\(NS.mam)</value></field>"
        if let jid { fields += "<field var='with'><value>\(XML.escape(jid))</value></field>" }
        if let start {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            fields += "<field var='start'><value>\(formatter.string(from: start))</value></field>"
        }
        var rsm = "<max>\(max)</max>"
        if let after { rsm += "<after>\(XML.escape(after))</after>" }
        if let before { rsm += "<before>\(XML.escape(before))</before>" }
        if reverse { rsm += "<reverse/>" }
        return """
        <query xmlns='\(NS.mam)' queryid='ward-\(String.wardID())'><x xmlns='\(NS.data)' type='submit'>\(fields)</x><set xmlns='\(NS.rsm)'>\(rsm)</set></query>
        """
    }

    private func mamSet(_ result: XMLNode) -> (first: String?, last: String?, complete: Bool)? {
        guard let fin = result.child("fin", xmlns: NS.mam) else { return nil }
        let set = fin.child("set", xmlns: NS.rsm)
        return (set?.child("first")?.trimmedText, set?.child("last")?.trimmedText,
                fin.attr("complete", "false") == "true")
    }

    /// Catch up from the last successful archive sync. The cursor is persisted per account so a
    /// reconnect does not skip messages that arrived while the app was closed. If a server rejects
    /// an old cursor, fall back to a seven-day window once instead of failing forever.
    func syncRecentArchive() async {
        let defaults = UserDefaults.standard
        let syncKey = "ward.mam.since.\(accountId)"
        let uidKey = "ward.mam.uid.\(accountId)"
        let now = Date()
        let lastSync = defaults.double(forKey: syncKey)
        let fallbackStart = now.addingTimeInterval(-7 * 86_400)
        var after = defaults.string(forKey: uidKey)
        var start: Date? = after == nil ? (lastSync > 0 ? Date(timeIntervalSince1970: lastSync - 2) : fallbackStart) : nil
        var lastUID: String? = after
        var completed = false

        for page in 0..<20 {
            let query = mamQuery(with: nil, max: 200, reverse: false, after: after, start: page == 0 ? start : nil)
            guard let result = await iqRequest(query, timeout: 40) else {
                if after != nil && page == 0 {
                    // A stale cursor from a previous archive should not block the whole account.
                    after = nil
                    start = fallbackStart
                    lastUID = nil
                    continue
                }
                return
            }
            if result.attr("type") == "error" && after != nil && page == 0 {
                after = nil
                start = fallbackStart
                lastUID = nil
                continue
            }
            guard let set = mamSet(result) else { return }
            if let last = set.last, !last.isEmpty { lastUID = last }
            if set.complete { completed = true; break }
            guard let last = set.last, !last.isEmpty, last != after else { break }
            after = last
            start = nil
        }
        if completed || lastUID != nil {
            defaults.set(now.timeIntervalSince1970, forKey: syncKey)
            if let lastUID { defaults.set(lastUID, forKey: uidKey) }
        }
    }

    /// Fetch recent pages for one chat, walking backwards so a manual re-sync can fill gaps.
    @discardableResult
    func syncChat(_ chat: Chat, pages: Int = 4) async -> Int {
        var before: String?
        var fetched = 0
        for _ in 0..<max(1, pages) {
            let query = mamQuery(with: chat.isGroup ? nil : chat.jid, max: 100, reverse: true, before: before)
            let result: XMLNode?
            if chat.isGroup {
                result = await iqRequest(query, to: chat.jid, timeout: 40)
            } else {
                result = await iqRequest(query, timeout: 40)
            }
            guard let result, let set = mamSet(result) else { break }
            fetched += 1
            guard let first = set.first, !first.isEmpty, first != before else { break }
            before = first
            if set.complete { break }
        }
        return fetched
    }

    func resyncAll() async -> String {
        let chats = ((try? await database.chats()) ?? []).filter { $0.accountId == accountId && $0.open }
        guard !chats.isEmpty else { return "No chats to re-sync." }
        var count = 0
        var pages = 0
        for chat in chats {
            let fetched = await syncChat(chat, pages: 10)
            if fetched > 0 { count += 1; pages += fetched }
        }
        return "Re-synced \(count) chat\(count == 1 ? "" : "s") (\(pages) page\(pages == 1 ? "" : "s"))."
    }
}

// MARK: - Upload

struct UploadService {
    var jid: String
    var maxSize: Int64 = 0
}

extension XMPPSession {
    func discoverUploadService() async {
        let candidates: [String]
        if let service = uploadService { candidates = [service.jid] }
        else {
            var discovered: [String] = []
            if let items = await discoItems(account.domain) {
                discovered = items.children("item").compactMap { $0.attr("jid") }
            }
            discovered.append("upload.\(account.domain)")
            candidates = discovered
        }
        for candidate in candidates.prefix(12) {
            if let info = await discoInfo(candidate),
               let query = info.child("query", xmlns: NS.discoInfo),
               query.children("feature").contains(where: { $0.attr("var") == NS.upload || $0.attr("var") == NS.uploadLegacy }) {
                var maxSize: Int64 = 0
                if let form = query.child("x", xmlns: NS.data),
                   let field = form.children("field").first(where: { $0.attr("var") == "max-file-size" }) {
                    maxSize = Int64(field.child("value")?.trimmedText ?? "0") ?? 0
                }
                uploadService = UploadService(jid: candidate, maxSize: maxSize)
                return
            }
        }
    }

    func upload(data: Data, name: String, mime: String) async throws -> String {
        if uploadService == nil { await discoverUploadService() }
        guard let service = uploadService else {
            throw WardError.network("This server does not offer HTTP file uploads (XEP-0363).")
        }
        if service.maxSize > 0 && Int64(data.count) > service.maxSize {
            throw WardError.network("This file is larger than the server allows (\(WardFormat.bytes(service.maxSize))).")
        }
        let request = "<request xmlns='\(NS.upload)' filename='\(XML.escape(name))' size='\(data.count)' content-type='\(XML.escape(mime))'/>"
        guard let result = await iqRequest(request, to: service.jid, type: "set", timeout: 30),
              let slot = result.child("slot", xmlns: NS.upload),
              let put = slot.child("put"), let urlString = put.attr("url"),
              let url = URL(string: urlString),
              let get = slot.child("get")?.attr("url") else {
            throw WardError.network("The upload server did not return a usable slot.")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "PUT"
        urlRequest.httpBody = data
        urlRequest.setValue(mime, forHTTPHeaderField: "Content-Type")
        for header in put.children("header") {
            if let name = header.attr("name") {
                urlRequest.setValue(header.trimmedText, forHTTPHeaderField: name)
            }
        }
        let (_, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WardError.network("The upload failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        return get
    }
}
