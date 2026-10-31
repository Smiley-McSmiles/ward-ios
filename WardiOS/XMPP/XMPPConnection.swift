import Foundation

// MARK: - Configuration

struct XMPPRegistrationRequest {
    var username: String
    var password: String
}

struct XMPPConfiguration {
    var jid: String
    var password: String
    var host: String
    var port: UInt16?
    var tlsMode: String = "auto" // auto | required | direct | none
    var resource: String = "Ward"
    var allowPlain: Bool = true
    var allowInvalidCertificates: Bool = true
    var keepalive: TimeInterval = 60
    var registration: XMPPRegistrationRequest? = nil

    var domain: String { JID.domain(jid) }
    var localpart: String { JID.local(jid) }
    var directTLS: Bool { tlsMode == "direct" }
    var useTLS: Bool { tlsMode != "none" }
}

// MARK: - Connection

final class XMPPConnection {
    enum Phase: String {
        case idle, connecting, stream, startTLS, authenticating, binding, ready, closed
    }

    let config: XMPPConfiguration
    private(set) var phase: Phase = .idle
    private(set) var boundJID: String = ""
    private(set) var isSecure = false
    private(set) var streamID: String = ""

    var onState: ((ConnectionState) -> Void)?
    var onStanza: ((XMLNode) -> Void)?
    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?
    var onRawIn: ((String) -> Void)?
    var onRawOut: ((String) -> Void)?
    var onRegistered: ((Result<Void, Error>) -> Void)?

    private var transport: TCPTransport?
    private var splitter = XMLStreamSplitter()
    private var sasl: SASLNegotiator?
    private var authenticated = false
    private var streamOpened = false
    private var restartingForTLS = false
    private var sessionRequired = false
    private var streamManagementOffered = false
    private var smEnabled = false
    private var smID: String?
    private var outboundH: UInt32 = 0
    private var inboundH: UInt32 = 0
    private var keepaliveTimer: Timer?
    private var lastReceived = Date()
    private var readyFired = false
    private var closedByUser = false
    private var registrationSent = false
    private var currentStep = "Connecting…"

    init(configuration: XMPPConfiguration) {
        self.config = configuration
    }

    // MARK: Lifecycle

    func connect() {
        guard phase == .idle || phase == .closed else { return }
        closedByUser = false
        readyFired = false
        authenticated = false
        streamOpened = false
        phase = .connecting
        isSecure = false
        currentStep = "Connecting…"
        emitState()
        openTransport(tls: config.directTLS)
    }

    func disconnect() {
        closedByUser = true
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        if phase == .ready { sendRaw("</stream:stream>") }
        transport?.cancel()
        transport = nil
        phase = .closed
        emitState(error: "")
    }

    private func openTransport(tls: Bool) {
        let port = config.port ?? (tls && config.directTLS ? 5223 : 5222)
        isSecure = tls
        splitter = XMLStreamSplitter()
        streamOpened = false
        let transport = TCPTransport(host: config.host, port: port, tls: tls,
                                     serverName: config.domain,
                                     allowInvalidCertificates: config.allowInvalidCertificates) { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        self.transport = transport
        transport.start()
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .connected:
            if restartingForTLS {
                restartingForTLS = false
                isSecure = true
            }
            sendStreamHeader()
        case .data(let data):
            lastReceived = Date()
            let string = String(decoding: data, as: UTF8.self)
            onRawIn?(string)
            for element in splitter.feed(string) {
                if element.hasPrefix("<stream:stream") {
                    handleStreamOpen(element)
                } else if element.hasPrefix("</stream:stream") {
                    fail("The server closed the stream.")
                } else if let node = XML.parse(element) {
                    handle(node)
                }
            }
        case .failed(let message):
            if !closedByUser { fail(message) }
        case .cancelled:
            if !closedByUser && !restartingForTLS { fail("The connection was closed.") }
        }
    }

    private func fail(_ message: String) {
        guard phase != .closed else { return }
        phase = .closed
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        transport?.cancel()
        transport = nil
        emitState(error: message)
        onError?(message)
    }

    private func emitState(error: String = "") {
        let state: String
        switch phase {
        case .ready: state = "online"
        case .idle, .closed: state = error.isEmpty ? "offline" : "error"
        default: state = "connecting"
        }
        onState?(ConnectionState(state: state, step: currentStep, error: error,
                                 since: state == "online" ? Date() : nil))
    }

    // MARK: Stream

