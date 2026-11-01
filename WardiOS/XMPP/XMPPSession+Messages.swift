import Foundation
import WardCrypto

extension XMPPSession {
    // MARK: - Incoming messages

    func processMessage(_ node: XMLNode, directionOverride: Int? = nil,
                        timestampOverride: Date? = nil, mam: Bool = false) async {
        guard isOnline else { return }
        if handleCallStanza(node, directionOverride: directionOverride) { return }
        var node = node
        let wasEncrypted = node.child("encrypted", xmlns: NS.omemo2) != nil
        if let encrypted = node.child("encrypted", xmlns: NS.omemo2) {
            guard let decrypted = await decryptOMEMO(encrypted, source: node) else { return }
            node = decrypted
            node.children.removeAll { $0.name == "body" }
        }
        let type = node.attr("type", "chat")
        if type == "error" {
            onToast?("A message could not be delivered. Check the XML console for details.", true)
            return
        }
        guard let from = node.attr("from") else { return }
        if type == "groupchat" {
            await processGroupMessage(node, timestampOverride: timestampOverride)
            return
        }
        var peer = JID.bare(from)
        var outgoing = false
        if let override = directionOverride {
            outgoing = override == 1
            let other = outgoing ? node.attr("to") : node.attr("from")
            peer = JID.bare(other ?? from)
        } else if JID.bare(from) == account.bareJID {
            outgoing = true
            peer = JID.bare(node.attr("to", from))
            if peer == account.bareJID { outgoing = false }
        }
        guard !peer.isEmpty, peer != account.bareJID || !outgoing else { return }

        let body = node.child("body")?.allText ?? ""
        let attachments = parseAttachments(node, body: body)
        let reply = node.child("reply", xmlns: NS.reply)
        let correction = node.child("replace", xmlns: NS.correct)?.attr("id")
        let retraction = node.child("retract", xmlns: NS.retract)?.attr("id")
            ?? node.child("retract", xmlns: NS.retract0)?.attr("id")
        let reactions = node.child("reactions", xmlns: NS.reactions)
        let isEncrypted = node.child("encrypted", xmlns: NS.omemo2) != nil
            || node.child("encrypted", xmlns: NS.omemo) != nil
            || node.child("openpgp", xmlns: NS.openpgp) != nil

        // Receipts and chat markers are extension-only messages.
        if let received = node.child("received", xmlns: NS.receipts)?.attr("id") {
            await updateReceipt(chatJid: peer, ref: received, status: 2)
            return
        }
        if let displayed = node.child("displayed", xmlns: NS.markers)?.attr("id") {
            await updateReceipt(chatJid: peer, ref: displayed, status: 3)
            return
        }
        if body.isEmpty && attachments.isEmpty && reactions == nil && correction == nil && retraction == nil && !isEncrypted {
            if node.child("composing", xmlns: NS.chatstates) != nil {
                if let chat = try? await database.chat(accountId: accountId, jid: peer) {
                    onTyping?(chat.id, contactName(peer))
                }
            } else if node.child("paused", xmlns: NS.chatstates) != nil || node.child("active", xmlns: NS.chatstates) != nil {
                if let chat = try? await database.chat(accountId: accountId, jid: peer) {
                    onTyping?(chat.id, "")
                }
            }
            return
        }

        let chat = await ensureChat(jid: peer, type: .chat)
        if let correction, let old = try? await database.findMessage(chatId: chat.id, ref: correction) {
            var updated = old
            updated.body = stripReplyQuote(body, reply: reply)
            updated.edited = true
            try? await database.updateMessage(updated)
            onMessageChanged?(updated)
            await updatePreviewIfNeeded(chat: chat, message: updated)
            return
        }
        if let retraction, let old = try? await database.findMessage(chatId: chat.id, ref: retraction) {
            var updated = old
            updated.retracted = true
            updated.body = ""
            updated.attachments = []
            updated.reactions = []
            try? await database.updateMessage(updated)
            onMessageChanged?(updated)
            await updatePreviewIfNeeded(chat: chat, message: updated)
            return
        }
        if let reactions, let target = reactions.attr("id"),
           let old = try? await database.findMessage(chatId: chat.id, ref: target) {
            var updated = old
            let who = contactName(peer)
            updated.reactions.removeAll { $0.who == who }
            let emoji = reactions.children("reaction").map { $0.trimmedText }.filter { !$0.isEmpty }
            if !emoji.isEmpty {
                updated.reactions.append(Reaction(emoji: emoji, who: who, mine: false))
            }
            try? await database.updateMessage(updated)
            onMessageChanged?(updated)
            return
        }

        let stored = await storedContact(peer)
        var contact = roster[peer] ?? stored
        if contact == nil && !outgoing {
            switch settings.string("privacy.strangers", "requests") {
            case "block": return
            case "requests":
                var requestChat = chat
                requestChat.isRequest = true
                requestChat = (try? await database.saveChat(requestChat)) ?? requestChat
                let request = ContactRequest(accountId: accountId, jid: peer, kind: "message",
                                             text: String(body.prefix(100)), chatId: requestChat.id)
                try? await database.saveRequest(request)
                onRequest?(request)
                onChatChanged?(requestChat)
                contact = Contact(accountId: accountId, jid: peer, inRoster: false)
                roster[peer] = contact
            default: break
            }
        }

        var timestamp = timestampOverride?.millis ?? Date().millis
        if let delay = node.child("delay", xmlns: NS.delay)?.attr("stamp"), let date = Date.fromXMPP(delay) {
            timestamp = date.millis
        }
        if timestamp <= chat.clearedAt { return }
        let stanzaId = node.attr("id").flatMap { $0.isEmpty ? nil : $0 } ?? node.child("origin-id", xmlns: NS.sid)?.attr("id") ?? String.wardID()
        let originId = node.child("origin-id", xmlns: NS.sid)?.attr("id", "") ?? ""
        var cleanBody = stripReplyQuote(body, reply: reply)
        for attachment in attachments where !attachment.url.isEmpty {
            cleanBody = cleanBody.replacingOccurrences(of: attachment.url, with: "")
        }
        cleanBody = cleanBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: String = cleanBody.hasPrefix("/me ") ? MessageKind.me.rawValue : (attachments.isEmpty ? MessageKind.text.rawValue : MessageKind.file.rawValue)
        var message = Message(chatId: chat.id, stanzaId: stanzaId, originId: originId, msgId: node.attr("id", ""),
                              sender: outgoing ? account.bareJID : peer, senderJid: from,
                              senderName: outgoing ? account.displayName : contactName(peer),
                              direction: outgoing ? 1 : 0, timestamp: timestamp,
                              body: cleanBody, isMarkdown: node.child("markdown", xmlns: NS.markdown) != nil,
                              kind: kind, encryption: wasEncrypted ? "omemo2" : "",
                              edited: false, retracted: false,
                              replyTo: reply?.attr("id", "") ?? "",
                              replyPreview: replyPreview(body: body, reply: reply),
                              replyAuthor: replyAuthor(reply),
                              status: outgoing ? 1 : 0,
                              error: "", mentionsMe: mentionsMe(chat: chat, body: cleanBody),
                              reactions: [], attachments: attachments, raw: node.xmlString())
        if let existing = try? await database.findMessage(chatId: chat.id, ref: stanzaId) {
            // A carbon and a MAM result can race. Never overwrite a locally sent copy with the echo.
            if !outgoing || existing.status > 0 { return }
            message.id = existing.id
            try? await database.updateMessage(message)
            onMessageChanged?(message)
            return
        }
        guard let inserted = try? await database.insertMessage(message) else { return }
        onMessage?(inserted, chat)
        let updatedChat = await touchChat(chat, message: inserted, outgoing: outgoing)
        if !outgoing && activeChatId == chat.id && appForeground {
            await markRead(updatedChat)
        }
    }

