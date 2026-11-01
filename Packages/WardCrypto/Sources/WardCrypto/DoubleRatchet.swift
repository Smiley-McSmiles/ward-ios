import Foundation

public struct SkippedMessageKey: Codable, Equatable {
    public var dhPublic: Data
    public var messageNumber: UInt32
    public var messageKey: Data
}

public struct RatchetState: Codable, Equatable {
    public var rootKey: Data
    public var selfPublic: Data
    public var selfSecret: Data
    public var remotePublic: Data?
    public var sendingChain: Data?
    public var receivingChain: Data?
    public var sendCount: UInt32
    public var receiveCount: UInt32
    public var previousSendCount: UInt32
    public var skipped: [SkippedMessageKey]

    /// Alice initiates X3DH and immediately derives a sending chain against Bob's signed prekey.
    public static func initiator(sharedSecret: Data, remoteSignedPreKey: Data) throws -> RatchetState {
        let selfPair = try CryptoPrimitives.x25519KeyPair()
        var state = RatchetState(rootKey: sharedSecret,
                                 selfPublic: selfPair.publicKey, selfSecret: selfPair.secretKey,
                                 remotePublic: remoteSignedPreKey,
                                 sendingChain: nil, receivingChain: nil,
                                 sendCount: 0, receiveCount: 0, previousSendCount: 0,
                                 skipped: [])
        let dh = try CryptoPrimitives.dh(secretKey: selfPair.secretKey, publicKey: remoteSignedPreKey)
        let (root, chain) = KDF.root(state.rootKey, dh)
        state.rootKey = root
        state.sendingChain = chain
        return state
    }

    /// Bob starts with his signed prekey as the local ratchet key and no remote key yet.
    public static func responder(sharedSecret: Data, signedPreKey: X25519KeyPair) throws -> RatchetState {
        RatchetState(rootKey: sharedSecret,
                     selfPublic: signedPreKey.publicKey, selfSecret: signedPreKey.secretKey,
                     remotePublic: nil, sendingChain: nil, receivingChain: nil,
                     sendCount: 0, receiveCount: 0, previousSendCount: 0,
                     skipped: [])
    }

    public mutating func encrypt(_ plaintext: Data, associatedData: Data) throws -> AuthenticatedRatchetMessage {
        guard let chain = sendingChain else { throw WardCryptoError.noSession }
        let (messageKey, nextChain) = KDF.chain(chain)
        sendingChain = nextChain
        let header = RatchetHeader(messageNumber: sendCount, previousChainLength: previousSendCount,
                                   dhPublic: selfPublic, ciphertext: nil)
        sendCount += 1
        let material = CryptoPrimitives.hkdf(ikm: messageKey, salt: Data(repeating: 0, count: 32),
                                             info: "OMEMO Message Key Material", count: 80)
        let encryptionKey = material.prefix(32)
        let authenticationKey = material.dropFirst(32).prefix(32)
        let iv = material.suffix(16)
        let ciphertext = try CryptoPrimitives.aesCBCEncrypt(plaintext, key: Data(encryptionKey), iv: Data(iv))
        var fullHeader = header
        fullHeader.ciphertext = ciphertext
        let serialized = fullHeader.encoded()
        let mac = CryptoPrimitives.hmac(key: Data(authenticationKey),
                                        message: associatedData + serialized).prefix(16)
        return AuthenticatedRatchetMessage(mac: Data(mac), message: serialized)
    }

    public mutating func decrypt(_ authenticated: AuthenticatedRatchetMessage,
                                 associatedData: Data) throws -> Data {
        // Work on a copy and only commit the advanced ratchet state after authentication succeeds.
        // Otherwise a forged or corrupted stanza could consume message keys and desynchronise the session.
        var working = self
        let plaintext = try working.decryptAdvancing(authenticated, associatedData: associatedData)
        self = working
        return plaintext
    }