    private func sendStreamHeader() {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let header = "<?xml version='1.0'?><stream:stream to='\(XML.escape(config.domain))' version='1.0' xml:lang='\(language)' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>"
        sendRaw(header)
        phase = .stream
        currentStep = "Opening stream…"
        emitState()
    }

    private func handleStreamOpen(_ element: String) {
        if let node = XML.parse(element) {
            streamID = node.attr("id", "")
        }
        currentStep = "Securing connection…"
        emitState()
    }

    private func handle(_ node: XMLNode) {
        if node.name == "error" && node.uri == "http://etherx.jabber.org/streams" {
            let text = node.child("text")?.trimmedText ?? "The server rejected the connection."
            fail(text)
            return
        }
        switch node.name {
        case "features":
            handleFeatures(node)
        case "proceed":
            upgradeTLS()
        case "failure" where node.uri == "urn:ietf:params:xml:ns:xmpp-sasl":
            let reason = node.children.first?.name ?? "Authentication failed"
            fail(friendlySASL(reason))
        case "challenge":
            guard let sasl, let value = node.trimmedText.isEmpty ? nil : node.trimmedText else {
                fail("The server sent an empty authentication challenge."); return
            }
            do {
                let response = try sasl.respond(to: value)
                sendRaw("<response xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\(response)</response>")
            } catch { fail(error.localizedDescription) }
        case "success":
            let value = node.trimmedText
            if !value.isEmpty { try? sasl?.verifyServerFinal(value) }
            authenticated = true
            phase = .stream
            currentStep = "Signing in…"
            emitState()
            restartStream()
        case "enabled":
            smEnabled = true
            smID = node.attr("id")
            finishReady()
        case "resumed":
            smEnabled = true
            if let h = node.attr("h").flatMap(UInt32.init) { inboundH = h }
            finishReady()
        case "failed" where node.uri == "urn:xmpp:sm:3":
            smEnabled = false
            finishReady()
        case "r" where node.uri == "urn:xmpp:sm:3":
            sendRaw("<a xmlns='urn:xmpp:sm:3' h='\(inboundH)'/>")
        case "a" where node.uri == "urn:xmpp:sm:3":
            if let h = node.attr("h").flatMap(UInt32.init) { outboundH = h }
        case "iq":
            handleIQ(node)
        case "message", "presence":
            inboundH &+= 1
            if phase == .ready { onStanza?(node) }
        default:
            break
        }
    }

