import Foundation

extension XMPPSession {
    func addContact(jid: String, name: String = "", message: String = "") async {
        let bare = JID.bare(jid)
        guard JID.valid(bare) else { return }
        var contact = roster[bare] ?? Contact(accountId: accountId, jid: bare)
        contact.inRoster = true
        if !name.isEmpty { contact.rosterName = name }
        roster[bare] = contact
        try? await database.saveContact(contact)
        onContactChanged?(contact)
        _ = connection?.send("<presence to='\(XML.escape(bare))' type='subscribe'>\(message.isEmpty ? "" : "<status>\(XML.escape(message))</status>")</presence>")
        if !name.isEmpty {
            _ = connection?.send("<iq type='set' id='ward-roster-\(String.wardID())'><query xmlns='\(NS.roster)'><item jid='\(XML.escape(bare))' name='\(XML.escape(name))'/></query></iq>")
        }
        _ = await ensureChat(jid: bare, type: .chat, name: name)
    }

    func removeContact(_ jid: String) async {
        let bare = JID.bare(jid)
        _ = connection?.send("<iq type='set' id='ward-roster-\(String.wardID())'><query xmlns='\(NS.roster)'><item jid='\(XML.escape(bare))' subscription='remove'/></query></iq>")
        roster.removeValue(forKey: bare)
        try? await database.deleteContact(accountId: accountId, jid: bare)
        if let chat = try? await database.chat(accountId: accountId, jid: bare) {
            try? await database.deleteChat(id: chat.id)
        }
        onChatsChanged?()
    }

    func setBlocked(jid: String, blocked: Bool) async {
        let bare = JID.bare(jid)
        let action = blocked ? "block" : "unblock"
        _ = connection?.send("<iq type='set' id='ward-block-\(String.wardID())'><\(action) xmlns='\(NS.blocklist)'><item jid='\(XML.escape(bare))'/></\(action)></iq>")
        if var contact = roster[bare] {
            contact.blocked = blocked
            roster[bare] = contact
            try? await database.saveContact(contact)
            onContactChanged?(contact)
        }
    }

    func acceptSubscription(_ jid: String) async {
        let bare = JID.bare(jid)
        _ = connection?.send("<presence to='\(XML.escape(bare))' type='subscribed'/>")
        _ = connection?.send("<presence to='\(XML.escape(bare))' type='subscribe'/>")
        try? await database.deleteRequest(accountId: accountId, jid: bare)
        if let chat = try? await database.chat(accountId: accountId, jid: bare) {
            var updated = chat
            updated.isRequest = false
            updated = (try? await database.saveChat(updated)) ?? updated
            onChatChanged?(updated)
        }
    }

    func declineSubscription(_ jid: String) async {
        let bare = JID.bare(jid)
        _ = connection?.send("<presence to='\(XML.escape(bare))' type='unsubscribed'/>")
        try? await database.deleteRequest(accountId: accountId, jid: bare)
    }

    func renameContact(_ jid: String, name: String) async {
        let bare = JID.bare(jid)
        if var contact = roster[bare] {
            contact.rosterName = name
            roster[bare] = contact
            try? await database.saveContact(contact)
            onContactChanged?(contact)
        }
        _ = connection?.send("<iq type='set' id='ward-roster-\(String.wardID())'><query xmlns='\(NS.roster)'><item jid='\(XML.escape(bare))' name='\(XML.escape(name))'/></query></iq>")
    }
}