    func processGroupMessage(_ node: XMLNode, timestampOverride: Date? = nil) async {
        guard let from = node.attr("from") else { return }
        let room = JID.bare(from)
        guard let nick = JID.resource(from) else { return }
        let knownRoom = (try? await database.chat(accountId: accountId, jid: room)) != nil
        guard joinedRooms.contains(room) || knownRoom else { return }
        let chat = await ensureChat(jid: room, type: .groupchat, name: JID.local(room))
        if let subject = node.child("subject")?.allText, !subject.isEmpty {
            var updated = chat
            updated.subject = subject
            updated = (try? await database.saveChat(updated)) ?? updated
            onChatChanged?(updated)
            return
        }
        let body = node.child("body")?.allText ?? ""
        let attachments = parseAttachments(node, body: body)
        let reply = node.child("reply", xmlns: NS.reply)
        let correction = node.child("replace", xmlns: NS.correct)?.attr("id")
        let retraction = node.child("retract", xmlns: NS.retract)?.attr("id")
            ?? node.child("retract", xmlns: NS.retract0)?.attr("id")
        let reactions = node.child("reactions", xmlns: NS.reactions)
        let ourNick = ourNicks[room] ?? chat.ourNick
        let mine = nick == ourNick
        if let correction, let old = try? await database.findMessage(chatId: chat.id, ref: correction) {
            var updated = old
            updated.body = stripReplyQuote(body, reply: reply)
            updated.edited = true
            try? await database.updateMessage(updated)
            onMessageChanged?(updated)
            return
        }
        if let retraction, let old = try? await database.findMessage(chatId: chat.id, ref: retraction) {
            var updated = old
            updated.retracted = true
            updated.body = ""
            updated.attachments = []
            try? await database.updateMessage(updated)
            onMessageChanged?(updated)
            return
        }
        if let reactions, let target = reactions.attr("id"),
           let old = try? await database.findMessage(chatId: chat.id, ref: target) {
            var updated = old
            updated.reactions.removeAll { $0.who == nick }
            let emoji = reactions.children("reaction").map { $0.trimmedText }.filter { !$0.isEmpty }
            if !emoji.isEmpty { updated.reactions.append(Reaction(emoji: emoji, who: nick, mine: mine)) }
            try? await database.updateMessage(updated)
            onMessageChanged?(updated)
            return
        }
        if body.isEmpty && attachments.isEmpty { return }
        if timestampOverride == nil, let delay = node.child("delay", xmlns: NS.delay)?.attr("stamp"),
           let date = Date.fromXMPP(delay), date.millis <= chat.clearedAt { return }
        let timestamp = timestampOverride?.millis ?? Date.fromXMPP(node.child("delay", xmlns: NS.delay)?.attr("stamp"))?.millis ?? Date().millis
        let stanzaId = node.attr("id").flatMap { $0.isEmpty ? nil : $0 } ?? String.wardID()
        let occupantJID = node.child("x", xmlns: NS.mucUser)?.child("item")?.attr("jid", "") ?? ""
        var cleanBody = stripReplyQuote(body, reply: reply)
        for attachment in attachments where !attachment.url.isEmpty {
            cleanBody = cleanBody.replacingOccurrences(of: attachment.url, with: "")
        }
        cleanBody = cleanBody.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = Message(chatId: chat.id, stanzaId: stanzaId,
                              originId: node.child("origin-id", xmlns: NS.sid)?.attr("id", "") ?? "",
                              msgId: node.attr("id", ""), sender: nick, senderJid: occupantJID,
                              senderName: nick, direction: mine ? 1 : 0, timestamp: timestamp,
                              body: cleanBody,
                              isMarkdown: node.child("markdown", xmlns: NS.markdown) != nil,
                              kind: cleanBody.hasPrefix("/me ") ? "me" : (attachments.isEmpty ? "text" : "file"),
                              replyTo: reply?.attr("id", "") ?? "",
                              replyPreview: replyPreview(body: body, reply: reply),
                              status: mine ? 1 : 0,
                              mentionsMe: mentionsMe(chat: chat, body: cleanBody),
                              attachments: attachments, raw: node.xmlString())
        guard let inserted = try? await database.insertMessage(message) else { return }
        message = inserted
        onMessage?(inserted, chat)
        let updatedChat = await touchChat(chat, message: inserted, outgoing: mine)
        if !mine && activeChatId == chat.id && appForeground {
            await markRead(updatedChat)
        }
    }

