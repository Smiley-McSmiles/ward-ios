import Foundation

/// A one-to-one OMEMO 2 engine. It owns the device identity, prekeys, ratchet sessions and the
/// OMEMO wire encoding. The XMPP layer supplies bundles and carries the resulting keys; this type
/// never performs network I/O and never falls back to plaintext.
public final class OMEMOEngine {
    /// XEP-0384 mandates prefixing the X3DH HKDF input with 32 bytes of 0xFF.
    static let x3dhPadding = Data(repeating: 0xFF, count: 32)

    public private(set) var identity: OMEMOIdentity
    private var sessions: [String: OMEMOSessionRecord]
    private let storeURL: URL?

    public init(storeURL: URL?) throws {
        self.storeURL = storeURL
        if let storeURL, let data = try? Data(contentsOf: storeURL),
           let stored = try? JSONDecoder().decode(OMEMOStoreData.self, from: data) {
            identity = stored.identity
            sessions = stored.sessions
        } else {
            identity = try OMEMOIdentity.generate()
            sessions = [:]
            try save()
        }
        try identity.replenishPreKeys()
    }

    public var deviceId: UInt32 { identity.deviceId }
    public var fingerprint: String { CryptoPrimitives.fingerprint(identity.identity.publicKey) }

    public func save() throws {
        guard let storeURL else { return }
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(OMEMOStoreData(identity: identity, sessions: sessions))
        #if os(iOS)
        try data.write(to: storeURL, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                               ofItemAtPath: storeURL.path)
        #else
        try data.write(to: storeURL, options: .atomic)
        #endif
    }

    public func bundleXML() -> String {
        var prekeys = ""
        for prekey in identity.preKeys {
            prekeys += "<pk id='\(prekey.id)'>\(prekey.publicKey.base64)</pk>"
        }
        return "<bundle xmlns='urn:xmpp:omemo:2'><spk id='\(identity.signedPreKeyId)'>\(identity.signedPreKey.publicKey.base64)</spk><spks>\(identity.signedPreKeySignature.base64)</spks><ik>\(identity.identity.publicKey.base64)</ik><prekeys>\(prekeys)</prekeys></bundle>"
    }

    public func deviceListXML(including existing: [UInt32] = []) -> String {
        var ids = Set(existing)
        ids.insert(identity.deviceId)
        let devices = ids.sorted().map { "<device id='\($0)'/>" }.joined()
        return "<devices xmlns='urn:xmpp:omemo:2'>\(devices)</devices>"
    }

    public func buildSessions(jid: String, bundles: [OMEMOBundle]) throws {
        for bundle in bundles where bundle.deviceId != identity.deviceId {
            let key = sessionKey(jid: jid, deviceId: bundle.deviceId)
            guard sessions[key] == nil else { continue }
            sessions[key] = try makeInitiatorSession(jid: jid, bundle: bundle)
        }
        try save()
    }

    public func hasSession(jid: String, deviceId: UInt32) -> Bool {
        sessions[sessionKey(jid: jid, deviceId: deviceId)] != nil
    }

    /// Removes a ratchet session so a reinstalled or re-verified device can perform a new X3DH.
    public func forgetSession(jid: String, deviceId: UInt32) {
        sessions.removeValue(forKey: sessionKey(jid: jid, deviceId: deviceId))
        try? save()
    }

