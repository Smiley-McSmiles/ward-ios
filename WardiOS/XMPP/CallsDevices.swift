import Foundation
import CryptoKit

// MARK: - Calls (Jingle Message Initiation signalling)

extension XMPPSession {
    func startCall(chat: Chat, video: Bool) async {
        guard settings.bool("calls.enabled") else {
            onToast?("Calls are turned off in Settings.", true)
            return
        }
        guard !chat.isGroup else {
            onToast?("Group calls are not supported.", true)
            return
        }
        let callID = UUID()
        var call = CallState(peer: chat.jid, accountId: accountId, kind: video ? .video : .audio,
                             status: .outgoing, incoming: false)
        call.id = callID
        activeCall = call
        onCallChanged?(call)
        let media = video ? "video" : "audio"
        let description = "<description xmlns='\(NS.jingleApps)' media='\(media)'><payload-type id='111' name='opus' channels='2' clockrate='48000'/><payload-type id='96' name='VP8' clockrate='90000'/></description>"
        _ = connection?.send("<message to='\(XML.escape(chat.jid))'><propose xmlns='\(NS.jingleMessage)' id='\(callID.uuidString.lowercased())'>\(description)</propose></message>")
        // Without a negotiated Jingle session the call stays in the ringing state. The UI
        // offers cancel/end so the signalling never leaves a ghost call behind.
    }

    func acceptCall() async {
        guard var call = activeCall, call.incoming else { return }
        call.status = .connecting
        call.startedAt = Date()
        activeCall = call
        onCallChanged?(call)
        _ = connection?.send("<message to='\(XML.escape(call.peer))'><accept xmlns='\(NS.jingleMessage)' id='\(call.id.uuidString.lowercased())'/></message>")
        onToast?("Call signalling connected. Audio and video media are not available in this build.", true)
    }

    func rejectCall() async {
        guard var call = activeCall else { return }
        _ = connection?.send("<message to='\(XML.escape(call.peer))'><reject xmlns='\(NS.jingleMessage)' id='\(call.id.uuidString.lowercased())'/></message>")
        call.status = .ended
        activeCall = nil
        onCallChanged?(nil)
    }

    func endCall() async {
        guard let call = activeCall else { return }
        _ = connection?.send("<message to='\(XML.escape(call.peer))'><finish xmlns='\(NS.jingleMessage)' id='\(call.id.uuidString.lowercased())'/></message>")
        activeCall = nil
        onCallChanged?(nil)
    }

    func toggleMute() {
        guard var call = activeCall else { return }
        call.muted.toggle()
        activeCall = call
        onCallChanged?(call)
    }

    func toggleSpeaker() {
        guard var call = activeCall else { return }
        call.speaker.toggle()
        activeCall = call
        onCallChanged?(call)
    }

    func toggleCamera() {
        guard var call = activeCall else { return }
        call.camera.toggle()
        activeCall = call
        onCallChanged?(call)
    }

    @discardableResult
    func handleCallStanza(_ node: XMLNode, directionOverride: Int?) -> Bool {
        let proposal = node.child("propose", xmlns: NS.jingleMessage)
        let accept = node.child("accept", xmlns: NS.jingleMessage)
        let reject = node.child("reject", xmlns: NS.jingleMessage)
        let proceed = node.child("proceed", xmlns: NS.jingleMessage)
        let finish = node.child("finish", xmlns: NS.jingleMessage)
        let retract = node.child("retract", xmlns: NS.jingleMessage)
        let ringing = node.child("ringing", xmlns: NS.jingleMessage)
        guard proposal != nil || accept != nil || reject != nil || proceed != nil || finish != nil || retract != nil || ringing != nil else {
            return false
        }
        guard settings.bool("calls.enabled") else { return true }
        if let proposal, let from = node.attr("from") {
            let id = proposal.attr("id", String.wardID())
            let media = proposal.child("description", xmlns: NS.jingleApps)?.attr("media", "audio") ?? "audio"
            var call = CallState(peer: JID.bare(from), accountId: accountId,
                                 kind: media == "video" ? .video : .audio,
                                 status: .ringing, incoming: true)
            call.id = UUID(uuidString: id) ?? UUID()
            call.incoming = true
            activeCall = call
            onCallChanged?(call)
            return true
        }
        if accept != nil || proceed != nil {
            if var call = activeCall {
                call.status = .active
                call.startedAt = Date()
                activeCall = call
                onCallChanged?(call)
            }
            return true
        }
        if ringing != nil {
            if var call = activeCall {
                call.status = .ringing
                activeCall = call
                onCallChanged?(call)
            }
            return true
        }
        if reject != nil || finish != nil || retract != nil {
            activeCall = nil
            onCallChanged?(nil)
            return true
        }
        return true
    }
}

