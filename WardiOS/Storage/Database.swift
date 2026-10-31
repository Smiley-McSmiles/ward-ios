import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Small, self-contained SQLite store. Entities are persisted as JSON in a `json` column while
/// the fields the UI sorts, joins and searches on are mirrored into real columns. This keeps the
/// schema readable and makes migrations cheap without sacrificing indexed lookups or full-text search.
actor WardDatabase {
    private var db: OpaquePointer?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(url: URL) throws {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, db != nil else {
            throw WardError.database("Could not open the Ward database.")
        }
        try Self.exec(db, "PRAGMA journal_mode=WAL;")
        try Self.exec(db, "PRAGMA synchronous=NORMAL;")
        try Self.exec(db, "PRAGMA foreign_keys=ON;")
        try createSchema()
    }

    deinit { sqlite3_close(db) }

    private func createSchema() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS accounts (
            id INTEGER PRIMARY KEY,
            json TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS contacts (
            accountId INTEGER NOT NULL,
            jid TEXT NOT NULL,
            json TEXT NOT NULL,
            PRIMARY KEY (accountId, jid)
        );
        CREATE TABLE IF NOT EXISTS chats (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            accountId INTEGER NOT NULL,
            jid TEXT NOT NULL,
            json TEXT NOT NULL,
            UNIQUE (accountId, jid)
        );
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            chatId INTEGER NOT NULL,
            stanzaId TEXT NOT NULL DEFAULT '',
            originId TEXT NOT NULL DEFAULT '',
            timestamp INTEGER NOT NULL,
            body TEXT NOT NULL DEFAULT '',
            json TEXT NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS messages_stanza ON messages (chatId, stanzaId) WHERE stanzaId != '';
        CREATE INDEX IF NOT EXISTS messages_chat_time ON messages (chatId, timestamp);
        CREATE INDEX IF NOT EXISTS messages_time ON messages (timestamp);
        CREATE TABLE IF NOT EXISTS devices (
            accountId INTEGER NOT NULL,
            jid TEXT NOT NULL,
            deviceId INTEGER NOT NULL,
            protocolName TEXT NOT NULL,
            json TEXT NOT NULL,
            PRIMARY KEY (accountId, jid, deviceId, protocolName)
        );
        CREATE TABLE IF NOT EXISTS receipts (
            messageId INTEGER NOT NULL,
            recipient TEXT NOT NULL,
            json TEXT NOT NULL,
            PRIMARY KEY (messageId, recipient)
        );
        CREATE TABLE IF NOT EXISTS requests (
            accountId INTEGER NOT NULL,
            jid TEXT NOT NULL,
            kind TEXT NOT NULL,
            json TEXT NOT NULL,
            PRIMARY KEY (accountId, jid, kind)
        );
        CREATE TABLE IF NOT EXISTS pgp_keys (
            accountId INTEGER NOT NULL,
            jid TEXT NOT NULL,
            fingerprint TEXT NOT NULL,
            json TEXT NOT NULL,
            PRIMARY KEY (accountId, jid, fingerprint)
        );
        """
        try Self.exec(db, sql)
    }

    // MARK: SQL primitives

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(error)
            throw WardError.database(message)
        }
    }

    private func run(_ sql: String, _ bind: [Any?] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw WardError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        try bindValues(stmt, bind)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw WardError.database(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Runs a query and maps every row before the statement is finalized. Never return a
    /// statement pointer to the caller: SQLite owns its lifetime and frees it with the statement.
    private func query<T>(_ sql: String, _ bind: [Any?] = [], _ map: (OpaquePointer) -> T?) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw WardError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        try bindValues(stmt, bind)
        var result: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let value = map(stmt!) { result.append(value) }
        }
        return result
    }

    private func rawRows(_ sql: String, _ bind: [Any?] = [], _ map: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw WardError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        try bindValues(stmt, bind)
        while sqlite3_step(stmt) == SQLITE_ROW { map(stmt!) }
    }

    private func bindValues(_ stmt: OpaquePointer?, _ values: [Any?]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case nil:
                sqlite3_bind_null(stmt, index)
            case let value as String:
                sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
            case let value as Int:
                sqlite3_bind_int64(stmt, index, Int64(value))
            case let value as Int64:
                sqlite3_bind_int64(stmt, index, value)
            case let value as Double:
                sqlite3_bind_double(stmt, index, value)
            case let value as Bool:
                sqlite3_bind_int(stmt, index, value ? 1 : 0)
            default:
                sqlite3_bind_text(stmt, index, "\(value!)", -1, SQLITE_TRANSIENT)
            }
        }
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
    }

    private func decode<T: Decodable>(_ type: T.Type, _ stmt: OpaquePointer, column: Int32 = 0) -> T? {
        guard let cString = sqlite3_column_text(stmt, column) else { return nil }
        let string = String(cString: cString)
        return try? decoder.decode(T.self, from: Data(string.utf8))
    }

    private func columnInt(_ stmt: OpaquePointer, _ index: Int32) -> Int64 { sqlite3_column_int64(stmt, index) }

    // MARK: Accounts

    func accounts() throws -> [Account] {
        try query("SELECT json FROM accounts ORDER BY id") { decode(Account.self, $0) }
    }

    @discardableResult
    func saveAccount(_ account: Account) throws -> Account {
        var value = account
        let payload = try json(value)
        if value.id == 0 {
            try run("INSERT INTO accounts (json) VALUES (?)", [payload])
            value.id = sqlite3_last_insert_rowid(db)
        } else {
            try run("INSERT INTO accounts (id, json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET json=excluded.json",
                    [value.id, payload])
        }
        return value
    }

    func deleteAccount(id: Int64) throws {
        try run("DELETE FROM accounts WHERE id=?", [id])
        try run("DELETE FROM contacts WHERE accountId=?", [id])
        try run("DELETE FROM devices WHERE accountId=?", [id])
        try run("DELETE FROM pgp_keys WHERE accountId=?", [id])
        let chatIds = try query("SELECT id FROM chats WHERE accountId=?", [id]) { columnInt($0, 0) }
        for chatId in chatIds { try run("DELETE FROM messages WHERE chatId=?", [chatId]) }
        try run("DELETE FROM chats WHERE accountId=?", [id])
        try run("DELETE FROM requests WHERE accountId=?", [id])
    }

    // MARK: Contacts

    func contacts(accountId: Int64? = nil) throws -> [Contact] {
        let sql = accountId == nil
            ? "SELECT json FROM contacts ORDER BY jid"
            : "SELECT json FROM contacts WHERE accountId=? ORDER BY jid"
        return try query(sql, accountId.map { [$0] } ?? []) { decode(Contact.self, $0) }
    }

    func saveContact(_ contact: Contact) throws {
        try run("INSERT INTO contacts (accountId, jid, json) VALUES (?, ?, ?) ON CONFLICT(accountId, jid) DO UPDATE SET json=excluded.json",
                [contact.accountId, contact.jid, try json(contact)])
    }

    func saveContacts(_ contacts: [Contact]) throws {
        for contact in contacts { try saveContact(contact) }
    }

    func deleteContact(accountId: Int64, jid: String) throws {
        try run("DELETE FROM contacts WHERE accountId=? AND jid=?", [accountId, jid])
        try run("DELETE FROM devices WHERE accountId=? AND jid=?", [accountId, jid])
        try run("DELETE FROM pgp_keys WHERE accountId=? AND jid=?", [accountId, jid])
    }

    // MARK: Chats

    func chats() throws -> [Chat] {
        try query("SELECT json FROM chats ORDER BY id") { decode(Chat.self, $0) }
            .sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                return $0.lastActivity > $1.lastActivity
            }
    }

    func chat(id: Int64) throws -> Chat? {
        try query("SELECT json FROM chats WHERE id=?", [id]) { decode(Chat.self, $0) }.first
    }

    func chat(accountId: Int64, jid: String) throws -> Chat? {
        try query("SELECT json FROM chats WHERE accountId=? AND jid=?", [accountId, jid]) { decode(Chat.self, $0) }.first
    }

    @discardableResult
    func saveChat(_ chat: Chat) throws -> Chat {
        var value = chat
        let payload = try json(value)
        if value.id == 0 {
            try run("INSERT INTO chats (accountId, jid, json) VALUES (?, ?, ?) ON CONFLICT(accountId, jid) DO UPDATE SET json=excluded.json",
                    [value.accountId, value.jid, payload])
            if let existing = try self.chat(accountId: value.accountId, jid: value.jid) {
                return existing
            }
            value.id = sqlite3_last_insert_rowid(db)
        } else {
            try run("INSERT INTO chats (id, accountId, jid, json) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET json=excluded.json",
                    [value.id, value.accountId, value.jid, payload])
        }
        return value
    }

    func deleteChat(id: Int64) throws {
        try run("DELETE FROM messages WHERE chatId=?", [id])
        try run("DELETE FROM chats WHERE id=?", [id])
    }

    func resetChats() throws {
        let chats = try self.chats()
        for var chat in chats {
            chat.preview = ""
            chat.previewSender = ""
            chat.unread = 0
            chat.mentions = 0
            chat.lastReadId = 0
            try saveChat(chat)
        }
    }

    // MARK: Messages

    func messages(chatId: Int64, limit: Int = 600) throws -> [Message] {
        let sql = "SELECT json FROM messages WHERE chatId=? ORDER BY timestamp ASC, id ASC LIMIT ?"
        return try query(sql, [chatId, limit]) { decode(Message.self, $0) }
    }

    func message(id: Int64) throws -> Message? {
        try query("SELECT json FROM messages WHERE id=?", [id]) { decode(Message.self, $0) }.first
    }

    func lastMessage(chatId: Int64) throws -> Message? {
        try query("SELECT json FROM messages WHERE chatId=? ORDER BY timestamp DESC, id DESC LIMIT 1", [chatId]) { decode(Message.self, $0) }.first
    }

    func findMessage(chatId: Int64, ref: String) throws -> Message? {
        try query("SELECT json FROM messages WHERE chatId=? AND (stanzaId=? OR originId=?) LIMIT 1", [chatId, ref, ref]) { decode(Message.self, $0) }.first
    }

    /// Returns nil when the stanza already exists (a duplicate carbon or MAM echo).
    func insertMessage(_ message: Message) throws -> Message? {
        if !message.stanzaId.isEmpty, try findMessage(chatId: message.chatId, ref: message.stanzaId) != nil {
            return nil
        }
        var value = message
        try run("INSERT INTO messages (chatId, stanzaId, originId, timestamp, body, json) VALUES (?, ?, ?, ?, ?, ?)",
                [value.chatId, value.stanzaId, value.originId, value.timestamp, value.body, try json(value)])
        value.id = sqlite3_last_insert_rowid(db)
        return value
    }

    func updateMessage(_ message: Message) throws {
        guard message.id != 0 else { return }
        try run("UPDATE messages SET stanzaId=?, originId=?, timestamp=?, body=?, json=? WHERE id=?",
                [message.stanzaId, message.originId, message.timestamp, message.body, try json(message), message.id])
    }

    func deleteMessage(id: Int64) throws { try run("DELETE FROM messages WHERE id=?", [id]) }
    func clearMessages(chatId: Int64) throws { try run("DELETE FROM messages WHERE chatId=?", [chatId]) }
    func clearAllMessages() throws { try run("DELETE FROM messages") }

    func search(chatId: Int64?, query: String) throws -> [Message] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pattern = "%\(trimmed)%"
        let sql = chatId == nil
            ? "SELECT json FROM messages WHERE body LIKE ? ORDER BY timestamp DESC LIMIT 200"
            : "SELECT json FROM messages WHERE chatId=? AND body LIKE ? ORDER BY timestamp DESC LIMIT 200"
        let bind: [Any?] = chatId == nil ? [pattern] : [chatId!, pattern]
        return try query(sql, bind) { decode(Message.self, $0) }
    }

    // MARK: Devices

    func devices(accountId: Int64, jid: String? = nil) throws -> [Device] {
        let sql = jid == nil
            ? "SELECT json FROM devices WHERE accountId=? ORDER BY jid, deviceId"
            : "SELECT json FROM devices WHERE accountId=? AND jid=? ORDER BY deviceId"
        return try query(sql, jid == nil ? [accountId] : [accountId, jid!]) { decode(Device.self, $0) }
    }

    func saveDevice(_ device: Device) throws {
        try run("INSERT INTO devices (accountId, jid, deviceId, protocolName, json) VALUES (?, ?, ?, ?, ?) ON CONFLICT(accountId, jid, deviceId, protocolName) DO UPDATE SET json=excluded.json",
                [device.accountId, device.jid, device.deviceId, device.protocolName, try json(device)])
    }

    func setDeviceTrust(accountId: Int64, jid: String, deviceId: Int64, protocolName: String, trust: String) throws {
        guard var device = try devices(accountId: accountId, jid: jid).first(where: { $0.deviceId == deviceId && $0.protocolName == protocolName }) else { return }
        device.trust = trust
        try saveDevice(device)
    }

    func deleteDevice(accountId: Int64, jid: String, deviceId: Int64, protocolName: String) throws {
        try run("DELETE FROM devices WHERE accountId=? AND jid=? AND deviceId=? AND protocolName=?",
                [accountId, jid, deviceId, protocolName])
    }

    // MARK: Requests

    func requests() throws -> [ContactRequest] {
        try query("SELECT json FROM requests ORDER BY json") { decode(ContactRequest.self, $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func saveRequest(_ request: ContactRequest) throws {
        try run("INSERT INTO requests (accountId, jid, kind, json) VALUES (?, ?, ?, ?) ON CONFLICT(accountId, jid, kind) DO UPDATE SET json=excluded.json",
                [request.accountId, request.jid, request.kind, try json(request)])
    }

    func deleteRequest(accountId: Int64, jid: String) throws {
        try run("DELETE FROM requests WHERE accountId=? AND jid=?", [accountId, jid])
    }

    // MARK: PGP

    func pgpKeys(accountId: Int64, jid: String) throws -> [PgpKey] {
        try query("SELECT json FROM pgp_keys WHERE accountId=? AND jid=? ORDER BY fingerprint", [accountId, jid]) { decode(PgpKey.self, $0) }
    }

    func savePgpKey(_ key: PgpKey) throws {
        try run("INSERT INTO pgp_keys (accountId, jid, fingerprint, json) VALUES (?, ?, ?, ?) ON CONFLICT(accountId, jid, fingerprint) DO UPDATE SET json=excluded.json",
                [key.accountId, key.jid, key.fingerprint, try json(key)])
    }

    // MARK: Receipts

    func saveReceipt(_ receipt: Receipt) throws {
        try run("INSERT INTO receipts (messageId, recipient, json) VALUES (?, ?, ?) ON CONFLICT(messageId, recipient) DO UPDATE SET json=excluded.json",
                [receipt.messageId, receipt.recipient, try json(receipt)])
    }

    func receipts(messageId: Int64) throws -> [Receipt] {
        try query("SELECT json FROM receipts WHERE messageId=?", [messageId]) { decode(Receipt.self, $0) }
    }

    // MARK: Maintenance

    func wipeEncryptionAndHistory() throws {
        try run("DELETE FROM messages")
        try run("DELETE FROM devices")
        try run("DELETE FROM pgp_keys")
        try run("DELETE FROM receipts")
        try resetChats()
    }
}

enum WardError: LocalizedError {
    case database(String)
    case network(String)
    case protocolError(String)
    case notConnected
    case authentication(String)
    case encryption(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .database(let message): return message
        case .network(let message): return message
        case .protocolError(let message): return message
        case .notConnected: return "Not connected to the server."
        case .authentication(let message): return message
        case .encryption(let message): return message
        case .cancelled: return "Cancelled."
        }
    }
}