    public func encrypt(contentXML: String, recipients: [OMEMORecipient], fromJID: String) throws -> OMEMOOutgoing {
        let envelope = try SCE.envelope(contentXML: contentXML, from: fromJID)
        let payloadKey = try CryptoPrimitives.randomBytes(32)
        let payloadMaterial = CryptoPrimitives.hkdf(ikm: payloadKey, salt: Data(repeating: 0, count: 32),
                                                    info: "OMEMO Payload", count: 80)
        let encryptionKey = payloadMaterial.prefix(32)
        let authenticationKey = payloadMaterial.dropFirst(32).prefix(32)
        let iv = payloadMaterial.suffix(16)
        let encryptedPayload = try CryptoPrimitives.aesCBCEncrypt(Data(envelope.utf8), key: Data(encryptionKey), iv: Data(iv))
        let payloadMAC = CryptoPrimitives.hmac(key: Data(authenticationKey), message: encryptedPayload).prefix(16)
        let ratchetPlaintext = payloadKey + payloadMAC

        var keys: [OMEMOKey] = []
        for recipient in recipients {
            for bundle in recipient.bundles where bundle.deviceId != identity.deviceId {
                let key = sessionKey(jid: recipient.jid, deviceId: bundle.deviceId)
                if sessions[key] == nil {
                    sessions[key] = try makeInitiatorSession(jid: recipient.jid, bundle: bundle)
                }
                guard var session = sessions[key] else { continue }
                let authenticated = try session.ratchet.encrypt(ratchetPlaintext, associatedData: session.associatedData)
                if let context = session.pendingKex {
                    let exchange = OMEMOKeyExchange(preKeyId: context.preKeyId,
                                                    signedPreKeyId: context.signedPreKeyId,
                                                    identityKey: context.identityKey,
                                                    ephemeralKey: context.ephemeralKey,
                                                    message: authenticated)
                    keys.append(OMEMOKey(jid: recipient.jid, deviceId: bundle.deviceId,
                                         data: exchange.encoded().base64, keyExchange: true))
                } else {
                    keys.append(OMEMOKey(jid: recipient.jid, deviceId: bundle.deviceId,
                                         data: authenticated.encoded().base64, keyExchange: false))
                }
                sessions[key] = session
            }
        }
        guard !keys.isEmpty else { throw WardCryptoError.noDevices }
        try save()
        return OMEMOOutgoing(senderDeviceId: identity.deviceId, keys: keys,
                             payload: encryptedPayload.base64)
    }

    /// Encrypts an empty OMEMO message used to confirm a key exchange (no payload).
    public func confirmation(senderJID: String, deviceId: UInt32) throws -> OMEMOKey? {
        let key = sessionKey(jid: senderJID, deviceId: deviceId)
        guard var session = sessions[key] else { return nil }
        let zeros = Data(repeating: 0, count: 32)
        let authenticated = try session.ratchet.encrypt(zeros, associatedData: session.associatedData)
        let result: OMEMOKey
        if let context = session.pendingKex {
            let exchange = OMEMOKeyExchange(preKeyId: context.preKeyId, signedPreKeyId: context.signedPreKeyId,
                                            identityKey: context.identityKey, ephemeralKey: context.ephemeralKey,
                                            message: authenticated)
            result = OMEMOKey(jid: senderJID, deviceId: deviceId, data: exchange.encoded().base64, keyExchange: true)
        } else {
            result = OMEMOKey(jid: senderJID, deviceId: deviceId, data: authenticated.encoded().base64, keyExchange: false)
        }
        sessions[key] = session
        try save()
        return result
    }

