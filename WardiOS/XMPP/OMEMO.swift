import Foundation
import WardCrypto

extension XMPPSession {
    // MARK: - Setup

    func setupOMEMO() async {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OMEMO", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("account-\(accountId).json")
        do {
            let engine = try OMEMOEngine(storeURL: url)
            omemo = engine
            await publishOMEMOProfile()
        } catch {
            onToast?("OMEMO initialization failed: \(error.localizedDescription)", true)
            onXml?(false, "OMEMO initialization failed: \(error)")
        }
    }

    func publishOMEMOProfile() async {
        guard let engine = omemo, isOnline else { return }
        var existing: [UInt32] = []
        guard let listResult = await iqRequest("<pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='\(NS.omemo2):devices'/></pubsub>",
                                               to: account.bareJID, timeout: 15) else {
            // Never replace another device's list with a list we could not read.
            return
        }
        if listResult.attr("type") == "error" {
            // A brand new account has no device list yet. Any other error must not clobber it.
            guard listResult.child("error")?.child("item-not-found") != nil else { return }
        } else if let items = listResult.child("pubsub")?.child("items") {
            for item in items.children("item") {
                for device in item.child("devices", xmlns: NS.omemo2)?.children("device") ?? [] {
                    if let value = device.attr("id").flatMap(UInt32.init) { existing.append(value) }
                }
            }
        }
        let deviceXML = engine.deviceListXML(including: existing)
        let deviceOptions = optionsXML(accessModel: "open", maxItems: "1")
        _ = await iqRequest("""
        <pubsub xmlns='http://jabber.org/protocol/pubsub'><publish node='\(NS.omemo2):devices'><item id='current'>\(deviceXML)</item></publish>\(deviceOptions)</pubsub>
        """, to: account.bareJID, type: "set", timeout: 20)

        let bundleXML = engine.bundleXML()
        let bundleOptions = optionsXML(accessModel: "open", maxItems: "max")
        let result = await iqRequest("""
        <pubsub xmlns='http://jabber.org/protocol/pubsub'><publish node='\(NS.omemo2):bundles'><item id='\(engine.deviceId)'>\(bundleXML)</item></publish>\(bundleOptions)</pubsub>
        """, to: account.bareJID, type: "set", timeout: 25)
        if result?.attr("type") == "error", !omemoPublishFailureShown {
            omemoPublishFailureShown = true
            onToast?("Your server refused the OMEMO bundle publish. Check its PEP/pubsub configuration.", true)
        }
    }

    private func optionsXML(accessModel: String, maxItems: String) -> String {
        "<publish-options><x xmlns='\(NS.data)' type='submit'><field var='FORM_TYPE' type='hidden'><value>http://jabber.org/protocol/pubsub#publish-options</value></field><field var='pubsub#access_model'><value>\(accessModel)</value></field><field var='pubsub#max_items'><value>\(maxItems)</value></field></x></publish-options>"
    }

    // MARK: - Bundles

    func fetchOMEMOBundles(jid: String) async -> [OMEMOBundle] {
        let bare = JID.bare(jid)
        if let cached = omemoBundleCache[bare], Date().timeIntervalSince(cached.date) < 300 {
            return await trustedOMEMOBundles(cached.bundles, jid: bare)
        }
        guard let result = await iqRequest("<pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='\(NS.omemo2):devices'/></pubsub>",
                                           to: bare, timeout: 20),
              let items = result.child("pubsub")?.child("items") else { return [] }
        var ids: [UInt32] = []
        for item in items.children("item") {
            for device in item.child("devices", xmlns: NS.omemo2)?.children("device") ?? [] {
                guard let id = device.attr("id").flatMap(UInt32.init) else { continue }
                // Device ids are only unique per account: never skip a contact's device just
                // because it happens to share this device's numeric id.
                if bare == account.bareJID && id == omemo?.deviceId { continue }
                ids.append(id)
            }
        }
        var bundles: [OMEMOBundle] = []
        for deviceId in ids.prefix(30) {
            let request = "<pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='\(NS.omemo2):bundles'><item id='\(deviceId)'/></items></pubsub>"
            guard let response = await iqRequest(request, to: bare, timeout: 20),
                  let item = response.child("pubsub")?.child("items")?.children("item").first,
                  let bundle = parseBundle(item, deviceId: deviceId) else { continue }
            await recordOMEMODevice(jid: bare, bundle: bundle)
            bundles.append(bundle)
        }
        omemoBundleCache[bare] = (Date(), bundles)
        return await trustedOMEMOBundles(bundles, jid: bare)
    }

