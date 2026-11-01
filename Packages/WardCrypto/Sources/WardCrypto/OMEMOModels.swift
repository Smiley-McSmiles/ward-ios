import Foundation

public struct OMEMOPreKey: Codable, Equatable {
    public var id: UInt32
    public var publicKey: Data
    public var secretKey: Data
    public init(id: UInt32, publicKey: Data, secretKey: Data) {
        self.id = id; self.publicKey = publicKey; self.secretKey = secretKey
    }
}

public struct OMEMOPublicPreKey: Equatable {
    public var id: UInt32
    public var publicKey: Data
    public init(id: UInt32, publicKey: Data) { self.id = id; self.publicKey = publicKey }
}

public struct OMEMOIdentity: Codable, Equatable {
    public var deviceId: UInt32
    public var identity: Ed25519KeyPair
    public var signedPreKeyId: UInt32
    public var signedPreKey: X25519KeyPair
    public var signedPreKeySignature: Data
    public var preKeys: [OMEMOPreKey]
    public var usedPreKeys: [OMEMOPreKey]

    public static func generate(deviceId: UInt32? = nil) throws -> OMEMOIdentity {
        let identity = try CryptoPrimitives.identityKeyPair()
        let signedPreKey = try CryptoPrimitives.x25519KeyPair()
        let signature = try CryptoPrimitives.sign(signedPreKey.publicKey, with: identity)
        let id = deviceId ?? UInt32.random(in: 1...UInt32(Int32.max))
        var keys: [OMEMOPreKey] = []
        for index in 0..<100 {
            let pair = try CryptoPrimitives.x25519KeyPair()
            keys.append(OMEMOPreKey(id: UInt32(index + 1), publicKey: pair.publicKey, secretKey: pair.secretKey))
        }
        return OMEMOIdentity(deviceId: id, identity: identity, signedPreKeyId: 1,
                             signedPreKey: signedPreKey, signedPreKeySignature: signature,
                             preKeys: keys, usedPreKeys: [])
    }

    public mutating func replenishPreKeys() throws {
        var next = (preKeys.map(\.id).max() ?? 0) + 1
        while preKeys.count < 100 {
            let pair = try CryptoPrimitives.x25519KeyPair()
            preKeys.append(OMEMOPreKey(id: next, publicKey: pair.publicKey, secretKey: pair.secretKey))
            next += 1
        }
        if usedPreKeys.count > 40 { usedPreKeys.removeFirst(usedPreKeys.count - 40) }
    }
}

public struct OMEMOBundle: Equatable {
    public var deviceId: UInt32
    public var identityKey: Data
    public var signedPreKeyId: UInt32
    public var signedPreKey: Data
    public var signedPreKeySignature: Data
    public var preKeys: [OMEMOPublicPreKey]

    public init(deviceId: UInt32, identityKey: Data, signedPreKeyId: UInt32,
                signedPreKey: Data, signedPreKeySignature: Data, preKeys: [OMEMOPublicPreKey]) {
        self.deviceId = deviceId
        self.identityKey = identityKey
        self.signedPreKeyId = signedPreKeyId
        self.signedPreKey = signedPreKey
        self.signedPreKeySignature = signedPreKeySignature
        self.preKeys = preKeys
    }
}

struct KexContext: Codable, Equatable {
    var preKeyId: UInt32
    var signedPreKeyId: UInt32
    var identityKey: Data
    var ephemeralKey: Data
}

public struct OMEMOSessionRecord: Codable, Equatable {
    public var jid: String
    public var deviceId: UInt32
    public var ratchet: RatchetState
    public var associatedData: Data
    var pendingKex: KexContext?
    public var confirmed: Bool
    public var fingerprint: String
    public var remoteIdentityKey: Data
    public var remoteKexEphemeral: Data?
}

public struct OMEMOKey: Equatable {
    public var jid: String
    public var deviceId: UInt32
    public var data: String
    public var keyExchange: Bool
}

public struct OMEMOOutgoing {
    public var senderDeviceId: UInt32
    public var keys: [OMEMOKey]
    public var payload: String?
}

public struct OMEMODecrypted {
    public var senderDeviceId: UInt32
    public var senderIdentity: Data
    public var envelopeXML: String?
    public var contentXML: String?
}

public struct OMEMORecipient {
    public var jid: String
    public var bundles: [OMEMOBundle]
    public init(jid: String, bundles: [OMEMOBundle]) {
        self.jid = jid; self.bundles = bundles
    }
}

public struct OMEMOStoreData: Codable {
    public var identity: OMEMOIdentity
    public var sessions: [String: OMEMOSessionRecord]
}