    private func handleFeatures(_ node: XMLNode) {
        let startTLS = node.child("starttls", xmlns: "urn:ietf:params:xml:ns:xmpp-tls")
        let mechanisms = node.children("mechanism").compactMap { $0.trimmedText }
        let bind = node.child("bind", xmlns: "urn:ietf:params:xml:ns:xmpp-bind")
        let session = node.child("session", xmlns: "urn:ietf:params:xml:ns:xmpp-session")
        if node.child("sm", xmlns: "urn:xmpp:sm:3") != nil { streamManagementOffered = true }

        if startTLS != nil && !isSecure && config.useTLS {
            if startTLS?.child("required") != nil || config.tlsMode == "required" || config.tlsMode == "auto" {
                currentStep = "Starting TLS…"
                emitState()
                phase = .startTLS
                sendRaw("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
                return
            }
        }
        if config.tlsMode != "none" && !isSecure {
            fail("This server does not offer STARTTLS. Ward will not send your password over an unencrypted connection.")
            return
        }
        if let registration = config.registration, !registrationSent, !authenticated {
            let registerFeature = node.child("register", xmlns: "http://jabber.org/features/iq-register")
                ?? node.child("register", xmlns: "jabber:iq:register")
            guard registerFeature != nil else {
                fail("This server does not support in-band account creation. Create the account on the server's website and sign in.")
                return
            }
            registrationSent = true
            currentStep = "Creating account…"
            phase = .authenticating
            emitState()
            let xml = "<iq type='set' id='ward-register'><query xmlns='jabber:iq:register'><username>\(XML.escape(registration.username))</username><password>\(XML.escape(registration.password))</password></query></iq>"
            sendRaw(xml)
            return
        }
        if !mechanisms.isEmpty && !authenticated {
            currentStep = "Signing in…"
            emitState()
            beginSASL(mechanisms)
            return
        }
        if bind != nil && authenticated {
            sessionRequired = session != nil
            currentStep = "Binding session…"
            emitState()
            phase = .binding
            sendRaw("<iq type='set' id='ward-bind'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><resource>\(XML.escape(config.resource))</resource></bind></iq>")
            return
        }
        if authenticated {
            finishReady()
        }
    }

    private func beginSASL(_ mechanisms: [String]) {
        let supported = mechanisms.compactMap { SASLMechanism(rawValue: $0) }
        let chosen: SASLMechanism?
        if supported.contains(.scramSHA256) { chosen = .scramSHA256 }
        else if supported.contains(.scramSHA1) { chosen = .scramSHA1 }
        else if supported.contains(.plain), config.allowPlain && isSecure { chosen = .plain }
        else { chosen = nil }
        guard let chosen else {
            fail("The server does not offer a supported secure login method.")
            return
        }
        let negotiator = SASLNegotiator(mechanism: chosen, username: config.localpart, password: config.password)
        sasl = negotiator
        phase = .authenticating
        let response = negotiator.initialResponse()
        sendRaw("<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='\(chosen.rawValue)'>\(response)</auth>")
    }

    private func upgradeTLS() {
        restartingForTLS = true
        transport?.cancel()
        transport = nil
        openTransport(tls: true)
    }

    private func restartStream() {
        splitter = XMLStreamSplitter()
        streamOpened = false
        sendStreamHeader()
    }

    private func handleIQ(_ node: XMLNode) {
        let id = node.attr("id", "")
        if id == "ward-register" {
            if node.attr("type") == "result" {
                onRegistered?(.success(()))
                closedByUser = true
                transport?.cancel()
                transport = nil
                phase = .closed
            } else {
                let condition = node.child("error")?.children.first?.name ?? "registration-failed"
                let text = node.child("error")?.child("text")?.trimmedText
                let message = text?.isEmpty == false ? text! : "The server refused to create the account (\(condition.replacingOccurrences(of: "-", with: " ")))."
                onRegistered?(.failure(WardError.authentication(message)))
                fail(message)
            }
            return
        }
        if id == "ward-bind", let bind = node.child("bind") {
            if let jid = bind.child("jid")?.trimmedText, !jid.isEmpty { boundJID = jid }
            if sessionRequired {
                sendRaw("<iq type='set' id='ward-session'><session xmlns='urn:ietf:params:xml:ns:xmpp-session'/></iq>")
            } else {
                finishReady()
            }
            return
        }
        if id == "ward-session" {
            finishReady()
            return
        }
        inboundH &+= 1
        if phase == .ready { onStanza?(node) }
    }

    private func finishReady() {
        guard phase != .ready else { return }
        phase = .ready
        currentStep = "Online"
        if streamManagementOffered && !smEnabled {
            sendRaw("<enable xmlns='urn:xmpp:sm:3' resume='true'/>")
        }
        startKeepalive()
        emitState()
        if !readyFired {
            readyFired = true
            onReady?()
        }
    }

    private func friendlySASL(_ reason: String) -> String {
        switch reason {
        case "not-authorized": return "The server did not accept that address and password."
        case "account-disabled": return "This account has been disabled by the server."
        case "credentials-expired": return "Your credentials have expired. Sign in again."
        case "temporary-auth-failure": return "The server could not check your password right now."
        default: return "Sign-in failed: \(reason.replacingOccurrences(of: "-", with: " "))."
        }
    }

    // MARK: Keepalive & send

    private func startKeepalive() {
        keepaliveTimer?.invalidate()
        let interval = max(30, config.keepalive)
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, self.phase == .ready else { return }
            if Date().timeIntervalSince(self.lastReceived) > interval * 2.5 {
                self.fail("The connection stopped responding.")
                return
            }
            self.sendRaw("<iq type='get' id='ward-ping-\(Int(Date().timeIntervalSince1970))' to='\(XML.escape(self.config.domain))'><ping xmlns='urn:xmpp:ping'/></iq>")
        }
    }

    @discardableResult
    func send(_ stanza: String) -> Bool {
        guard phase == .ready else { return false }
        if stanza.hasPrefix("<message") || stanza.hasPrefix("<presence") || stanza.hasPrefix("<iq") {
            outboundH &+= 1
        }
        sendRaw(stanza)
        return true
    }

    func sendRaw(_ xml: String) {
        onRawOut?(xml)
        transport?.send(xml)
    }

    var isConnected: Bool { phase == .ready }
    var resource: String { JID.resource(boundJID) ?? config.resource }
    var counters: (outbound: UInt32, inbound: UInt32) { (outboundH, inboundH) }
}