    private func trustedOMEMOBundles(_ bundles: [OMEMOBundle], jid: String) async -> [OMEMOBundle] {
        let devices = (try? await database.devices(accountId: accountId, jid: jid)) ?? []
        let manual = settings.string("encryption.trust", "btbv") == "manual"
        let blocked = Set(devices.filter {
            $0.protocolName == "omemo2"
                && ($0.trust == "distrusted" || (manual && $0.trust != "trusted"))
        }.map { UInt32(truncatingIfNeeded: $0.deviceId) })
        return bundles.filter { !blocked.contains($0.deviceId) }
    }

    private func parseBundle(_ item: XMLNode, deviceId: UInt32) -> OMEMOBundle? {
        guard let bundle = item.child("bundle", xmlns: NS.omemo2),
              let identity = bundle.child("ik")?.trimmedText,
              let signed = bundle.child("spk")?.trimmedText,
              let signature = bundle.child("spks")?.trimmedText,
              let identityData = Data(base64Encoded: identity),
              let signedData = Data(base64Encoded: signed),
              let signatureData = Data(base64Encoded: signature),
              let signedId = bundle.child("spk")?.attr("id").flatMap(UInt32.init) else { return nil }
        var preKeys: [OMEMOPublicPreKey] = []
        for key in bundle.child("prekeys")?.children("pk") ?? [] {
            guard let id = key.attr("id").flatMap(UInt32.init),
                  let value = Data(base64Encoded: key.trimmedText) else { continue }
            preKeys.append(OMEMOPublicPreKey(id: id, publicKey: value))
        }
        guard !preKeys.isEmpty else { return nil }
        return OMEMOBundle(deviceId: deviceId, identityKey: identityData,
                           signedPreKeyId: signedId, signedPreKey: signedData,
                           signedPreKeySignature: signatureData, preKeys: preKeys)
    }

    private func recordOMEMODevice(jid: String, bundle: OMEMOBundle) async {
        let fingerprint = CryptoPrimitives.fingerprint(bundle.identityKey)
        let existing = (try? await database.devices(accountId: accountId, jid: jid))?.first {
            $0.deviceId == Int64(bundle.deviceId) && $0.protocolName == "omemo2"
        }
        let trust: String
        if let existing {
            if existing.fingerprint != fingerprint {
                trust = "distrusted"
                onToast?("The OMEMO identity key for \(jid) device \(bundle.deviceId) changed. Verify it before sending.", true)
            } else {
                trust = existing.trust
            }
        } else {
            trust = settings.string("encryption.trust", "btbv") == "btbv" ? "trusted" : "undecided"
        }
        let device = Device(accountId: accountId, jid: jid, deviceId: Int64(bundle.deviceId),
                            fingerprint: fingerprint, label: "Device \(bundle.deviceId)",
                            trust: trust, own: jid == account.bareJID, thisDevice: false,
                            protocolName: "omemo2")
        try? await database.saveDevice(device)
        onDevicesChanged?(jid)
    }

    func recordOMEMOIdentity(jid: String, deviceId: UInt32, identityKey: Data) async {
        let fingerprint = CryptoPrimitives.fingerprint(identityKey)
        let existing = (try? await database.devices(accountId: accountId, jid: jid))?.first {
            $0.deviceId == Int64(deviceId) && $0.protocolName == "omemo2"
        }
        let trust: String
        if let existing {
            if existing.fingerprint != fingerprint {
                trust = "distrusted"
                onToast?("The OMEMO identity key for \(jid) device \(deviceId) changed. Verify it before sending.", true)
            } else {
                trust = existing.trust
            }
        } else {
            trust = settings.string("encryption.trust", "btbv") == "btbv" ? "trusted" : "undecided"
        }
        let device = Device(accountId: accountId, jid: jid, deviceId: Int64(deviceId),
                            fingerprint: fingerprint, label: "Device \(deviceId)",
                            trust: trust, own: jid == account.bareJID, thisDevice: false,
                            protocolName: "omemo2")
        try? await database.saveDevice(device)
        onDevicesChanged?(jid)
    }

    // MARK: - Encryption

    func omemoRequired(_ chat: Chat) -> Bool {
        if chat.encryptionMode == .omemo { return true }
        if chat.encryptionMode == .default { return settings.string("encryption.default", "off") == "always" }
        return false
    }

