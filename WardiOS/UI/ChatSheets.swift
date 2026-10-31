import UIKit
import SwiftUI

// MARK: - Chat details

struct ChatDetailsSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    var chat: Chat

    @State private var showMembers = false
    @State private var showDevices = false
    @State private var showInvite = false
    @State private var showSubject = false
    @State private var showDelete = false
    @State private var showClear = false
    @State private var showSearch = false
    @State private var inviteJID = ""
    @State private var subject = ""

    private var contact: Contact? { app.contact(jid: chat.jid, accountId: chat.accountId) }
    private var current: Chat { app.chat(id: chat.id) ?? chat }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    quickActions
                    settingsCard
                    if current.isGroup { groupCard } else { directCard }
                    dangerCard
                    Spacer(minLength: 30)
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }
            .background(WardBackground())
            .scrollIndicators(.hidden)
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showMembers) { MembersSheet(chat: current) }
            .sheet(isPresented: $showSearch) { ChatSearchSheet(chat: current) }
            .sheet(isPresented: $showDevices) { DevicesSheet(accountId: chat.accountId, jid: chat.jid) }
            .alert("Invite to group", isPresented: $showInvite) {
                TextField("alice@example.org", text: $inviteJID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Invite") { app.invite(current, jid: inviteJID); inviteJID = "" }
                Button("Cancel", role: .cancel) { inviteJID = "" }
            }
            .alert("Group topic", isPresented: $showSubject) {
                TextField("Topic", text: $subject)
                Button("Save") { Task { await app.setSubject(current, subject: subject) } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Clear this conversation?", isPresented: $showClear, titleVisibility: .visible) {
                Button("Clear history", role: .destructive) { Task { await app.clearHistory(current); dismiss() } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Leave and delete this chat?", isPresented: $showDelete, titleVisibility: .visible) {
                Button("Delete chat", role: .destructive) { Task { await app.deleteChat(current); dismiss() } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            AvatarView(name: current.displayName, jid: current.jid, size: 88,
                       presence: current.isGroup ? nil : contact?.presence,
                       imagePath: current.avatar.isEmpty ? contact?.avatar : current.avatar,
                       group: current.isGroup)
            Text(current.displayName).font(.title2.weight(.bold)).foregroundStyle(palette.text)
            Text(current.isGroup ? "\(max(current.memberCount, app.members[current.jid]?.count ?? 0)) members" : current.jid)
                .font(.caption).foregroundStyle(palette.secondaryText)
            if !current.isGroup {
                Text(WardFormat.presence(contact, state: app.states[chat.accountId]))
                    .font(.caption).foregroundStyle(palette.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            if !current.isGroup {
                QuickAction(icon: "phone.fill", title: "Call", color: palette.success) { app.startCall(current, video: false) }
                QuickAction(icon: "video.fill", title: "Video", color: palette.accent) { app.startCall(current, video: true) }
            }
            QuickAction(icon: "magnifyingglass", title: "Search", color: palette.purple) { showSearch = true }
            if current.isGroup {
                QuickAction(icon: "person.3.fill", title: "Members", color: palette.accent) { showMembers = true }
            } else {
                QuickAction(icon: "lock.shield.fill", title: "Devices", color: palette.warning) { showDevices = true }
            }
        }
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            Menu {
                ForEach(EncryptionMode.allCases) { mode in
                    Button {
                        Task { await app.setEncryption(current, mode) }
                    } label: {
                        Label(mode.label, systemImage: current.encryptionMode == mode ? "checkmark" : "")
                    }
                }
            } label: {
                DetailRow(icon: "lock.shield.fill", color: palette.success, title: "Encryption",
                          value: current.encryptionMode.label)
            }
            Divider().padding(.leading, 50)
            Menu {
                Button("Default") { Task { await app.setNotify(current, "default") } }
                Button("All messages") { Task { await app.setNotify(current, "all") } }
                Button("Mentions only") { Task { await app.setNotify(current, "mentions") } }
                Button("Nothing") { Task { await app.setNotify(current, "none") } }
            } label: {
                DetailRow(icon: "bell.badge.fill", color: palette.orange, title: "Notifications",
                          value: notifyLabel(current.notify))
            }
            Divider().padding(.leading, 50)
            Menu {
                Button("Off") { Task { await app.setMuted(current, until: 0) } }
                Button("For 1 hour") { Task { await app.setMuted(current, until: Date().addingTimeInterval(3600).millis) } }
                Button("For 8 hours") { Task { await app.setMuted(current, until: Date().addingTimeInterval(28800).millis) } }
                Button("For 1 day") { Task { await app.setMuted(current, until: Date().addingTimeInterval(86400).millis) } }
                Button("For 1 week") { Task { await app.setMuted(current, until: Date().addingTimeInterval(604800).millis) } }
            } label: {
                DetailRow(icon: current.isMuted ? "bell.slash.fill" : "bell.fill", color: palette.purple,
                          title: "Mute", value: current.isMuted ? "On" : "Off")
            }
            Divider().padding(.leading, 50)
            Button { Task { await app.setPinned(current, !current.pinned) } } label: {
                DetailRow(icon: "pin.fill", color: palette.warning, title: "Pin chat",
                          value: current.pinned ? "On" : "Off", chevron: false)
            }
            Divider().padding(.leading, 50)
            Button { Task { await app.setArchived(current, true); dismiss() } } label: {
                DetailRow(icon: "archivebox.fill", color: palette.slate, title: "Archive", value: "", chevron: false)
            }
        }
        .padding(.horizontal, 14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.outline.opacity(0.2), lineWidth: 0.5))
    }

    private var groupCard: some View {
        VStack(spacing: 0) {
            Button { subject = current.subject; showSubject = true } label: {
                DetailRow(icon: "text.quote", color: palette.accent, title: "Topic",
                          value: current.subject.isEmpty ? "Set a topic" : current.subject)
            }
            Divider().padding(.leading, 50)
            Button { showMembers = true } label: {
                DetailRow(icon: "person.3.fill", color: palette.purple, title: "Members",
                          value: "\(max(current.memberCount, app.members[current.jid]?.count ?? 0))")
            }
            Divider().padding(.leading, 50)
            Button { showInvite = true } label: {
                DetailRow(icon: "person.badge.plus", color: palette.success, title: "Invite someone", value: "")
            }
            Divider().padding(.leading, 50)
            Button { Task { await app.leaveGroup(current); dismiss() } } label: {
                DetailRow(icon: "rectangle.portrait.and.arrow.right", color: palette.danger, title: "Leave group", value: "", chevron: false)
            }
        }
        .padding(.horizontal, 14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.outline.opacity(0.2), lineWidth: 0.5))
    }

    private var directCard: some View {
        VStack(spacing: 0) {
            Button { showDevices = true } label: {
                DetailRow(icon: "lock.shield.fill", color: palette.warning, title: "Encryption devices", value: "")
            }
            Divider().padding(.leading, 50)
            if let contact {
                Button { Task { await app.block(contact, blocked: !contact.blocked) } } label: {
                    DetailRow(icon: "hand.raised.fill", color: palette.danger, title: contact.blocked ? "Unblock contact" : "Block contact", value: "", chevron: false)
                }
                Divider().padding(.leading, 50)
            }
            Button {
                UIPasteboard.general.string = current.jid
                app.showToast("Address copied.")
            } label: {
                DetailRow(icon: "doc.on.doc.fill", color: palette.slate, title: "Copy address", value: "", chevron: false)
            }
        }
        .padding(.horizontal, 14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.outline.opacity(0.2), lineWidth: 0.5))
    }

    private var dangerCard: some View {
        VStack(spacing: 0) {
            Button { showClear = true } label: {
                DetailRow(icon: "eraser.fill", color: palette.orange, title: "Clear history", value: "", chevron: false)
            }
            Divider().padding(.leading, 50)
            Button { showDelete = true } label: {
                DetailRow(icon: "trash.fill", color: palette.danger, title: "Delete chat", value: "", chevron: false)
            }
        }
        .padding(.horizontal, 14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.outline.opacity(0.2), lineWidth: 0.5))
    }

    private func notifyLabel(_ value: String) -> String {
        switch value {
        case "all": return "All"
        case "mentions": return "Mentions"
        case "none": return "None"
        default: return "Default"
        }
    }
}