    private func updatePreviewIfNeeded(chat: Chat, message: Message) async {
        if chat.preview == message.body { return }
        var updated = chat
        updated.preview = message.retracted ? "Message deleted" : message.body
        updated = (try? await database.saveChat(updated)) ?? updated
        onChatChanged?(updated)
    }

    private func updateReceipt(chatJid: String, ref: String, status: Int) async {
        guard let chat = try? await database.chat(accountId: accountId, jid: chatJid),
              var message = try? await database.findMessage(chatId: chat.id, ref: ref) else { return }
        guard message.status < status else { return }
        message.status = status
        try? await database.updateMessage(message)
        onMessageChanged?(message)
    }

    // MARK: - Parsing helpers

    func parseAttachments(_ node: XMLNode, body: String) -> [Attachment] {
        var output: [Attachment] = []
        if let sharing = node.child("file-sharing", xmlns: NS.sfs) {
            let file = sharing.child("file", xmlns: NS.file)
            let source = sharing.child("sources")?.children("url-data").first?.attr("target", "")
                ?? sharing.children("sources").first?.children("url-data").first?.attr("target", "")
            let url = source ?? ""
            if !url.isEmpty {
                output.append(Attachment(
                    url: url,
                    name: file?.child("name")?.trimmedText ?? URL(string: url)?.lastPathComponent ?? "file",
                    mime: file?.child("media-type")?.trimmedText ?? "",
                    size: Int64(file?.child("size")?.trimmedText ?? "0") ?? 0,
                    width: Double(file?.child("width")?.trimmedText ?? "0") ?? 0,
                    height: Double(file?.child("height")?.trimmedText ?? "0") ?? 0,
                    encrypted: url.hasPrefix("aesgcm://")))
            }
        }
        if output.isEmpty, let oob = node.child("x", xmlns: NS.oob),
           let url = oob.child("url")?.trimmedText, !url.isEmpty {
            let name = oob.child("desc")?.trimmedText ?? URL(string: url)?.lastPathComponent ?? "file"
            output.append(Attachment(url: url, name: name, mime: Self.guessMIME(name), encrypted: url.hasPrefix("aesgcm://")))
        }
        if output.isEmpty {
            let urls = body.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") || $0.hasPrefix("aesgcm://") }
            if let first = urls.first(where: { Self.isMediaURL($0) }) {
                let name = URL(string: first)?.lastPathComponent ?? "file"
                output.append(Attachment(url: first, name: name, mime: Self.guessMIME(name), encrypted: first.hasPrefix("aesgcm://")))
            }
        }
        return output
    }

