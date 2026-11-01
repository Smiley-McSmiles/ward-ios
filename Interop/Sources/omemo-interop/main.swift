import Foundation
import WardCrypto

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func readJSON(_ path: String) -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: path),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        die("cannot read \(path)")
    }
    return object
}

func writeJSON(_ object: [String: Any], to path: String) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: path))
}

func data(_ value: Any?, _ name: String) -> Data {
    guard let string = value as? String, let decoded = Data(base64Encoded: string) else {
        die("missing or invalid base64 field \(name)")
    }
    return decoded
}

func u32(_ value: Any?, _ name: String) -> UInt32 {
    guard let number = value as? NSNumber else { die("missing field \(name)") }
    return number.uint32Value
}

func bundle(from object: [String: Any]) -> OMEMOBundle {
    let keys = (object["preKeys"] as? [[String: Any]] ?? []).map {
        OMEMOPublicPreKey(id: u32($0["id"], "preKeys.id"), publicKey: data($0["publicKey"], "preKeys.publicKey"))
    }
    return OMEMOBundle(deviceId: u32(object["deviceId"], "deviceId"),
                       identityKey: data(object["identityKey"], "identityKey"),
                       signedPreKeyId: u32(object["signedPreKeyId"], "signedPreKeyId"),
                       signedPreKey: data(object["signedPreKey"], "signedPreKey"),
                       signedPreKeySignature: data(object["signedPreKeySignature"], "signedPreKeySignature"),
                       preKeys: keys)
}

func exportBundle(_ engine: OMEMOEngine) -> [String: Any] {
    let identity = engine.identity
    return [
        "deviceId": identity.deviceId,
        "identityKey": identity.identity.publicKey.base64EncodedString(),
        "signedPreKeyId": identity.signedPreKeyId,
        "signedPreKey": identity.signedPreKey.publicKey.base64EncodedString(),
        "signedPreKeySignature": identity.signedPreKeySignature.base64EncodedString(),
        "preKeys": identity.preKeys.map { ["id": $0.id, "publicKey": $0.publicKey.base64EncodedString()] }
    ]
}

let args = CommandLine.arguments
guard args.count >= 4 else { die("usage: <export|encrypt|decrypt> <store> ...") }
let command = args[1]
let store = URL(fileURLWithPath: args[2])

switch command {
case "export":
    let engine = try OMEMOEngine(storeURL: store)
    writeJSON(exportBundle(engine), to: args[3])
case "encrypt":
    let engine = try OMEMOEngine(storeURL: store)
    let remote = bundle(from: readJSON(args[3]))
    let text = args[4]
    let jid = args.count > 6 ? args[6] : "twomemo@example.org"
    let fromJID = args.count > 7 ? args[7] : "swift@example.org"
    if !engine.hasSession(jid: jid, deviceId: remote.deviceId) {
        try engine.buildSessions(jid: jid, bundles: [remote])
    }
    let content = "<body xmlns='jabber:client'>\(text)</body>"
    let outgoing = try engine.encrypt(contentXML: content,
                                      recipients: [OMEMORecipient(jid: jid, bundles: [remote])],
                                      fromJID: fromJID)
    writeJSON([
        "senderDevice": outgoing.senderDeviceId,
        "payload": outgoing.payload ?? "",
        "keys": outgoing.keys.map { ["deviceId": $0.deviceId, "data": $0.data, "kex": $0.keyExchange] }
    ], to: args[5])
case "decrypt":
    let engine = try OMEMOEngine(storeURL: store)
    let incoming = readJSON(args[3])
    let key = (incoming["keys"] as? [[String: Any]])?.first
    guard let key else { die("no key in incoming message") }
    let decrypted = try engine.decrypt(keyBase64: key["data"] as! String,
                                       keyExchange: key["kex"] as! Bool,
                                       senderJID: incoming["senderJID"] as! String,
                                       senderDevice: u32(incoming["senderDevice"], "senderDevice"),
                                       payloadBase64: incoming["payload"] as? String)
    guard let decrypted else { die("no plaintext") }
    let text = decrypted.contentXML ?? decrypted.envelopeXML ?? ""
    try! Data(text.utf8).write(to: URL(fileURLWithPath: args[4]))
default:
    die("unknown command \(command)")
}