private struct QuickAction: View {
    @Environment(\.ward) private var palette
    var icon: String
    var title: String
    var color: Color
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(color)
                    .frame(width: 42, height: 42).background(color.opacity(0.12), in: Circle())
                Text(title).font(.caption2.weight(.medium)).foregroundStyle(palette.secondaryText)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableStyle())
    }
}

private struct DetailRow: View {
    @Environment(\.ward) private var palette
    var icon: String
    var color: Color
    var title: String
    var value: String
    var chevron: Bool = true
    var body: some View {
        HStack(spacing: 12) {
            IconTile(icon: icon, color: color, size: 30)
            Text(title).font(.subheadline).foregroundStyle(palette.text)
            Spacer()
            Text(value).font(.caption).foregroundStyle(palette.secondaryText).lineLimit(1)
            if chevron {
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(palette.tertiaryText)
            }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

// MARK: - Members

struct MembersSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    var chat: Chat
    @State private var showInvite = false
    @State private var inviteJID = ""

    private var occupants: [RoomOccupant] { app.members[chat.jid] ?? [] }

    var body: some View {
        NavigationStack {
            List {
                if occupants.isEmpty {
                    Section {
                        ContentUnavailableView("No member list yet", systemImage: "person.3",
                                               description: Text("Join the group to see who is here."))
                    }
                }
                Section("Members (\(max(occupants.count, chat.memberCount)))") {
                    ForEach(occupants) { member in
                        HStack(spacing: 12) {
                            AvatarView(name: member.nick, jid: member.jid, size: 38, presence: "online")
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(member.nick).font(.subheadline.weight(.medium))
                                    if member.isMe {
                                        Text("You").font(.system(size: 8, weight: .bold))
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(palette.accent.opacity(0.15), in: Capsule())
                                            .foregroundStyle(palette.accent)
                                    }
                                }
                                Text(member.jid.isEmpty ? member.role : member.jid)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(member.affiliation == "owner" ? "Owner" : member.affiliation == "admin" ? "Admin" : member.role)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(member.role == "moderator" ? palette.accent : palette.secondaryText)
                        }
                        .contextMenu {
                            Button { app.setRole(chat, nick: member.nick, role: "moderator") } label: {
                                Label("Make moderator", systemImage: "shield.lefthalf.filled")
                            }
                            Button { app.setRole(chat, nick: member.nick, role: "participant") } label: {
                                Label("Remove moderator", systemImage: "shield.slash")
                            }
                            Button { app.setAffiliation(chat, jid: member.jid, affiliation: "admin") } label: {
                                Label("Make admin", systemImage: "crown")
                            }
                            Divider()
                            Button(role: .destructive) { app.kick(chat, nick: member.nick) } label: {
                                Label("Remove from group", systemImage: "person.badge.minus")
                            }
                            Button(role: .destructive) { app.ban(chat, jid: member.jid) } label: {
                                Label("Ban", systemImage: "nosign")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showInvite = true } label: { Image(systemName: "person.badge.plus") }
                }
            }
            .alert("Invite to group", isPresented: $showInvite) {
                TextField("alice@example.org", text: $inviteJID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Invite") { app.invite(chat, jid: inviteJID); inviteJID = "" }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

// MARK: - Devices

struct DevicesSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    var accountId: Int64
    var jid: String
    @State private var loading = true

    private var devices: [Device] { app.devices[jid] ?? [] }

    var body: some View {
        NavigationStack {
            Group {
                if loading && devices.isEmpty {
                    ProgressView("Finding devices…")
                } else if devices.isEmpty {
                    ContentUnavailableView("No devices published", systemImage: "lock.shield",
                                           description: Text("This contact has not published any OMEMO devices."))
                } else {
                    List {
                        Section {
                            ForEach(devices) { device in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Image(systemName: device.thisDevice ? "iphone" : "lock.shield.fill")
                                            .foregroundStyle(device.trust == "trusted" ? palette.success : palette.accent)
                                        Text(device.thisDevice ? "This device" : (device.label.isEmpty ? "Device \(device.deviceId)" : device.label))
                                            .font(.subheadline.weight(.medium))
                                        Spacer()
                                        Text(device.trust == "trusted" ? "Trusted" : device.trust == "distrusted" ? "Distrusted" : "Unverified")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(device.trust == "trusted" ? palette.success : device.trust == "distrusted" ? palette.danger : palette.warning)
                                    }
                                    Text(device.fingerprint.isEmpty ? "Fingerprint not fetched" : WardFormat.fingerprint(device.fingerprint))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    HStack(spacing: 6) {
                                        Text("ID \(device.deviceId)").font(.caption2).foregroundStyle(.tertiary)
                                        Text(device.protocolName == "omemo2" ? "OMEMO 2" : "OMEMO")
                                            .font(.caption2.weight(.medium))
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(palette.accent.opacity(0.12), in: Capsule())
                                    }
                                    HStack(spacing: 10) {
                                        Button("Trust") { Task { await app.trustDevice(device, trusted: true) } }
                                            .buttonStyle(.bordered).tint(palette.success).controlSize(.small)
                                        Button("Distrust") { Task { await app.trustDevice(device, trusted: false) } }
                                            .buttonStyle(.bordered).tint(palette.danger).controlSize(.small)
                                        if !device.thisDevice {
                                            Button("Forget", role: .destructive) { Task { await app.forgetDevice(device) } }
                                                .buttonStyle(.bordered).controlSize(.small)
                                        }
                                    }
                                    .padding(.top, 2)
                                }
                                .padding(.vertical, 5)
                            }
                        } header: {
                            Text("Fingerprints")
                        } footer: {
                            Text("Compare fingerprints with your contact in person or over another trusted channel. Trust is stored on this device.")
                        }
                    }
                }
            }
            .navigationTitle("Encryption devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task {
                await app.loadDevices(accountId: accountId, jid: jid)
                loading = false
            }
            .refreshable {
                await app.loadDevices(accountId: accountId, jid: jid)
            }
        }
    }
}

// MARK: - Search

struct ChatSearchSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    var chat: Chat
    @State private var query = ""
    @State private var results: [Message] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(palette.secondaryText)
                    TextField("Search this conversation", text: $query)
                        .textInputAutocapitalization(.never)
                        .onChange(of: query) { _, value in search(value) }
                    if !query.isEmpty {
                        Button { query = ""; results = [] } label: { Image(systemName: "xmark.circle.fill") }
                            .foregroundStyle(palette.tertiaryText)
                    }
                }
                .padding(11)
                .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(14)

                if results.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "Search messages" : "No matches",
                                           systemImage: "text.magnifyingglass",
                                           description: Text(query.isEmpty ? "Find text in this conversation." : "Try another word."))
                } else {
                    List(results) { message in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(message.senderName).font(.caption.weight(.semibold)).foregroundStyle(palette.accent)
                                Spacer()
                                Text(WardFormat.chatListTime(message.date, settings: app.settings))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(message.body).font(.subheadline).lineLimit(3)
                        }
                        .padding(.vertical, 3)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(chat.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func search(_ value: String) {
        let needle = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { results = []; return }
        results = app.messages(for: chat.id).filter { $0.body.lowercased().contains(needle) }.reversed()
    }
}

// MARK: - Forward

struct ForwardSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    var message: Message
    @State private var query = ""

    private var chats: [Chat] {
        app.chats.filter { !$0.archived && (query.isEmpty || $0.displayName.lowercased().contains(query.lowercased())) }
    }

    var body: some View {
        NavigationStack {
            List(chats) { chat in
                Button {
                    app.forward(message, to: chat)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: chat.displayName, jid: chat.jid, size: 38, group: chat.isGroup,
                                   imagePath: chat.avatar)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(chat.displayName).font(.subheadline.weight(.medium)).foregroundStyle(palette.text)
                            Text(chat.preview).font(.caption).foregroundStyle(palette.secondaryText).lineLimit(1)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search chats")
            .navigationTitle("Forward to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
    }
}

// MARK: - New chat / contact / group

struct NewChatSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var accountId: Int64 = 0
    @State private var address = ""
    @State private var name = ""
    @State private var showAddContact = false
    @State private var showNewGroup = false
    @State private var showJoinGroup = false
    @State private var error = ""

    private var account: Account? { app.accounts.first { $0.id == accountId } ?? app.accounts.first }
    private var suggestions: [Contact] {
        guard !address.isEmpty else { return [] }
        return app.contacts.filter {
            $0.accountId == (account?.id ?? 0) &&
            ($0.name.lowercased().contains(address.lowercased()) || $0.jid.lowercased().contains(address.lowercased()))
        }.prefix(5).map { $0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if app.accounts.count > 1 {
                        Picker("From", selection: $accountId) {
                            ForEach(app.accounts) { account in
                                Text(account.jid).tag(account.id)
                            }
                        }
                    }
                    TextField("Address (you@example.org)", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    TextField("Name (optional)", text: $name)
                } header: {
                    Text("Start a chat")
                } footer: {
                    if !error.isEmpty { Text(error).foregroundStyle(palette.danger) }
                }

                if !suggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(suggestions) { contact in
                            Button {
                                Task {
                                    await app.openChat(accountId: contact.accountId, jid: contact.jid)
                                    dismiss()
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    AvatarView(name: contact.name, jid: contact.jid, size: 30, presence: contact.presence)
                                    VStack(alignment: .leading) {
                                        Text(contact.name).foregroundStyle(palette.text)
                                        Text(contact.jid).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        guard let account else { return }
                        let value = address.contains("@") ? address : "\(address)@\(account.domain)"
                        guard JID.valid(value) else { error = "Enter a valid XMPP address."; return }
                        Task {
                            await app.openChat(accountId: account.id, jid: value, name: name)
                            dismiss()
                        }
                    } label: {
                        Label("Message", systemImage: "bubble.left.fill")
                    }
                    .disabled(address.isEmpty)
                    Button { showAddContact = true } label: {
                        Label("Add contact", systemImage: "person.badge.plus")
                    }
                }

                Section {
                    Button { showNewGroup = true } label: { Label("New group", systemImage: "person.3.sequence.fill") }
                    Button { showJoinGroup = true } label: { Label("Join a group", systemImage: "rectangle.portrait.and.arrow.forward") }
                }
            }
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $showAddContact) { AddContactSheet(initialAccountId: accountId) }
            .sheet(isPresented: $showNewGroup) { NewGroupSheet(initialAccountId: accountId) }
            .sheet(isPresented: $showJoinGroup) { JoinGroupSheet(initialAccountId: accountId) }
            .onAppear { if accountId == 0 { accountId = app.accounts.first?.id ?? 0 } }
        }
    }
}

struct AddContactSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    var initialAccountId: Int64? = nil
    @State private var accountId: Int64 = 0
    @State private var jid = ""
    @State private var name = ""
    @State private var message = ""
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if app.accounts.count > 1 {
                        Picker("From", selection: $accountId) {
                            ForEach(app.accounts) { Text($0.jid).tag($0.id) }
                        }
                    }
                    TextField("Address", text: $jid).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                    TextField("Name (optional)", text: $name)
                    TextField("Intro message (optional)", text: $message)
                } footer: {
                    if !error.isEmpty { Text(error).foregroundStyle(palette.danger) }
                }
            }
            .navigationTitle("Add contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        guard let account = app.account(id: accountId) else { return }
                        let value = jid.contains("@") ? jid : "\(jid)@\(account.domain)"
                        guard JID.valid(value) else { error = "Enter a valid XMPP address."; return }
                        busy = true
                        Task {
                            await app.addContact(accountId: account.id, jid: value, name: name)
                            dismiss()
                        }
                    }
                    .disabled(jid.isEmpty || busy)
                }
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                accountId = initialAccountId ?? app.accounts.first?.id ?? 0
            }
        }
    }
}

