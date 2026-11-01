import XCTest
@testable import WardCrypto

final class OMEMOTests: XCTestCase {
    func testProtobufRoundTrips() throws {
        let header = RatchetHeader(messageNumber: 7, previousChainLength: 3,
                                   dhPublic: Data(repeating: 9, count: 32),
                                   ciphertext: Data(repeating: 4, count: 12))
        let encoded = header.encoded()
        XCTAssertEqual(try RatchetHeader.decode(encoded), header)
        let authenticated = AuthenticatedRatchetMessage(mac: Data(repeating: 1, count: 16),
                                                        message: encoded)
        XCTAssertEqual(try AuthenticatedRatchetMessage.decode(authenticated.encoded()), authenticated)
    }

    func testAESAndHKDF() throws {
        let key = try CryptoPrimitives.randomBytes(32)
        let iv = try CryptoPrimitives.randomBytes(16)
        let plaintext = Data("Ward OMEMO test vector".utf8)
        let ciphertext = try CryptoPrimitives.aesCBCEncrypt(plaintext, key: key, iv: iv)
        XCTAssertNotEqual(ciphertext, plaintext)
        XCTAssertEqual(try CryptoPrimitives.aesCBCDecrypt(ciphertext, key: key, iv: iv), plaintext)
        let derived = CryptoPrimitives.hkdf(ikm: key, salt: Data(repeating: 0, count: 32),
                                            info: "OMEMO X3DH", count: 32)
        XCTAssertEqual(derived.count, 32)
    }

    func testAliceAndBobExchange() throws {
        let alice = try makeEngine("alice")
        let bob = try makeEngine("bob")
        let bobBundle = makeBundle(bob)
        let aliceBundle = makeBundle(alice)

        try alice.buildSessions(jid: "bob@example.org", bundles: [bobBundle])
        let first = try alice.encrypt(contentXML: "<body xmlns='jabber:client'>Hello Bob</body>",
                                      recipients: [OMEMORecipient(jid: "bob@example.org", bundles: [bobBundle])],
                                      fromJID: "alice@example.org")
        XCTAssertEqual(first.keys.count, 1)
        XCTAssertTrue(first.keys[0].keyExchange)
        XCTAssertNotNil(first.payload)
        let firstKey = first.keys[0]
        let decrypted = try XCTUnwrap(bob.decrypt(keyBase64: firstKey.data, keyExchange: true,
                                                  senderJID: "alice@example.org", senderDevice: alice.deviceId,
                                                  payloadBase64: first.payload))
        XCTAssertTrue(decrypted.contentXML?.contains("Hello Bob") == true)
        XCTAssertEqual(decrypted.senderIdentity, alice.identity.identity.publicKey)

        // Bob replies without a new key exchange, and Alice can decrypt it.
        let reply = try bob.encrypt(contentXML: "<body xmlns='jabber:client'>Hello Alice</body>",
                                    recipients: [OMEMORecipient(jid: "alice@example.org", bundles: [aliceBundle])],
                                    fromJID: "bob@example.org")
        XCTAssertFalse(reply.keys[0].keyExchange)
        let replyDecrypted = try XCTUnwrap(alice.decrypt(keyBase64: reply.keys[0].data, keyExchange: false,
                                                         senderJID: "bob@example.org", senderDevice: bob.deviceId,
                                                         payloadBase64: reply.payload))
        XCTAssertTrue(replyDecrypted.contentXML?.contains("Hello Alice") == true)
    }

    func testRepeatedKeyExchangeAndSkippedCounters() throws {
        let alice = try makeEngine("alice2")
        let bob = try makeEngine("bob2")
        let bundle = makeBundle(bob)
        try alice.buildSessions(jid: "bob@example.org", bundles: [bundle])
        let recipient = OMEMORecipient(jid: "bob@example.org", bundles: [bundle])
        let one = try alice.encrypt(contentXML: "<body xmlns='jabber:client'>one</body>",
                                    recipients: [recipient], fromJID: "alice@example.org")
        let two = try alice.encrypt(contentXML: "<body xmlns='jabber:client'>two</body>",
                                    recipients: [recipient], fromJID: "alice@example.org")
        XCTAssertTrue(one.keys[0].keyExchange)
        XCTAssertTrue(two.keys[0].keyExchange)
        let first = try XCTUnwrap(bob.decrypt(keyBase64: one.keys[0].data, keyExchange: true,
                                              senderJID: "alice@example.org", senderDevice: alice.deviceId,
                                              payloadBase64: one.payload))
        XCTAssertTrue(first.contentXML?.contains("one") == true)
        let second = try XCTUnwrap(bob.decrypt(keyBase64: two.keys[0].data, keyExchange: true,
                                               senderJID: "alice@example.org", senderDevice: alice.deviceId,
                                               payloadBase64: two.payload))
        XCTAssertTrue(second.contentXML?.contains("two") == true)
    }