    private mutating func decryptAdvancing(_ authenticated: AuthenticatedRatchetMessage,
                                           associatedData: Data) throws -> Data {
        let header = try RatchetHeader.decode(authenticated.message)
        guard header.ciphertext != nil else {
            throw WardCryptoError.invalidMessage("The OMEMO ratchet message has no ciphertext.")
        }

        // Check cached keys first, regardless of the current chain, so messages that arrive out of
        // order across a DH ratchet step still decrypt.
        if let index = skipped.firstIndex(where: {
            $0.dhPublic == header.dhPublic && $0.messageNumber == header.messageNumber
        }) {
            let skippedKey = skipped.remove(at: index)
            return try decryptWithKey(authenticated, header: header, messageKey: skippedKey.messageKey,
                                      associatedData: associatedData)
        }

        if remotePublic == header.dhPublic {
            guard header.messageNumber >= receiveCount else {
                throw WardCryptoError.authentication("This OMEMO message was already used or is too old.")
            }
        } else {
            if let remotePublic {
                try skipReceivingKeys(until: header.previousChainLength, dhPublic: remotePublic)
            }
            try performDHRatchet(remotePublic: header.dhPublic)
        }
        try skipReceivingKeys(until: header.messageNumber, dhPublic: header.dhPublic)

        guard let chain = receivingChain else { throw WardCryptoError.noSession }
        let (messageKey, nextChain) = KDF.chain(chain)
        receivingChain = nextChain
        let plaintext = try decryptWithKey(authenticated, header: header, messageKey: messageKey,
                                           associatedData: associatedData)
        receiveCount += 1
        return plaintext
    }

    private mutating func decryptWithKey(_ authenticated: AuthenticatedRatchetMessage, header: RatchetHeader,
                                         messageKey: Data, associatedData: Data) throws -> Data {
        guard let ciphertext = header.ciphertext else { throw WardCryptoError.invalidMessage("Missing ciphertext.") }
        let material = CryptoPrimitives.hkdf(ikm: messageKey, salt: Data(repeating: 0, count: 32),
                                             info: "OMEMO Message Key Material", count: 80)
        let encryptionKey = material.prefix(32)
        let authenticationKey = material.dropFirst(32).prefix(32)
        let iv = material.suffix(16)
        let expected = CryptoPrimitives.hmac(key: Data(authenticationKey),
                                             message: associatedData + authenticated.message).prefix(16)
        guard constantTimeEqual(Data(expected), authenticated.mac) else {
            throw WardCryptoError.authentication("The OMEMO message authentication tag is invalid.")
        }
        return try CryptoPrimitives.aesCBCDecrypt(ciphertext, key: Data(encryptionKey), iv: Data(iv))
    }

    private mutating func skipReceivingKeys(until number: UInt32, dhPublic: Data) throws {
        guard number >= receiveCount else { return }
        guard number - receiveCount <= 1000 else { throw WardCryptoError.invalidMessage("Too many skipped OMEMO messages.") }
        while receiveCount < number {
            guard let chain = receivingChain else { throw WardCryptoError.noSession }
            let (messageKey, nextChain) = KDF.chain(chain)
            receivingChain = nextChain
            skipped.append(SkippedMessageKey(dhPublic: dhPublic, messageNumber: receiveCount, messageKey: messageKey))
            receiveCount += 1
        }
        if skipped.count > 1000 { skipped.removeFirst(skipped.count - 1000) }
    }

    private mutating func performDHRatchet(remotePublic newRemote: Data) throws {
        previousSendCount = sendCount
        sendCount = 0
        receiveCount = 0
        remotePublic = newRemote
        let receivingDH = try CryptoPrimitives.dh(secretKey: selfSecret, publicKey: newRemote)
        let (rootAfterReceive, receiving) = KDF.root(rootKey, receivingDH)
        rootKey = rootAfterReceive
        receivingChain = receiving
        let newSelf = try CryptoPrimitives.x25519KeyPair()
        let sendingDH = try CryptoPrimitives.dh(secretKey: newSelf.secretKey, publicKey: newRemote)
        let (rootAfterSend, sending) = KDF.root(rootKey, sendingDH)
        rootKey = rootAfterSend
        selfPublic = newSelf.publicKey
        selfSecret = newSelf.secretKey
        sendingChain = sending
    }
}

enum KDF {
    static func root(_ rootKey: Data, _ dhOutput: Data) -> (root: Data, chain: Data) {
        let material = CryptoPrimitives.hkdf(ikm: dhOutput, salt: rootKey,
                                             info: "OMEMO Root Chain", count: 64)
        return (material.prefix(32), material.suffix(32))
    }

    static func chain(_ chainKey: Data) -> (message: Data, next: Data) {
        let message = CryptoPrimitives.hmac(key: chainKey, message: Data([0x01]))
        let next = CryptoPrimitives.hmac(key: chainKey, message: Data([0x02]))
        return (message, next)
    }
}