struct NewGroupSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    var initialAccountId: Int64? = nil
    @State private var accountId: Int64 = 0
    @State private var room = ""
    @State private var name = ""
    @State private var isPrivate = true
    @State private var description = ""
    @State private var invitees = ""
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if app.accounts.count > 1 {
                        Picker("From", selection: $accountId) {
                            ForEach(app.accounts) { Text($0.jid).tag($0.id) }
                        }
                    }
                    TextField("Group name", text: $name)
                    TextField("Room address (optional)", text: $room)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text(room.isEmpty && !name.isEmpty ? "Ward will suggest a room address on your server." : "Group addresses look like room@conference.example.org.")
                }
                Section {
                    Toggle("Private group", isOn: $isPrivate)
                    TextField("Topic", text: $description, axis: .vertical)
                    TextField("Invite (comma-separated addresses)", text: $invitees, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    if !error.isEmpty { Text(error).foregroundStyle(palette.danger) }
                    Text("Private groups are members-only. Public channels can be discovered by anyone on the server.")
                }
                Section {
                    Button {
                        create()
                    } label: {
                        HStack {
                            if busy { ProgressView() }
                            Text("Create group")
                        }
                    }
                    .disabled(name.isEmpty || busy)
                }
            }
            .navigationTitle("New group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } }
            }
            .onAppear { accountId = initialAccountId ?? app.accounts.first?.id ?? 0 }
        }
    }

    private func create() {
        guard let account = app.account(id: accountId) else { return }
        var slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        if slug.isEmpty { slug = "group-\(Int(Date().timeIntervalSince1970))" }
        let roomJID = room.isEmpty ? "\(slug)@conference.\(account.domain)" : room
        let list = invitees.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
        busy = true
        Task {
            _ = await app.createGroup(accountId: account.id, room: roomJID, name: name,
                                      isPrivate: isPrivate, description: description, invitees: list)
            dismiss()
        }
    }
}