    func testTamperingFails() throws {
        let alice = try makeEngine("alice3")
        let bob = try makeEngine("bob3")
        let bundle = makeBundle(bob)
        try alice.buildSessions(jid: "bob@example.org", bundles: [bundle])
        let outgoing = try alice.encrypt(contentXML: "<body xmlns='jabber:client'>secret</body>",
                                         recipients: [OMEMORecipient(jid: "bob@example.org", bundles: [bundle])],
                                         fromJID: "alice@example.org")
        var bytes = Array(Data(base64Encoded: outgoing.keys[0].data)!)
        bytes[bytes.count / 2] ^= 0x40
        let tampered = Data(bytes).base64EncodedString()
        XCTAssertThrowsError(try bob.decrypt(keyBase64: tampered, keyExchange: true,
                                             senderJID: "alice@example.org", senderDevice: alice.deviceId,
                                             payloadBase64: outgoing.payload))
    }

    func testPreKeyIsConsumed() throws {
        let alice = try makeEngine("alice4")
        let bob = try makeEngine("bob4")
        let bundle = makeBundle(bob)
        let before = bob.identity.preKeys.count
        try alice.buildSessions(jid: "bob@example.org", bundles: [bundle])
        let outgoing = try alice.encrypt(contentXML: "<body xmlns='jabber:client'>hello</body>",
                                         recipients: [OMEMORecipient(jid: "bob@example.org", bundles: [bundle])],
                                         fromJID: "alice@example.org")
        _ = try bob.decrypt(keyBase64: outgoing.keys[0].data, keyExchange: true,
                            senderJID: "alice@example.org", senderDevice: alice.deviceId,
                            payloadBase64: outgoing.payload)
        XCTAssertLessThan(bob.identity.preKeys.count, before + 1)
        XCTAssertFalse(bob.bundleXML().isEmpty)
    }

    func testForgedMessageDoesNotAdvanceRatchet() throws {
        let alice = try makeEngine("alice5")
        let bob = try makeEngine("bob5")
        let bundle = makeBundle(bob)
        try alice.buildSessions(jid: "bob@example.org", bundles: [bundle])
        let recipient = OMEMORecipient(jid: "bob@example.org", bundles: [bundle])
        let first = try alice.encrypt(contentXML: "<body xmlns='jabber:client'>first</body>",
                                      recipients: [recipient], fromJID: "alice@example.org")
        let second = try alice.encrypt(contentXML: "<body xmlns='jabber:client'>second</body>",
                                       recipients: [recipient], fromJID: "alice@example.org")
        var forged = Array(Data(base64Encoded: first.keys[0].data)!)
        forged[forged.count - 1] ^= 0x01
        XCTAssertThrowsError(try bob.decrypt(keyBase64: Data(forged).base64EncodedString(), keyExchange: true,
                                             senderJID: "alice@example.org", senderDevice: alice.deviceId,
                                             payloadBase64: first.payload))
        // The genuine first message must still decrypt: the forged one must not have consumed its key.
        let genuine = try XCTUnwrap(bob.decrypt(keyBase64: first.keys[0].data, keyExchange: true,
                                                senderJID: "alice@example.org", senderDevice: alice.deviceId,
                                                payloadBase64: first.payload))
        XCTAssertTrue(genuine.contentXML?.contains("first") == true)
        let next = try XCTUnwrap(bob.decrypt(keyBase64: second.keys[0].data, keyExchange: true,
                                             senderJID: "alice@example.org", senderDevice: alice.deviceId,
                                             payloadBase64: second.payload))
        XCTAssertTrue(next.contentXML?.contains("second") == true)
    }

    func testIdentityChangeIsRejected() throws {
        let alice = try makeEngine("alice6")
        let bob = try makeEngine("bob6")
        let mallory = try makeEngine("mallory6")
        let bobBundle = makeBundle(bob)
        try alice.buildSessions(jid: "bob@example.org", bundles: [bobBundle])
        let first = try alice.encrypt(contentXML: "<body xmlns='jabber:client'>hi</body>",
                                      recipients: [OMEMORecipient(jid: "bob@example.org", bundles: [bobBundle])],
                                      fromJID: "alice@example.org")
        _ = try bob.decrypt(keyBase64: first.keys[0].data, keyExchange: true,
                            senderJID: "alice@example.org", senderDevice: alice.deviceId,
                            payloadBase64: first.payload)
        try mallory.buildSessions(jid: "bob@example.org", bundles: [bobBundle])
        let impostor = try mallory.encrypt(contentXML: "<body xmlns='jabber:client'>evil</body>",
                                           recipients: [OMEMORecipient(jid: "bob@example.org", bundles: [bobBundle])],
                                           fromJID: "alice@example.org")
        XCTAssertThrowsError(try bob.decrypt(keyBase64: impostor.keys[0].data, keyExchange: true,
                                             senderJID: "alice@example.org", senderDevice: alice.deviceId,
                                             payloadBase64: impostor.payload)) { error in
            guard case WardCryptoError.authentication = error else {
                return XCTFail("Expected an identity change rejection, got \(error)")
            }
        }
    }