// MARK: - OMEMO device lists

extension XMPPSession {
    func loadDevices(jid: String) async {
        var devices: [Device] = []
        let nodes = [NS.omemo2 + ":devices", "eu.siacs.conversations.axolotl.devicelist"]
        for node in nodes {
            let xml = "<pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='\(node)'/></pubsub>"
            guard let result = await iqRequest(xml, to: jid, timeout: 15) else { continue }
            if let items = result.child("pubsub")?.child("items") {
                for item in items.children("item") {
                    if let id = item.attr("id"), let deviceID = Int64(id), deviceID != 0 {
                        let isOwn = JID.bare(jid) == account.bareJID
                        let device = Device(accountId: accountId, jid: JID.bare(jid), deviceId: deviceID,
                                            label: isOwn ? "This account" : "Device \(deviceID)",
                                            trust: "undecided", active: true, own: isOwn,
                                            thisDevice: isOwn && deviceID == Int64(SecureStore.shared.deviceId()),
                                            protocolName: node.contains("omemo:2") ? "omemo2" : "omemo")
                        devices.append(device)
                        try? await database.saveDevice(device)
                    }
                }
                if !devices.isEmpty { continue }
            }
            if let list = result.child("pubsub")?.child("items")?.child("item")?.child("devices") {
                for device in list.children("device") {
                    if let id = device.attr("id"), let deviceID = Int64(id) {
                        let isOwn = JID.bare(jid) == account.bareJID
                        let entry = Device(accountId: accountId, jid: JID.bare(jid), deviceId: deviceID,
                                           label: isOwn ? "This account" : "Device \(deviceID)",
                                           own: isOwn, protocolName: "omemo")
                        devices.append(entry)
                        try? await database.saveDevice(entry)
                    }
                }
            }
        }
        for index in devices.indices where devices[index].protocolName == "omemo2" && devices[index].fingerprint.isEmpty {
            if let fingerprint = await fetchBundleFingerprint(jid: devices[index].jid, deviceId: devices[index].deviceId) {
                devices[index].fingerprint = fingerprint
                try? await database.saveDevice(devices[index])
            }
        }
        onDevicesChanged?(jid)
    }

    private func fetchBundleFingerprint(jid: String, deviceId: Int64) async -> String? {
        let xml = "<pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='\(NS.omemo2):bundles'><item id='\(deviceId)'/></items></pubsub>"
        guard let result = await iqRequest(xml, to: JID.bare(jid), timeout: 15),
              let bundle = result.child("pubsub")?.child("items")?.children("item").first?.child("bundle", xmlns: NS.omemo2),
              let encoded = bundle.child("ik")?.trimmedText,
              let data = Data(base64Encoded: encoded) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func trustDevice(jid: String, deviceId: Int64, fingerprint: String, trusted: Bool, protocolName: String = "omemo2") async {
        try? await database.setDeviceTrust(accountId: accountId, jid: jid, deviceId: deviceId,
                                           protocolName: protocolName, trust: trusted ? "trusted" : "distrusted")
        onDevicesChanged?(jid)
    }

    func forgetDevice(jid: String, deviceId: Int64, protocolName: String) async {
        try? await database.deleteDevice(accountId: accountId, jid: jid, deviceId: deviceId, protocolName: protocolName)
        onDevicesChanged?(jid)
    }

    func publishOwnDevice() {
        // Kept deliberately conservative until the OMEMO ratchet is wired: publishing a device
        // list without a matching bundle makes encrypted messages undecryptable for everyone.
        guard settings.bool("encryption.legacy_omemo") else { return }
    }
}