struct JoinGroupSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    var initialAccountId: Int64? = nil
    @State private var accountId: Int64 = 0
    @State private var room = ""
    @State private var nick = ""
    @State private var password = ""
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if app.accounts.count > 1 {
                        Picker("From", selection: $accountId) {
                            ForEach(app.accounts) { Text($0.jid).tag($0.id) }
                        }
                    }
                    TextField("room@conference.example.org", text: $room)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Nickname (optional)", text: $nick)
                    SecureField("Password (optional)", text: $password)
                } footer: {
                    if !error.isEmpty { Text(error).foregroundStyle(palette.danger) }
                }
                Section {
                    Button("Join") {
                        guard let account = app.account(id: accountId) else { return }
                        var value = room
                        if !value.contains("@") { value = "\(value)@conference.\(account.domain)" }
                        guard JID.valid(value) else { error = "Enter a room address."; return }
                        Task {
                            guard let chat = await app.ensureChat(accountId: account.id, jid: JID.bare(value), type: .groupchat, name: JID.local(value)) else { return }
                            await app.joinGroup(chat, nick: nick, password: password)
                            dismiss()
                        }
                    }
                    .disabled(room.isEmpty)
                }
            }
            .navigationTitle("Join a group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
            .onAppear { accountId = initialAccountId ?? app.accounts.first?.id ?? 0 }
        }
    }
}