    func messageContentXML(_ message: Message, chat: Chat) -> String {
        var children: [String] = []
        if !message.body.isEmpty {
            children.append("<body xmlns='jabber:client'>\(XML.escape(message.body))</body>")
        }
        if !message.replyTo.isEmpty {
            let to = chat.isGroup ? "" : " to='\(XML.escape(chat.jid))'"
            let preview = message.replyPreview.isEmpty ? "" : "<fallback xmlns='\(NS.fallback)'><body xmlns='jabber:client'>\(XML.escape(message.replyPreview))</body></fallback>"
            children.append("<reply xmlns='\(NS.reply)' id='\(XML.escape(message.replyTo))'\(to)>\(preview)</reply>")
        }
        children.append("<markdown xmlns='\(NS.markdown)'/>")
        if let attachment = message.attachments.first, !attachment.url.isEmpty {
            var file = "<name>\(XML.escape(attachment.name))</name><size>\(attachment.size)</size>"
            if !attachment.mime.isEmpty { file += "<media-type>\(XML.escape(attachment.mime))</media-type>" }
            if attachment.width > 0 { file += "<width>\(Int(attachment.width))</width>" }
            if attachment.height > 0 { file += "<height>\(Int(attachment.height))</height>" }
            children.append("<file-sharing xmlns='\(NS.sfs)' disposition='inline'><file xmlns='\(NS.file)'>\(file)</file><sources><url-data xmlns='http://jabber.org/protocol/url-data' target='\(XML.escape(attachment.url))'/></sources></file-sharing>")
            children.append("<x xmlns='\(NS.oob)'><url>\(XML.escape(attachment.url))</url><desc>\(XML.escape(attachment.name))</desc></x>")
        }
        return children.joined()
    }

    func encryptAndSend(_ chat: Chat, contentXML: String, messageId: String, extra: [String] = []) async throws -> Bool {
        guard let engine = omemo else { throw WardCryptoError.noSession }
        guard !chat.isGroup else { throw WardCryptoError.encryption("OMEMO group chats are not implemented yet.") }
        let bundles = await fetchOMEMOBundles(jid: chat.jid)
        guard !bundles.isEmpty else { throw WardCryptoError.noDevices }
        let ownBundles = await fetchOMEMOBundles(jid: account.bareJID)
        var recipients = [OMEMORecipient(jid: chat.jid, bundles: bundles)]
        if !ownBundles.isEmpty {
            recipients.append(OMEMORecipient(jid: account.bareJID, bundles: ownBundles))
        }
        let outgoing = try engine.encrypt(contentXML: contentXML,
                                          recipients: recipients,
                                          fromJID: account.bareJID)
        var groups: [String: [OMEMOKey]] = [:]
        for key in outgoing.keys { groups[key.jid, default: []].append(key) }
        var keysXML = ""
        for jid in groups.keys.sorted() {
            keysXML += "<keys jid='\(XML.escape(jid))'>"
            for key in groups[jid] ?? [] {
                let kex = key.keyExchange ? " kex='true'" : ""
                keysXML += "<key rid='\(key.deviceId)'\(kex)>\(key.data)</key>"
            }
            keysXML += "</keys>"
        }
        let payload = outgoing.payload.map { "<payload>\($0)</payload>" } ?? ""
        let encrypted = "<encrypted xmlns='\(NS.omemo2)'><header sid='\(outgoing.senderDeviceId)'>\(keysXML)</header>\(payload)</encrypted>"
        let eme = "<encryption xmlns='\(NS.eme)' namespace='\(NS.omemo2)' name='OMEMO'/>"
        let outer = [
            "<origin-id xmlns='\(NS.sid)' id='\(XML.escape(messageId))'/>",
            "<markable xmlns='\(NS.markers)'/>",
            "<request xmlns='\(NS.receipts)'/>",
            "<active xmlns='\(NS.chatstates)'/>",
            encrypted, eme,
            "<store xmlns='\(NS.hints)'/>"
        ] + extra
        let stanza = "<message to='\(XML.escape(chat.jid))' type='\(chat.isGroup ? "groupchat" : "chat")' id='\(XML.escape(messageId))'>\(outer.joined())</message>"
        return connection?.send(stanza) ?? false
    }

    func sendEncryptedReaction(chat: Chat, target: String, emojis: [String]) async -> Bool {
        let reactions = "<reactions xmlns='\(NS.reactions)' id='\(XML.escape(target))'>" + emojis.map { "<reaction>\(XML.escape($0))</reaction>" }.joined() + "</reactions>"
        return (try? await encryptAndSend(chat, contentXML: reactions, messageId: String.wardID())) ?? false
    }