    func testPreKeyIdsAreNeverReused() throws {
        var identity = try OMEMOIdentity.generate(deviceId: 42)
        let highest = try XCTUnwrap(identity.preKeys.map(\.id).max())
        let index = try XCTUnwrap(identity.preKeys.firstIndex { $0.id == highest })
        let consumed = identity.preKeys.remove(at: index)
        identity.usedPreKeys.append(consumed)
        try identity.replenishPreKeys()
        let allIds = identity.preKeys.map(\.id) + identity.usedPreKeys.map(\.id)
        XCTAssertEqual(Set(allIds).count, allIds.count)
        XCTAssertEqual(identity.preKeys.filter { $0.id > highest }.count, 1)
    }

    func testForgettingASessionAllowsAReinstalledIdentity() throws {
        let alice = try makeEngine("alice7")
        let bob = try makeEngine("bob7")
        let mallory = try makeEngine("mallory7")
        let bobBundle = makeBundle(bob)
        try alice.buildSessions(jid: "bob@example.org", bundles: [bobBundle])
        let first = try alice.encrypt(contentXML: "<body xmlns='jabber:client'>hi</body>",
                                      recipients: [OMEMORecipient(jid: "bob@example.org", bundles: [bobBundle])],
                                      fromJID: "alice@example.org")
        _ = try bob.decrypt(keyBase64: first.keys[0].data, keyExchange: true,
                            senderJID: "alice@example.org", senderDevice: alice.deviceId,
                            payloadBase64: first.payload)
        bob.forgetSession(jid: "alice@example.org", deviceId: alice.deviceId)
        try mallory.buildSessions(jid: "bob@example.org", bundles: [bobBundle])
        let replacement = try mallory.encrypt(contentXML: "<body xmlns='jabber:client'>new phone</body>",
                                              recipients: [OMEMORecipient(jid: "bob@example.org", bundles: [bobBundle])],
                                              fromJID: "alice@example.org")
        let decrypted = try XCTUnwrap(bob.decrypt(keyBase64: replacement.keys[0].data, keyExchange: true,
                                                  senderJID: "alice@example.org", senderDevice: alice.deviceId,
                                                  payloadBase64: replacement.payload))
        XCTAssertTrue(decrypted.contentXML?.contains("new phone") == true)
    }

    func testSCEEnvelopeKeepsContent() throws {
        let content = "<body xmlns='jabber:client'>a &amp; b</body><reply xmlns='urn:xmpp:reply:0' id='x'/>"
        let envelope = try SCE.envelope(contentXML: content, from: "alice@example.org")
        XCTAssertTrue(envelope.contains("<rpad>"))
        XCTAssertTrue(envelope.contains("<from jid='alice@example.org'/>"))
        let engine = try makeEngine("sce8")
        XCTAssertEqual(try XCTUnwrap(engine.extractContentForTesting(envelope)), content)
    }

    func testConfirmationStopsRepeatedKeyExchange() throws {
        let alice = try makeEngine("alice9")
        let bob = try makeEngine("bob9")
        let bundle = makeBundle(bob)
        let recipient = OMEMORecipient(jid: "bob@example.org", bundles: [bundle])
        try alice.buildSessions(jid: "bob@example.org", bundles: [bundle])
        let first = try alice.encrypt(contentXML: "<body xmlns='jabber:client'>one</body>",
                                      recipients: [recipient], fromJID: "alice@example.org")
        _ = try bob.decrypt(keyBase64: first.keys[0].data, keyExchange: true,
                            senderJID: "alice@example.org", senderDevice: alice.deviceId,
                            payloadBase64: first.payload)
        let confirmation = try XCTUnwrap(bob.confirmation(senderJID: "alice@example.org",
                                                          deviceId: alice.deviceId))
        XCTAssertFalse(confirmation.keyExchange)
        _ = try alice.decrypt(keyBase64: confirmation.data, keyExchange: false,
                              senderJID: "bob@example.org", senderDevice: bob.deviceId,
                              payloadBase64: nil)
        let second = try alice.encrypt(contentXML: "<body xmlns='jabber:client'>two</body>",
                                       recipients: [recipient], fromJID: "alice@example.org")
        XCTAssertFalse(second.keys[0].keyExchange)
    }

    private func makeEngine(_ name: String) throws -> OMEMOEngine {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ward-omemo-test-\(name)-\(UUID().uuidString).json")
        return try OMEMOEngine(storeURL: url)
    }

    private func makeBundle(_ engine: OMEMOEngine) -> OMEMOBundle {
        let identity = engine.identity
        return OMEMOBundle(deviceId: identity.deviceId,
                           identityKey: identity.identity.publicKey,
                           signedPreKeyId: identity.signedPreKeyId,
                           signedPreKey: identity.signedPreKey.publicKey,
                           signedPreKeySignature: identity.signedPreKeySignature,
                           preKeys: identity.preKeys.map { OMEMOPublicPreKey(id: $0.id, publicKey: $0.publicKey) })
    }
}