// MARK: - Profile

struct ProfileSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false
    @State private var removeAccount: Account? = nil
    @State private var presence = "online"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        AvatarView(name: app.accounts.first?.displayName ?? "Ward",
                                   jid: app.accounts.first?.jid ?? "", size: 76,
                                   presence: app.states[app.accounts.first?.id ?? 0]?.state == "online" ? "online" : "offline",
                                   imagePath: app.accounts.first?.avatar)
                        Text(app.accounts.first?.displayName ?? "Ward").font(.title3.weight(.bold))
                        Text(app.accounts.first?.jid ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 9) {
                        Text("PRESENCE").font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(palette.tertiaryText)
                        HStack(spacing: 7) {
                            ForEach(Array([("online", "Online", "circle.fill"), ("away", "Away", "moon.fill"), ("dnd", "Busy", "minus.circle.fill"), ("offline", "Offline", "circle")].enumerated()), id: \.offset) { _, item in
                                Button {
                                    presence = item.0
                                    app.setPresence(item.0)
                                    Haptics.selection()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: item.2).font(.system(size: 9))
                                        Text(item.1).font(.caption.weight(.medium))
                                    }
                                    .foregroundStyle(presence == item.0 ? palette.onAccent : palette.secondaryText)
                                    .padding(.horizontal, 9).padding(.vertical, 6)
                                    .background(presence == item.0 ? palette.accent : palette.surfaceContainer, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    VStack(spacing: 0) {
                        ForEach(app.accounts) { account in
                            HStack(spacing: 12) {
                                AvatarView(name: account.displayName, jid: account.jid, size: 40,
                                           presence: app.states[account.id]?.state == "online" ? "online" : "offline",
                                           imagePath: account.avatar)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.displayName).font(.subheadline.weight(.medium)).foregroundStyle(palette.text)
                                    Text(account.jid).font(.caption2).foregroundStyle(palette.secondaryText)
                                    if let state = app.states[account.id], state.state != "online" {
                                        Text(state.error.isEmpty ? state.label : state.error)
                                            .font(.caption2).foregroundStyle(palette.danger).lineLimit(2)
                                    }
                                }
                                Spacer()
                                ConnectionPill(state: app.states[account.id] ?? ConnectionState())
                                Menu {
                                    if app.states[account.id]?.state == "online" {
                                        Button { app.disconnect(account) } label: { Label("Disconnect", systemImage: "wifi.slash") }
                                    } else {
                                        Button { app.connect(account) } label: { Label("Connect", systemImage: "wifi") }
                                    }
                                    Button(role: .destructive) { removeAccount = account } label: {
                                        Label("Remove account", systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis").foregroundStyle(palette.tertiaryText)
                                }
                            }
                            .padding(.vertical, 11)
                            if account.id != app.accounts.last?.id {
                                Divider().padding(.leading, 52)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    Button { showAdd = true } label: {
                        Label("Add another account", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(WardSecondaryButtonStyle())
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 18)
            }
            .background(WardBackground())
            .navigationTitle("You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showAdd) { AddAccountSheet() }
            .confirmationDialog("Remove this account?", isPresented: Binding(get: { removeAccount != nil }, set: { if !$0 { removeAccount = nil } }), titleVisibility: .visible) {
                Button("Remove account", role: .destructive) {
                    if let account = removeAccount { Task { await app.deleteAccount(account) } }
                    removeAccount = nil
                }
                Button("Cancel", role: .cancel) { removeAccount = nil }
            } message: {
                Text("The local history and keys for this account will be deleted from this device.")
            }
        }
    }
}

struct AddAccountSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var jid = ""
    @State private var password = ""
    @State private var remember = true
    @State private var advanced = false
    @State private var host = ""
    @State private var port = ""
    @State private var tls = "auto"
    @State private var error = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("you@example.org", text: $jid)
                        .textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(.password)
                    Toggle("Remember in Keychain", isOn: $remember)
                } footer: {
                    if !error.isEmpty { Text(error).foregroundStyle(palette.danger) }
                }
                Section {
                    TextField("Server host (optional)", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port (optional)", text: $port).keyboardType(.numberPad)
                    Picker("TLS", selection: $tls) {
                        Text("Automatic").tag("auto")
                        Text("Require STARTTLS").tag("starttls")
                    }
                }
            }
            .navigationTitle("Add account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        busy = true
                        Task {
                            do {
                                _ = try await app.addAccount(jid: jid, password: password, remember: remember,
                                                             host: host, port: port, tls: tls)
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                                busy = false
                            }
                        }
                    }
                    .disabled(jid.isEmpty || password.isEmpty || busy)
                }
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

// MARK: - Archived & requests

struct ArchivedChatsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss

    private var archived: [Chat] { app.chats.filter { $0.archived } }

    var body: some View {
        NavigationStack {
            Group {
                if archived.isEmpty {
                    ContentUnavailableView("Nothing archived", systemImage: "archivebox",
                                           description: Text("Archived chats stay out of the way until you need them."))
                } else {
                    List(archived) { chat in
                        Button {
                            Task { await app.setArchived(chat, false); app.selectChat(chat.id); dismiss() }
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: chat.displayName, jid: chat.jid, size: 40, group: chat.isGroup, imagePath: chat.avatar)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(chat.displayName).font(.subheadline.weight(.medium)).foregroundStyle(palette.text)
                                    Text(chat.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if chat.unread > 0 {
                                    Text("\(chat.unread)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 3)
                                        .background(palette.accent, in: Capsule())
                                }
                            }
                        }
                        .swipeActions {
                            Button { Task { await app.setArchived(chat, false) } } label: {
                                Label("Unarchive", systemImage: "tray.and.arrow.up")
                            }.tint(palette.accent)
                            Button(role: .destructive) { Task { await app.deleteChat(chat) } } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Archived")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct RequestsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if app.requests.isEmpty {
                    ContentUnavailableView("No requests", systemImage: "person.crop.circle.badge.questionmark",
                                           description: Text("Messages from people you have not added appear here."))
                } else {
                    List {
                        ForEach(app.requests) { request in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack(spacing: 11) {
                                    AvatarView(name: app.contact(jid: request.jid, accountId: request.accountId)?.name ?? JID.local(request.jid),
                                               jid: request.jid, size: 42)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.contact(jid: request.jid, accountId: request.accountId)?.name ?? JID.local(request.jid))
                                            .font(.subheadline.weight(.semibold))
                                        Text(request.jid).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(WardFormat.chatListTime(Date(millis: request.createdAt), settings: app.settings))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                if !request.text.isEmpty {
                                    Text(request.text).font(.subheadline).foregroundStyle(palette.secondaryText).lineLimit(3)
                                }
                                HStack(spacing: 8) {
                                    Button("Accept") {
                                        Task { await app.acceptRequest(request); dismiss() }
                                    }
                                    .buttonStyle(.borderedProminent).tint(palette.accent).controlSize(.small)
                                    Button("Decline") {
                                        Task { await app.declineRequest(request) }
                                    }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    Button("Block") {
                                        Task { await app.declineRequest(request, block: true) }
                                    }
                                    .buttonStyle(.bordered).tint(palette.danger).controlSize(.small)
                                }
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
            }
            .navigationTitle("Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}


// MARK: - Global search

struct GlobalSearchView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Message] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            Group {
                if searching {
                    ProgressView("Searching…")
                } else if query.isEmpty {
                    ContentUnavailableView("Search all messages", systemImage: "text.magnifyingglass",
                                           description: Text("Find text across every chat on this device."))
                } else if results.isEmpty {
                    ContentUnavailableView("No matches", systemImage: "magnifyingglass",
                                           description: Text("Try a different word."))
                } else {
                    List(results) { message in
                        Button {
                            app.selectChat(message.chatId)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(app.chat(id: message.chatId)?.displayName ?? "Chat")
                                        .font(.caption.weight(.semibold)).foregroundStyle(palette.accent)
                                    Spacer()
                                    Text(WardFormat.chatListTime(message.date, settings: app.settings))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(message.body).font(.subheadline).lineLimit(3).foregroundStyle(palette.text)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Search messages")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search every chat")
            .onChange(of: query) { _, value in
                Task {
                    let needle = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard needle.count >= 2 else { results = []; return }
                    searching = true
                    results = await app.searchAllMessages(needle)
                    searching = false
                }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
