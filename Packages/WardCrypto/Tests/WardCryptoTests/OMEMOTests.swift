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
