import Foundation

public struct RatchetHeader: Equatable {
    public var messageNumber: UInt32
    public var previousChainLength: UInt32
    public var dhPublic: Data
    public var ciphertext: Data?

    public init(messageNumber: UInt32, previousChainLength: UInt32, dhPublic: Data, ciphertext: Data? = nil) {
        self.messageNumber = messageNumber
        self.previousChainLength = previousChainLength
        self.dhPublic = dhPublic
        self.ciphertext = ciphertext
    }

    public func encoded(includeCiphertext: Bool = true) -> Data {
        var writer = ProtoWriter()
        writer.varint(1, UInt64(messageNumber), always: true)
        writer.varint(2, UInt64(previousChainLength), always: true)
        writer.bytes(3, dhPublic)
        if includeCiphertext, let ciphertext { writer.bytes(4, ciphertext) }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> RatchetHeader {
        var reader = ProtoReader(data)
        var n: UInt32 = 0
        var pn: UInt32 = 0
        var dh: Data?
        var ciphertext: Data?
        while let field = reader.next() {
            switch field.number {
            case 1: n = UInt32(field.varint ?? 0)
            case 2: pn = UInt32(field.varint ?? 0)
            case 3: dh = field.bytes
            case 4: ciphertext = field.bytes
            default: break
            }
        }
        guard let dh, dh.count == 32 else { throw WardCryptoError.invalidMessage("Invalid OMEMO ratchet header.") }
        return RatchetHeader(messageNumber: n, previousChainLength: pn, dhPublic: dh, ciphertext: ciphertext)
    }
}

public struct AuthenticatedRatchetMessage: Equatable {
    public var mac: Data
    public var message: Data

    public init(mac: Data, message: Data) {
        self.mac = mac
        self.message = message
    }

    public func encoded() -> Data {
        var writer = ProtoWriter()
        writer.bytes(1, mac)
        writer.bytes(2, message)
        return writer.data
    }

    public static func decode(_ data: Data) throws -> AuthenticatedRatchetMessage {
        var reader = ProtoReader(data)
        var mac: Data?
        var message: Data?
        while let field = reader.next() {
            switch field.number {
            case 1: mac = field.bytes
            case 2: message = field.bytes
            default: break
            }
        }
        guard let mac, mac.count == 16, let message else {
            throw WardCryptoError.invalidMessage("Invalid OMEMO authenticated message.")
        }
        return AuthenticatedRatchetMessage(mac: mac, message: message)
    }
}

public struct OMEMOKeyExchange: Equatable {
    public var preKeyId: UInt32
    public var signedPreKeyId: UInt32
    public var identityKey: Data
    public var ephemeralKey: Data
    public var message: AuthenticatedRatchetMessage

    public init(preKeyId: UInt32, signedPreKeyId: UInt32, identityKey: Data,
                ephemeralKey: Data, message: AuthenticatedRatchetMessage) {
        self.preKeyId = preKeyId
        self.signedPreKeyId = signedPreKeyId
        self.identityKey = identityKey
        self.ephemeralKey = ephemeralKey
        self.message = message
    }

    public func encoded() -> Data {
        var writer = ProtoWriter()
        writer.varint(1, UInt64(preKeyId), always: true)
        writer.varint(2, UInt64(signedPreKeyId), always: true)
        writer.bytes(3, identityKey)
        writer.bytes(4, ephemeralKey)
        writer.message(5, message.encoded())
        return writer.data
    }

    public static func decode(_ data: Data) throws -> OMEMOKeyExchange {
        var reader = ProtoReader(data)
        var pkId: UInt32 = 0
        var spkId: UInt32 = 0
        var ik: Data?
        var ek: Data?
        var message: AuthenticatedRatchetMessage?
        while let field = reader.next() {
            switch field.number {
            case 1: pkId = UInt32(field.varint ?? 0)
            case 2: spkId = UInt32(field.varint ?? 0)
            case 3: ik = field.bytes
            case 4: ek = field.bytes
            case 5:
                if let bytes = field.bytes { message = try? AuthenticatedRatchetMessage.decode(bytes) }
            default: break
            }
        }
        guard let ik, ik.count == 32, let ek, ek.count == 32, let message else {
            throw WardCryptoError.invalidMessage("Invalid OMEMO key exchange.")
        }
        return OMEMOKeyExchange(preKeyId: pkId, signedPreKeyId: spkId,
                                identityKey: ik, ephemeralKey: ek, message: message)
    }
}