    static func guessMIME(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "ogg", "oga", "opus": return "audio/ogg"
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    static func isMediaURL(_ url: String) -> Bool {
        let ext = (URL(string: url)?.pathExtension ?? "").lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "heic", "mp4", "mov", "m4v", "webm",
                "mp3", "m4a", "aac", "ogg", "oga", "opus", "pdf"].contains(ext)
    }

    func stripReplyQuote(_ body: String, reply: XMLNode?) -> String {
        guard reply != nil else { return body }
        var lines = body.components(separatedBy: "\n")
        while let first = lines.first, first.hasPrefix(">") { lines.removeFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func replyAuthor(_ reply: XMLNode?) -> String {
        guard let to = reply?.attr("to", ""), !to.isEmpty else { return "" }
        return contactName(to)
    }

    func replyPreview(body: String, reply: XMLNode?) -> String {
        guard let reply else { return "" }
        if let fallback = reply.child("fallback", xmlns: NS.fallback)?.child("body")?.trimmedText, !fallback.isEmpty {
            return fallback
        }
        let quoted = body.components(separatedBy: "\n").prefix { $0.hasPrefix(">") }
            .map { $0.replacingOccurrences(of: "> ", with: "") }.joined(separator: "\n")
        return quoted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func mentionsMe(chat: Chat, body: String) -> Bool {
        guard !body.isEmpty else { return false }
        var needles = [account.nickname, account.localpart, chat.ourNick].filter { !$0.isEmpty }
        needles += settings.list("notify.highlight_words")
        return needles.contains { needle in
            body.range(of: needle, options: .caseInsensitive) != nil
        }
    }

    // MARK: - Sending

    @discardableResult
    func sendText(chat: Chat, text: String, replyTo: Message? = nil) async -> Message? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let id = String.wardID()
        var message = Message(chatId: chat.id, stanzaId: id, originId: id,
                              sender: account.bareJID, senderJid: account.bareJID,
                              senderName: account.displayName, direction: 1,
                              timestamp: Date().millis, body: text,
                              isMarkdown: true,
                              kind: text.hasPrefix("/me ") ? "me" : "text",
                              replyTo: replyTo?.stanzaId ?? "",
                              replyPreview: replyTo?.body ?? "",
                              replyAuthor: replyTo?.senderName ?? "",
                              status: 0)
        guard let stored = try? await database.insertMessage(message) else { return nil }
        message = stored
        onMessage?(stored, chat)
        let updatedChat = await touchChat(chat, message: stored, outgoing: true)
        await transmit(message: stored, chat: updatedChat)
        return stored
    }

    @discardableResult
    func sendAttachment(chat: Chat, fileURL: URL, name: String, mime: String,
                        caption: String, isVoice: Bool = false,
                        width: Double = 0, height: Double = 0, duration: Double = 0) async -> Message? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let id = String.wardID()
        var attachment = Attachment(url: "", name: name, mime: mime, size: size,
                                    width: width, height: height, duration: duration,
                                    localPath: fileURL.path, isVoice: isVoice)
        var message = Message(chatId: chat.id, stanzaId: id, originId: id,
                              sender: account.bareJID, senderJid: account.bareJID,
                              senderName: account.displayName, direction: 1,
                              timestamp: Date().millis, body: caption.isEmpty ? name : caption, isMarkdown: true,
                              kind: MessageKind.file.rawValue,
                              status: 0, attachments: [attachment])
        guard let stored = try? await database.insertMessage(message) else { return nil }
        message = stored
        onMessage?(stored, chat)
        _ = await touchChat(chat, message: stored, outgoing: true)

        do {
            guard let data = try? Data(contentsOf: fileURL) else {
                throw WardError.network("The attachment could not be read.")
            }
            let encryptAttachment = omemoRequired(chat)
                || (chat.encryptionMode == .default && settings.string("encryption.default", "off") == "always")
            let url: String
            if encryptAttachment {
                let sealed = try FileCrypto.encrypt(data)
                let https = try await upload(data: sealed.ciphertext, name: name, mime: "application/octet-stream")
                url = FileCrypto.aesgcmURL(httpsURL: https, key: sealed.key, iv: sealed.iv)
                attachment.encrypted = true
            } else {
                url = try await upload(data: data, name: name, mime: mime)
            }
            attachment.url = url
            attachment.localPath = fileURL.path
            message.attachments = [attachment]
            try? await database.updateMessage(message)
            onMessageChanged?(message)
            await transmit(message: message, chat: chat)
        } catch {
            message.status = -1
            message.error = error.localizedDescription
            try? await database.updateMessage(message)
            onMessageChanged?(message)
            onToast?(error.localizedDescription, true)
        }
        return message
    }

    func sendScheduled(chat: Chat, message: Message) async {
        guard message.id != 0 else { return }
        var value = message
        value.scheduledAt = nil
        value.timestamp = Date().millis
        value.status = 0
        try? await database.updateMessage(value)
        onMessageChanged?(value)
        _ = await touchChat(chat, message: value, outgoing: true)
        await transmit(message: value, chat: chat)
    }

    private func transmit(message original: Message, chat: Chat) async {
        guard isOnline, let connection = connection else {
            var queued = original
            queued.status = 0
            try? await database.updateMessage(queued)
            onMessageChanged?(queued)
            return
        }
        var message = original
        let defaultMode = settings.string("encryption.default", "off")
        if chat.encryptionMode == .pgp {
            message.status = -1
            message.error = "OpenPGP is not available in this build."
            try? await database.updateMessage(message)
            onMessageChanged?(message)
            onToast?(message.error, true)
            return
        }
        if omemoRequired(chat) || (chat.encryptionMode == .default && defaultMode == "available" && omemo != nil) {
            do {
                let content = messageContentXML(message, chat: chat)
                let sent = try await encryptAndSend(chat, contentXML: content,
                                                    messageId: message.stanzaId.isEmpty ? String.wardID() : message.stanzaId)
                if sent {
                    message.status = 1
                    message.error = ""
                    message.encryption = "omemo2"
                    try? await database.updateMessage(message)
                    onMessageChanged?(message)
                } else {
                    throw WardCryptoError.encryption("The OMEMO message could not be sent.")
                }
                return
            } catch {
                if chat.encryptionMode == .default && defaultMode == "available" {
                    if !warnedAboutEncryption {
                        warnedAboutEncryption = true
                        onToast?("No OMEMO devices were available; this message is being sent unencrypted.", true)
                    }
                } else {
                    message.status = -1
                    message.error = "OMEMO failed: \(error.localizedDescription)"
                    try? await database.updateMessage(message)
                    onMessageChanged?(message)
                    onToast?(message.error, true)
                    return
                }
            }
        }
        if chat.isGroup && !joinedRooms.contains(chat.jid) {
            message.status = -1
            message.error = "Join the group before sending messages."
            try? await database.updateMessage(message)
            onMessageChanged?(message)
            return
        }
        let id = message.stanzaId.isEmpty ? String.wardID() : message.stanzaId
        var body = message.body
        var children: [String] = []
        if !message.replyTo.isEmpty {
            let quote = message.replyPreview.components(separatedBy: "\n").prefix(3)
                .filter { !$0.isEmpty }.map { "> \($0)" }.joined(separator: "\n")
            if !quote.isEmpty { body = quote + "\n" + body }
        }
        if !body.isEmpty { children.append("<body>\(XML.escape(body))</body>") }
        children.append("<origin-id xmlns='\(NS.sid)' id='\(XML.escape(id))'/>")
        children.append("<markdown xmlns='\(NS.markdown)'/>")
        children.append("<markable xmlns='\(NS.markers)'/>")
        children.append("<active xmlns='\(NS.chatstates)'/>")
        if !message.replyTo.isEmpty {
            let to = chat.isGroup ? "" : " to='\(XML.escape(chat.jid))'"
            children.append("<reply xmlns='\(NS.reply)' id='\(XML.escape(message.replyTo))'\(to)/>")
            children.append("<fallback xmlns='\(NS.fallback)' for='\(NS.reply)'><body start='0' end='\(body.count)'/></fallback>")
        }
        if !chat.isGroup {
            children.append("<request xmlns='\(NS.receipts)'/>")
        }
        if let attachment = message.attachments.first, !attachment.url.isEmpty {
            var file = "<name>\(XML.escape(attachment.name))</name><size>\(attachment.size)</size>"
            if !attachment.mime.isEmpty { file += "<media-type>\(XML.escape(attachment.mime))</media-type>" }
            if attachment.width > 0 { file += "<width>\(Int(attachment.width))</width>" }
            if attachment.height > 0 { file += "<height>\(Int(attachment.height))</height>" }
            children.append("<file-sharing xmlns='\(NS.sfs)' disposition='inline'><file xmlns='\(NS.file)'>\(file)</file><sources><url-data xmlns='http://jabber.org/protocol/url-data' target='\(XML.escape(attachment.url))'/></sources></file-sharing>")
            children.append("<x xmlns='\(NS.oob)'><url>\(XML.escape(attachment.url))</url><desc>\(XML.escape(attachment.name))</desc></x>")
        }
        children.append("<store xmlns='\(NS.hints)'/>")
        let type = chat.isGroup ? "groupchat" : "chat"
        let stanza = "<message to='\(XML.escape(chat.jid))' type='\(type)' id='\(XML.escape(id))'>\(children.joined())</message>"
        if connection.send(stanza) {
            message.status = 1
            message.error = ""
            message.stanzaId = id
            try? await database.updateMessage(message)
            onMessageChanged?(message)
        } else {
            message.status = 0
            try? await database.updateMessage(message)
            onMessageChanged?(message)
        }
    }

    func sendReceipt(chat: Chat, stanzaId: String) {
        guard !stanzaId.isEmpty, settings.bool("chats.send_receipts"), isOnline else { return }
        let type = chat.isGroup ? "groupchat" : "chat"
        _ = connection?.send("<message to='\(XML.escape(chat.jid))' type='\(type)'><received xmlns='\(NS.receipts)' id='\(XML.escape(stanzaId))'/></message>")
    }

    func sendDisplayed(chat: Chat, message: Message) {
        guard settings.bool("chats.send_markers"), isOnline else { return }
        let ref = chat.isGroup ? message.stanzaId : (message.msgId.isEmpty ? message.stanzaId : message.msgId)
        guard !ref.isEmpty else { return }
        let type = chat.isGroup ? "groupchat" : "chat"
        _ = connection?.send("<message to='\(XML.escape(chat.jid))' type='\(type)'><displayed xmlns='\(NS.markers)' id='\(XML.escape(ref))'/><store xmlns='\(NS.hints)'/></message>")
    }

    func sendTyping(chat: Chat, composing: Bool) {
        guard settings.bool("chats.send_typing"), isOnline else { return }
        let state = composing ? "composing" : "paused"
        let type = chat.isGroup ? "groupchat" : "chat"
        _ = connection?.send("<message to='\(XML.escape(chat.jid))' type='\(type)'><\(state) xmlns='\(NS.chatstates)'/><no-store xmlns='\(NS.hints)'/></message>")
    }

    func react(chat: Chat, message: Message, emoji: String) async {
        let target = chat.isGroup ? message.stanzaId : (message.originId.isEmpty ? message.msgId : message.originId)
        guard !target.isEmpty else { return }
        var updated = message
        let alreadyMine = updated.reactions.contains { $0.mine && $0.emoji.contains(emoji) }
        updated.reactions.removeAll { $0.mine }
        if !alreadyMine {
            updated.reactions.append(Reaction(emoji: [emoji], who: account.displayName, mine: true))
        }
        try? await database.updateMessage(updated)
        onMessageChanged?(updated)
        let type = chat.isGroup ? "groupchat" : "chat"
        let emojis = alreadyMine ? [] : [emoji]
        if omemoRequired(chat) || (chat.encryptionMode == .default && settings.string("encryption.default", "off") == "always") {
            if await sendEncryptedReaction(chat: chat, target: target, emojis: emojis) { return }
        }
        let reactions = alreadyMine
            ? "<reactions xmlns='\(NS.reactions)' id='\(XML.escape(target))'/>"
            : "<reactions xmlns='\(NS.reactions)' id='\(XML.escape(target))'><reaction>\(XML.escape(emoji))</reaction></reactions>"
        _ = connection?.send("<message to='\(XML.escape(chat.jid))' type='\(type)'><origin-id xmlns='\(NS.sid)' id='\(String.wardID())'/>\(reactions)<store xmlns='\(NS.hints)'/></message>")
    }

    func edit(chat: Chat, message: Message, text: String) async {
        let target = message.originId.isEmpty ? message.msgId : message.originId
        guard !target.isEmpty, !text.isEmpty else { return }
        var updated = message
        updated.body = text
        updated.edited = true
        try? await database.updateMessage(updated)
        onMessageChanged?(updated)
        let type = chat.isGroup ? "groupchat" : "chat"
        if omemoRequired(chat) || (chat.encryptionMode == .default && settings.string("encryption.default", "off") == "always") {
            if await sendEncryptedEdit(chat: chat, target: target, text: text) { return }
        }
        let xml = "<message to='\(XML.escape(chat.jid))' type='\(type)'><body>\(XML.escape(text))</body><replace xmlns='\(NS.correct)' id='\(XML.escape(target))'/><origin-id xmlns='\(NS.sid)' id='\(String.wardID())'/><store xmlns='\(NS.hints)'/></message>"
        _ = connection?.send(xml)
    }

    func retract(chat: Chat, message: Message) async {
        let target = chat.isGroup ? (message.stanzaId.isEmpty ? message.originId : message.stanzaId) : (message.originId.isEmpty ? message.msgId : message.originId)
        guard !target.isEmpty else { return }
        var updated = message
        updated.retracted = true
        updated.body = ""
        updated.attachments = []
        try? await database.updateMessage(updated)
        onMessageChanged?(updated)
        let type = chat.isGroup ? "groupchat" : "chat"
        if omemoRequired(chat) || (chat.encryptionMode == .default && settings.string("encryption.default", "off") == "always") {
            if await sendEncryptedRetraction(chat: chat, target: target) { return }
        }
        let xml = "<message to='\(XML.escape(chat.jid))' type='\(type)'><retract xmlns='\(NS.retract)' id='\(XML.escape(target))'/><origin-id xmlns='\(NS.sid)' id='\(String.wardID())'/><store xmlns='\(NS.hints)'/></message>"
        _ = connection?.send(xml)
    }

    func forward(_ message: Message, to chat: Chat) async {
        if let attachment = message.attachments.first, let path = attachment.localPath,
           FileManager.default.fileExists(atPath: path) {
            _ = await sendAttachment(chat: chat, fileURL: URL(fileURLWithPath: path), name: attachment.name,
                                     mime: attachment.mime, caption: message.body)
        } else {
            _ = await sendText(chat: chat, text: message.body)
        }
    }
}
