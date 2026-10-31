import Foundation
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
        account.avatar = file.path
        if var contact = roster[account.bareJID] {
            contact.avatar = file.path
            roster[account.bareJID] = contact
        }
        try? await database.saveAccount(account)
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
    private func mamQuery(with jid: String?, max: Int, reverse: Bool = true) -> String {
        var fields = "<field var='FORM_TYPE' type='hidden'><value>\(NS.mam)</value></field>"
        if let jid { fields += "<field var='with'><value>\(XML.escape(jid))</value></field>" }
        let order = reverse ? "<reverse/>" : ""
        return """
        <query xmlns='\(NS.mam)' queryid='ward-\(String.wardID())'><x xmlns='\(NS.data)' type='submit'>\(fields)</x><set xmlns='\(NS.rsm)'><max>\(max)</max>\(order)</set></query>
        """
    }

    func syncRecentArchive() async {
        _ = await iqRequest(mamQuery(with: nil, max: 200), timeout: 35)
    }

    func syncChat(_ chat: Chat) async {
        if chat.isGroup {
            _ = await iqRequest(mamQuery(with: nil, max: 100), to: chat.jid, timeout: 35)
        } else {
            _ = await iqRequest(mamQuery(with: chat.jid, max: 100), timeout: 35)
        }
    }

    func resyncAll() async -> String {
        let chats = ((try? await database.chats()) ?? []).filter { $0.accountId == accountId && $0.open }
        guard !chats.isEmpty else { return "No chats to re-sync." }
        var count = 0
        for chat in chats {
            await syncChat(chat)
            count += 1
        }
        return "Re-synced \(count) chat\(count == 1 ? "" : "s")."
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
