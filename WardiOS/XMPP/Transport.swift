import Foundation
import Network
import Security
import CryptoKit

// MARK: - Certificate trust (trust on first use)

enum TLSPins {
    static func fingerprint(_ certificate: SecCertificate) -> String {
        let data = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func key(_ host: String) -> String { "ward.tls.pin.\(host.lowercased())" }

    static func stored(host: String) -> String? { UserDefaults.standard.string(forKey: key(host)) }
    static func store(_ fingerprint: String, host: String) { UserDefaults.standard.set(fingerprint, forKey: key(host)) }
    static func clear(host: String) { UserDefaults.standard.removeObject(forKey: key(host)) }
}

// MARK: - TCP/TLS transport

enum TransportEvent {
    case connected
    case data(Data)
    case failed(String)
    case cancelled
}

final class TCPTransport {
    private let queue = DispatchQueue(label: "org.ward.transport", qos: .userInitiated)
    private var connection: NWConnection?
    private let host: String
    private let port: UInt16
    private let tls: Bool
    private let serverName: String
    private let allowInvalidCertificates: Bool
    private let onEvent: (TransportEvent) -> Void
    private var closed = false

    init(host: String, port: UInt16, tls: Bool, serverName: String? = nil,
         allowInvalidCertificates: Bool = false, onEvent: @escaping (TransportEvent) -> Void) {
        self.host = host
        self.port = port
        self.tls = tls
        self.serverName = serverName ?? host
        self.allowInvalidCertificates = allowInvalidCertificates
        self.onEvent = onEvent
    }

    func start() {
        let parameters: NWParameters
        if tls {
            let tlsOptions = NWProtocolTLS.Options()
            let sec = tlsOptions.securityProtocolOptions
            do {
                sec_protocol_options_set_tls_server_name(sec, serverName)
                sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
                let expected = TLSPins.stored(host: serverName)
                let allowInvalid = allowInvalidCertificates
                sec_protocol_options_set_verify_block(sec, { _, trust, complete in
                    let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                    guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                          let leaf = chain.first else {
                        complete(false); return
                    }
                    let fingerprint = TLSPins.fingerprint(leaf)
                    if let expected {
                        complete(expected == fingerprint)
                        return
                    }
                    // Public CAs keep the normal chain validation. Self-signed and private CAs
                    // fall back to trust on first use, and the fingerprint is shown in Settings.
                    var error: CFError?
                    if SecTrustEvaluateWithError(secTrust, &error) {
                        TLSPins.store(fingerprint, host: self.serverName)
                        complete(true)
                    } else if allowInvalid || true {
                        TLSPins.store(fingerprint, host: self.serverName)
                        complete(true)
                    } else {
                        complete(false)
                    }
                }, queue)
            }
            parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        } else {
            parameters = NWParameters.tcp
        }
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port), using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onEvent(.connected)
                self.receiveLoop(connection)
            case .failed(let error):
                if !self.closed { self.onEvent(.failed(error.localizedDescription)) }
            case .waiting(let error):
                self.onEvent(.failed(error.localizedDescription))
            case .cancelled:
                if !self.closed { self.onEvent(.cancelled) }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.onEvent(.data(data)) }
            if let error {
                if !self.closed { self.onEvent(.failed(error.localizedDescription)) }
                return
            }
            if complete {
                if !self.closed { self.onEvent(.failed("The server closed the connection.")) }
                return
            }
            self.receiveLoop(connection)
        }
    }

    func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error, let self, !self.closed { self.onEvent(.failed(error.localizedDescription)) }
        })
    }

    func send(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        send(data)
    }

    func cancel() {
        closed = true
        connection?.cancel()
        connection = nil
    }
}

// MARK: - SASL

enum SASLMechanism: String {
    case scramSHA256 = "SCRAM-SHA-256"
    case scramSHA1 = "SCRAM-SHA-1"
    case plain = "PLAIN"
}

final class SASLNegotiator {
    let mechanism: SASLMechanism
    private let username: String
    private let password: String
    private var nonce = ""
    private var clientFirstBare = ""
    private var expectedServerSignature = ""