    public func decrypt(keyBase64: String, keyExchange: Bool, senderJID: String,
                        senderDevice: UInt32, payloadBase64: String?) throws -> OMEMODecrypted? {
        guard let keyData = Data(base64Encoded: keyBase64) else {
            throw WardCryptoError.invalidMessage("The OMEMO key is not valid base64.")
        }
        let sessionKey = sessionKey(jid: senderJID, deviceId: senderDevice)
        let plaintext: Data
        let identityKey: Data

        if keyExchange {
            let exchange = try OMEMOKeyExchange.decode(keyData)
            if let existing = sessions[sessionKey], existing.remoteIdentityKey != exchange.identityKey {
                // Never silently replace a known identity. The user must remove and re-verify the device.
                throw WardCryptoError.authentication("The OMEMO identity key for this device changed.")
            }
            if var existing = sessions[sessionKey], existing.remoteKexEphemeral == exchange.ephemeralKey,
               existing.ratchet.remotePublic != nil {
                // A sender repeats the X3DH header until it receives a reply. Keep the existing
                // ratchet instead of rebuilding and consuming the prekey again.
                plaintext = try existing.ratchet.decrypt(exchange.message, associatedData: existing.associatedData)
                identityKey = exchange.identityKey
                existing.confirmed = true
                existing.pendingKex = nil
                sessions[sessionKey] = existing
            } else {
                var session = try makeResponderSession(senderJID: senderJID, senderDevice: senderDevice, exchange: exchange)
                plaintext = try session.ratchet.decrypt(exchange.message, associatedData: session.associatedData)
                identityKey = exchange.identityKey
                session.confirmed = true
                session.pendingKex = nil
                sessions[sessionKey] = session
            }
            try save()
        } else {
            guard var session = sessions[sessionKey] else { throw WardCryptoError.noSession }
            let authenticated = try AuthenticatedRatchetMessage.decode(keyData)
            plaintext = try session.ratchet.decrypt(authenticated, associatedData: session.associatedData)
            identityKey = session.remoteIdentityKey
            session.confirmed = true
            session.pendingKex = nil
            sessions[sessionKey] = session
            try save()
        }

        guard let payloadBase64 else {
            return OMEMODecrypted(senderDeviceId: senderDevice, senderIdentity: identityKey,
                                  envelopeXML: nil, contentXML: nil)
        }
        guard plaintext.count == 48, let payload = Data(base64Encoded: payloadBase64) else {
            throw WardCryptoError.invalidMessage("The OMEMO payload is incomplete.")
        }
        let payloadKey = plaintext.prefix(32)
        let payloadMAC = plaintext.dropFirst(32).prefix(16)
        let material = CryptoPrimitives.hkdf(ikm: Data(payloadKey), salt: Data(repeating: 0, count: 32),
                                             info: "OMEMO Payload", count: 80)
        let encryptionKey = material.prefix(32)
        let authenticationKey = material.dropFirst(32).prefix(32)
        let iv = material.suffix(16)
        let expected = CryptoPrimitives.hmac(key: Data(authenticationKey), message: payload).prefix(16)
        guard constantTimeEqual(Data(expected), Data(payloadMAC)) else {
            throw WardCryptoError.authentication("The OMEMO payload authentication tag is invalid.")
        }
        let envelopeData = try CryptoPrimitives.aesCBCDecrypt(payload, key: Data(encryptionKey), iv: Data(iv))
        let envelope = String(decoding: envelopeData, as: UTF8.self)
        return OMEMODecrypted(senderDeviceId: senderDevice, senderIdentity: identityKey,
                              envelopeXML: envelope, contentXML: extractContent(envelope))
    }

    public func sessionFingerprint(jid: String, deviceId: UInt32) -> String? {
        sessions[sessionKey(jid: jid, deviceId: deviceId)]?.fingerprint
    }

    private func makeInitiatorSession(jid: String, bundle: OMEMOBundle) throws -> OMEMOSessionRecord {
        guard CryptoPrimitives.verify(signature: bundle.signedPreKeySignature,
                                      message: bundle.signedPreKey,
                                      publicKey: bundle.identityKey) else {
            throw WardCryptoError.invalidBundle
        }
        guard let prekey = bundle.preKeys.randomElement() else { throw WardCryptoError.noPreKey }
        let ephemeral = try CryptoPrimitives.x25519KeyPair()
        let ownIdentityX = try CryptoPrimitives.edSecretToX25519(identity.identity.secretKey)
        let remoteIdentityX = try CryptoPrimitives.edPublicToX25519(bundle.identityKey)
        let dh1 = try CryptoPrimitives.dh(secretKey: ownIdentityX, publicKey: bundle.signedPreKey)
        let dh2 = try CryptoPrimitives.dh(secretKey: ephemeral.secretKey, publicKey: remoteIdentityX)
        let dh3 = try CryptoPrimitives.dh(secretKey: ephemeral.secretKey, publicKey: bundle.signedPreKey)
        let dh4 = try CryptoPrimitives.dh(secretKey: ephemeral.secretKey, publicKey: prekey.publicKey)
        let shared = CryptoPrimitives.hkdf(ikm: Self.x3dhPadding + dh1 + dh2 + dh3 + dh4,
                                           salt: Data(repeating: 0, count: 32),
                                           info: "OMEMO X3DH", count: 32)
        let ad = identity.identity.publicKey + bundle.identityKey
        let ratchet = try RatchetState.initiator(sharedSecret: shared, remoteSignedPreKey: bundle.signedPreKey)
        return OMEMOSessionRecord(jid: jid, deviceId: bundle.deviceId, ratchet: ratchet,
                                  associatedData: ad,
                                  pendingKex: KexContext(preKeyId: prekey.id,
                                                         signedPreKeyId: bundle.signedPreKeyId,
                                                         identityKey: identity.identity.publicKey,
                                                         ephemeralKey: ephemeral.publicKey),
                                  confirmed: false,
                                  fingerprint: CryptoPrimitives.fingerprint(bundle.identityKey),
                                  remoteIdentityKey: bundle.identityKey,
                                  remoteKexEphemeral: nil)
    }