    func sendEncryptedEdit(chat: Chat, target: String, text: String) async -> Bool {
        let content = "<body xmlns='jabber:client'>\(XML.escape(text))</body><replace xmlns='\(NS.correct)' id='\(XML.escape(target))'/>"
        return (try? await encryptAndSend(chat, contentXML: content, messageId: String.wardID())) ?? false
    }

    func sendEncryptedRetraction(chat: Chat, target: String) async -> Bool {
        let content = "<retract xmlns='\(NS.retract)' id='\(XML.escape(target))'/>"
        return (try? await encryptAndSend(chat, contentXML: content, messageId: String.wardID())) ?? false
    }

    /// Sends the empty OMEMO message that tells the initiator their session is confirmed. Some
    /// clients keep repeating the X3DH header until they receive one of these.
    func sendOMEMOConfirmation(senderJID: String, deviceId: UInt32) async {
        guard let engine = omemo, senderJID != account.bareJID,
              let key = try? engine.confirmation(senderJID: senderJID, deviceId: deviceId) else { return }
        let kex = key.keyExchange ? " kex='true'" : ""
        let stanza = """
        <message to='\(XML.escape(senderJID))' type='chat' id='\(String.wardID())'>\
        <encrypted xmlns='\(NS.omemo2)'><header sid='\(engine.deviceId)'><keys jid='\(XML.escape(senderJID))'>\
        <key rid='\(deviceId)'\(kex)>\(key.data)</key></keys></header></encrypted>\
        <store xmlns='\(NS.hints)'/></message>
        """
        _ = connection?.send(stanza)
    }

    // MARK: - Decryption

    func decryptOMEMO(_ encrypted: XMLNode, source: XMLNode) async -> XMLNode? {
        guard let engine = omemo else { return nil }
        guard let header = encrypted.child("header"),
              let sid = header.attr("sid").flatMap(UInt32.init) else { return nil }
        let ownJID = account.bareJID
        guard let keys = header.children("keys").first(where: { JID.bare($0.attr("jid", "")) == ownJID }),
              let key = keys.children("key").first(where: { $0.attr("rid").flatMap(UInt32.init) == engine.deviceId }) else {
            let sender = JID.bare(source.attr("from", ""))
            if sender != ownJID { onToast?("An OMEMO message was not encrypted for this device.", true) }
            return nil
        }
        guard let keyData = key.trimmedText as String?, !keyData.isEmpty else { return nil }
        let kex = key.attr("kex", "false") == "true"
        let payload = encrypted.child("payload")?.trimmedText
        let senderJID = JID.bare(source.attr("from", ""))
        let trust = (try? await database.devices(accountId: accountId, jid: senderJID))?
            .first { $0.deviceId == Int64(sid) && $0.protocolName == "omemo2" }?.trust
        if trust == "distrusted" {
            onToast?("Ignored a message from a distrusted OMEMO device.", true)
            onXml?(false, "Ignored OMEMO message from distrusted \(senderJID)/\(sid)")
            return nil
        }
        do {
            guard let decrypted = try engine.decrypt(keyBase64: keyData, keyExchange: kex,
                                                     senderJID: senderJID, senderDevice: sid,
                                                     payloadBase64: payload) else { return nil }
            await recordOMEMOIdentity(jid: senderJID, deviceId: sid, identityKey: decrypted.senderIdentity)
            if kex {
                Task { await self.publishOMEMOProfile() }
                // Group messages are addressed to the room; a confirmation only makes sense 1:1.
                if source.attr("type", "chat") != "groupchat" {
                    await self.sendOMEMOConfirmation(senderJID: senderJID, deviceId: sid)
                }
            }
            guard let contentXML = decrypted.contentXML,
                  let root = XML.parse("<content>\(contentXML)</content>") else { return nil }
            var effective = source
            // Drop the outer cleartext fallback body and encryption hints; only authenticated
            // content from inside the SCE envelope may reach the message pipeline.
            effective.children.removeAll {
                $0.name == "encrypted" || $0.name == "body" || $0.name == "encryption"
            }
            effective.children.append(contentsOf: root.children)
            return effective
        } catch {
            onToast?("Could not decrypt an OMEMO message: \(error.localizedDescription)", true)
            onXml?(false, "OMEMO decrypt failed from \(senderJID)/\(sid): \(error)")
            return nil
        }
    }
}