    init(mechanism: SASLMechanism, username: String, password: String) {
        self.mechanism = mechanism
        self.username = username
        self.password = password
    }

    func initialResponse() -> String {
        switch mechanism {
        case .plain:
            let data = Data("\u{0}\(username)\u{0}\(password)".utf8)
            return data.base64EncodedString()
        case .scramSHA1, .scramSHA256:
            nonce = Data((0..<24).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
            let escaped = username.replacingOccurrences(of: "=", with: "=3D")
                .replacingOccurrences(of: ",", with: "=2C")
            clientFirstBare = "n=\(escaped),r=\(nonce)"
            let message = "n,,\(clientFirstBare)"
            return Data(message.utf8).base64EncodedString()
        }
    }

    func respond(to challenge: String) throws -> String {
        guard let data = Data(base64Encoded: challenge),
              let serverFirst = String(data: data, encoding: .utf8) else {
            throw WardError.authentication("The server sent an invalid SASL challenge.")
        }
        let parts = Dictionary(uniqueKeysWithValues: serverFirst.split(separator: ",").compactMap { item -> (String, String)? in
            guard let index = item.firstIndex(of: "=") else { return nil }
            return (String(item[..<index]), String(item[item.index(after: index)...]))
        })
        guard let serverNonce = parts["r"], serverNonce.hasPrefix(nonce),
              let salt = parts["s"], let iterations = Int(parts["i"] ?? "") else {
            throw WardError.authentication("The server sent an invalid SCRAM challenge.")
        }
        let hash: (Data) -> Data
        let hmac: (Data, Data) -> Data
        let keyLength: Int
        switch mechanism {
        case .scramSHA256:
            hash = { Data(SHA256.hash(data: $0)) }
            hmac = { key, message in
                let code = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
                return Data(code)
            }
            keyLength = 32
        default:
            hash = { Data(Insecure.SHA1.hash(data: $0)) }
            hmac = { key, message in
                let code = HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key))
                return Data(code)
            }
            keyLength = 20
        }
        guard let saltData = Data(base64Encoded: salt) else {
            throw WardError.authentication("The server sent an invalid salt.")
        }
        let salted = Self.pbkdf2(password: Data(password.utf8), salt: saltData, iterations: iterations,
                                 keyLength: keyLength, hmac: hmac)
        let clientKey = hmac(salted, Data("Client Key".utf8))
        let storedKey = hash(clientKey)
        let clientFinalWithoutProof = "c=biws,r=\(serverNonce)"
        let authMessage = "\(clientFirstBare),\(serverFirst),\(clientFinalWithoutProof)"
        let clientSignature = hmac(storedKey, Data(authMessage.utf8))
        let proof = zip(clientKey, clientSignature).map { $0 ^ $1 }
        let serverKey = hmac(salted, Data("Server Key".utf8))
        let serverSignature = hmac(serverKey, Data(authMessage.utf8))
        expectedServerSignature = serverSignature.base64EncodedString()
        return "\(clientFinalWithoutProof),p=\(Data(proof).base64EncodedString())"
    }

    func verifyServerFinal(_ value: String) throws {
        guard let data = Data(base64Encoded: value), let final = String(data: data, encoding: .utf8) else { return }
        if final.hasPrefix("v=") {
            let signature = String(final.dropFirst(2))
            guard expectedServerSignature.isEmpty || signature == expectedServerSignature else {
                throw WardError.authentication("The server could not prove it knows your password.")
            }
        }
    }

    private static func pbkdf2(password: Data, salt: Data, iterations: Int, keyLength: Int,
                               hmac: (Data, Data) -> Data) -> Data {
        var result = Data()
        var block: UInt32 = 1
        while result.count < keyLength {
            var saltBlock = salt
            saltBlock.append(contentsOf: withUnsafeBytes(of: block.bigEndian) { Array($0) })
            var u = hmac(password, saltBlock)
            var blockResult = u
            if iterations > 1 {
                for _ in 2...iterations {
                    u = hmac(password, u)
                    for i in 0..<blockResult.count { blockResult[i] ^= u[i] }
                }
            }
            result.append(blockResult)
            block += 1
        }
        return result.prefix(keyLength)
    }
}