    private func makeResponderSession(senderJID: String, senderDevice: UInt32,
                                      exchange: OMEMOKeyExchange) throws -> OMEMOSessionRecord {
        guard exchange.signedPreKeyId == identity.signedPreKeyId else {
            throw WardCryptoError.invalidMessage("The OMEMO signed prekey is unknown.")
        }
        let allPreKeys = identity.preKeys + identity.usedPreKeys
        guard let prekey = allPreKeys.first(where: { $0.id == exchange.preKeyId }) else {
            throw WardCryptoError.noPreKey
        }
        let remoteIdentityX = try CryptoPrimitives.edPublicToX25519(exchange.identityKey)
        let ownIdentityX = try CryptoPrimitives.edSecretToX25519(identity.identity.secretKey)
        let dh1 = try CryptoPrimitives.dh(secretKey: identity.signedPreKey.secretKey, publicKey: remoteIdentityX)
        let dh2 = try CryptoPrimitives.dh(secretKey: ownIdentityX, publicKey: exchange.ephemeralKey)
        let dh3 = try CryptoPrimitives.dh(secretKey: identity.signedPreKey.secretKey, publicKey: exchange.ephemeralKey)
        let dh4 = try CryptoPrimitives.dh(secretKey: prekey.secretKey, publicKey: exchange.ephemeralKey)
        let shared = CryptoPrimitives.hkdf(ikm: Self.x3dhPadding + dh1 + dh2 + dh3 + dh4,
                                           salt: Data(repeating: 0, count: 32),
                                           info: "OMEMO X3DH", count: 32)
        let ad = exchange.identityKey + identity.identity.publicKey
        let ratchet = try RatchetState.responder(sharedSecret: shared, signedPreKey: identity.signedPreKey)
        if let index = identity.preKeys.firstIndex(where: { $0.id == prekey.id }) {
            identity.preKeys.remove(at: index)
            identity.usedPreKeys.append(prekey)
            try identity.replenishPreKeys()
        }
        return OMEMOSessionRecord(jid: senderJID, deviceId: senderDevice, ratchet: ratchet,
                                  associatedData: ad, pendingKex: nil, confirmed: true,
                                  fingerprint: CryptoPrimitives.fingerprint(exchange.identityKey),
                                  remoteIdentityKey: exchange.identityKey,
                                  remoteKexEphemeral: exchange.ephemeralKey)
    }

    func extractContentForTesting(_ envelope: String) -> String? { extractContent(envelope) }

    private func extractContent(_ envelope: String) -> String? {
        guard let open = envelope.range(of: "<content"),
              let openEnd = envelope[open.upperBound...].firstIndex(of: ">"),
              let end = envelope.range(of: "</content>", options: .backwards),
              openEnd < end.lowerBound else { return nil }
        return String(envelope[envelope.index(after: openEnd)..<end.lowerBound])
    }

    private func sessionKey(jid: String, deviceId: UInt32) -> String {
        "\(JIDNormalizer.bare(jid))|\(deviceId)"
    }
}

enum JIDNormalizer {
    static func bare(_ jid: String) -> String {
        String(jid.split(separator: "/").first ?? Substring(jid)).lowercased()
    }
}
