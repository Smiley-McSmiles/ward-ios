import SwiftUI
import PhotosUI

struct AccountSettingsPage: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    var accountId: Int64

    @State private var nickname = ""
    @State private var host = ""
    @State private var port = ""
    @State private var tls = "auto"
    @State private var photo: PhotosPickerItem?
    @State private var showRemove = false
    @State private var showServerDelete = false
    @State private var showPasswordInfo = false

    private var account: Account? { app.account(id: accountId) }
    private var state: ConnectionState { app.states[accountId] ?? ConnectionState() }

    var body: some View {
        ZStack {
            WardBackground()
            if let account {
                ScrollView {
                    VStack(spacing: 18) {
                        avatarSection(account)
                        identityCard(account)
                        connectionCard(account)
                        actionsCard(account)
                        removeCard(account)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
                }
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let account {
                nickname = account.nickname
                host = account.options["host"] ?? ""
                port = account.options["port"] ?? ""
                tls = account.options["tls"] ?? "auto"
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    app.publishAvatar(accountId: accountId, data: data)
                }
            }
        }
        .alert("Password changes", isPresented: $showPasswordInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Password changes are handled by your server. Change the password in your provider's account page, then add the account again here.")
        }
        .confirmationDialog("Remove this account?", isPresented: $showRemove, titleVisibility: .visible) {
            Button("Remove locally", role: .destructive) {
                if let account { Task { await app.deleteAccount(account); dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Local history, media and encryption state for this account will be deleted from this device. Your account on the server is not changed.")
        }
        .confirmationDialog("Delete the account on the server?", isPresented: $showServerDelete, titleVisibility: .visible) {
            Button("Delete account everywhere", role: .destructive) {
                if let account {
                    Task {
                        if await app.deleteAccountOnServer(account) { dismiss() }
                        else { app.showToast("The server did not allow account deletion. Remove it locally or contact your server administrator.", error: true) }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This asks the XMPP server to delete the account, then removes local history and keys. This cannot be undone.")
        }
    }

    private func avatarSection(_ account: Account) -> some View {
        VStack(spacing: 10) {
            PhotosPicker(selection: $photo, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(name: account.displayName, jid: account.jid, size: 84, imagePath: account.avatar)
                    Image(systemName: "camera.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(palette.accent, in: Circle())
                        .overlay(Circle().strokeBorder(palette.background, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            }
            Text(account.displayName).font(.title3.weight(.bold)).foregroundStyle(palette.text)
            Text(account.jid).font(.caption).foregroundStyle(palette.secondaryText)
            ConnectionPill(state: state)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func identityCard(_ account: Account) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(icon: "person.text.rectangle.fill", color: .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Display name").font(.subheadline)
                    Text("Shown to your contacts").font(.caption2).foregroundStyle(palette.secondaryText)
                }
                Spacer()
                TextField("Name", text: $nickname)
                    .multilineTextAlignment(.trailing)
                    .font(.subheadline)
                    .onSubmit { saveNickname(account) }
            }
            .padding(.vertical, 11)
            Divider().padding(.leading, 52)
            Menu {
                ForEach(Array([("online", "Online"), ("away", "Away"), ("dnd", "Do not disturb"), ("xa", "Away for a while")].enumerated()), id: \.offset) { _, item in
                    Button(item.1) { app.setPresence(item.0) }
                }
            } label: {
                HStack(spacing: 12) {
                    IconTile(icon: "circle.circle.fill", color: .green)
                    Text("Presence").font(.subheadline)
                    Spacer()
                    Text(state.state == "online" ? "Available" : "Offline").font(.caption).foregroundStyle(palette.secondaryText)
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(palette.tertiaryText)
                }
                .padding(.vertical, 11)
            }
            Divider().padding(.leading, 52)
            HStack(spacing: 12) {
                IconTile(icon: "shield.lefthalf.filled", color: .indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Server administrator").font(.subheadline)
                    Text("Show the server admin tab and commands").font(.caption2).foregroundStyle(palette.secondaryText)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { account.isAdmin }, set: { value in
                    Task {
                        var updated = account
                        updated.isAdmin = value
                        await app.updateAccount(updated)
                        if value { await app.loadCommands() }
                    }
                }))
                .labelsHidden()
                .tint(palette.accent)
            }
            .padding(.vertical, 9)
        }
        .padding(.horizontal, 14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func connectionCard(_ account: Account) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(icon: "server.rack", color: .teal)
                Text("Host").font(.subheadline)
                Spacer()
                TextField("Automatic", text: $host)
                    .multilineTextAlignment(.trailing).font(.subheadline)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { saveConnection(account) }
            }
            .padding(.vertical, 11)
            Divider().padding(.leading, 52)
            HStack(spacing: 12) {
                IconTile(icon: "number", color: .orange)
                Text("Port").font(.subheadline)
                Spacer()
                TextField("Automatic", text: $port)
                    .multilineTextAlignment(.trailing).font(.subheadline).keyboardType(.numberPad)
                    .onSubmit { saveConnection(account) }
            }
            .padding(.vertical, 11)
            Divider().padding(.leading, 52)
            Menu {
                Button("Automatic") { tls = "auto"; saveConnection(account) }
                Button("Require STARTTLS") { tls = "starttls"; saveConnection(account) }
            } label: {
                HStack(spacing: 12) {
                    IconTile(icon: "lock.fill", color: .green)
                    Text("Transport security").font(.subheadline)
                    Spacer()
                    Text(tls == "starttls" ? "STARTTLS" : "Automatic").font(.caption).foregroundStyle(palette.secondaryText)
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(palette.tertiaryText)
                }
                .padding(.vertical, 11)
            }
            Divider().padding(.leading, 52)
            if let pin = TLSPins.stored(host: account.domain) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 12) {
                        IconTile(icon: "checkmark.shield.fill", color: .green)
                        Text("Pinned certificate").font(.subheadline)
                        Spacer()
                        Button("Forget") {
                            TLSPins.clear(host: account.domain)
                            app.showToast("Certificate pin forgotten. Reconnect to trust it again.")
                        }
                        .font(.caption).foregroundStyle(palette.danger)
                    }
                    Text(WardFormat.fingerprint(pin))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(palette.secondaryText)
                        .textSelection(.enabled)
                        .padding(.leading, 44)
                }
                .padding(.vertical, 9)
                Divider().padding(.leading, 52)
            }
            HStack(spacing: 12) {
                IconTile(icon: "wifi", color: state.state == "online" ? .green : .gray)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.label).font(.subheadline)
                    if !state.error.isEmpty {
                        Text(state.error).font(.caption2).foregroundStyle(palette.danger)
                    }
                }
                Spacer()
                Button(state.state == "online" ? "Disconnect" : "Connect") {
                    if state.state == "online" { app.disconnect(account) } else { app.connect(account) }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .tint(state.state == "online" ? palette.danger : palette.accent)
            }
            .padding(.vertical, 9)
        }
        .padding(.horizontal, 14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func actionsCard(_ account: Account) -> some View {
        VStack(spacing: 0) {
            Button {
                Task { app.showToast(await app.resyncHistory(accountId: account.id)) }
            } label: {
                SettingsRow(icon: "arrow.triangle.2.circlepath", iconColor: .blue, title: "Re-sync history", subtitle: "Fetch messages from the server archive", value: "", chevron: false)
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 52)
            Button { showPasswordInfo = true } label: {
                SettingsRow(icon: "key.fill", iconColor: .orange, title: "Password", subtitle: "Managed by your server", value: "", chevron: false)
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 52)
            Button {
                Task { app.showToast(await app.cleanUpKeys()) }
            } label: {
                SettingsRow(icon: "lock.rotation", iconColor: .purple, title: "Encryption maintenance", subtitle: "Trim cached device lists", value: "", chevron: false)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func removeCard(_ account: Account) -> some View {
        VStack(spacing: 8) {
            Button { showRemove = true } label: {
                HStack {
                    Image(systemName: "iphone.slash").foregroundStyle(palette.danger)
                    Text("Remove from this device").foregroundStyle(palette.danger)
                    Spacer()
                }
                .padding(15)
                .background(palette.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(palette.danger.opacity(0.18), lineWidth: 0.5))
            }
            .buttonStyle(PressableStyle())
            Button { showServerDelete = true } label: {
                HStack {
                    Image(systemName: "trash.fill").foregroundStyle(palette.danger)
                    Text("Delete account on server").foregroundStyle(palette.danger)
                    Spacer()
                }
                .padding(15)
                .background(palette.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(palette.danger.opacity(0.18), lineWidth: 0.5))
            }
            .buttonStyle(PressableStyle())
        }
    }

    private func saveNickname(_ account: Account) {
        var updated = account
        updated.nickname = nickname
        Task { await app.updateAccount(updated) }
    }

    private func saveConnection(_ account: Account) {
        Task {
            await app.setAccountOption(account, key: "host", value: host)
            await app.setAccountOption(account, key: "port", value: port)
            await app.setAccountOption(account, key: "tls", value: tls)
            let fresh = app.account(id: account.id)
            if let fresh { app.disconnect(fresh); app.connect(fresh) }
        }
    }
}

// MARK: - Security

struct SecurityView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var showPasscode = false
    @State private var showRemovePasscode = false

    var body: some View {
        NavigationStack {
            SecurityEmbedded()
                .navigationTitle("App lock")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
                .sheet(isPresented: $showPasscode) { SetPasscodeSheet() }
                .confirmationDialog("Remove your passcode?", isPresented: $showRemovePasscode, titleVisibility: .visible) {
                    Button("Remove passcode and turn off app lock", role: .destructive) {
                        lock.clearPasscode()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Ward will no longer ask for a passcode when it opens.")
                }
        }
    }
}

struct SecurityEmbedded: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.ward) private var palette
    @State private var showPasscode = false
    @State private var showRemovePasscode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader(title: "App lock", subtitle: "Require Face ID or a passcode when Ward opens")
            VStack(spacing: 0) {
                Toggle(isOn: Binding(get: { lock.enabled }, set: { value in
                    if value {
                        if lock.hasPasscode { lock.setEnabled(true); lock.authenticate() }
                        else { showPasscode = true }
                    } else {
                        lock.setEnabled(false)
                    }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lock Ward").font(.subheadline)
                        Text("Face ID is used when available").font(.caption2).foregroundStyle(palette.secondaryText)
                    }
                }
                .tint(palette.accent)
                .padding(.vertical, 8)
                if lock.enabled {
                    Divider()
                    Toggle(isOn: Binding(get: { lock.useBiometrics }, set: { lock.useBiometrics = $0 })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Unlock with \(lock.biometricName)").font(.subheadline)
                            Text(lock.biometricAvailable ? "Biometrics are available on this device" : "Not available on this device")
                                .font(.caption2).foregroundStyle(palette.secondaryText)
                        }
                    }
                    .tint(palette.accent)
                    .padding(.vertical, 8)
                    .disabled(!lock.biometricAvailable)
                    Divider()
                    HStack {
                        Text("Lock after").font(.subheadline)
                        Spacer()
                        Picker("Lock after", selection: Binding(get: { lock.delay }, set: { lock.delay = $0 })) {
                            Text("Immediately").tag(0)
                            Text("1 minute").tag(60)
                            Text("5 minutes").tag(300)
                            Text("15 minutes").tag(900)
                        }
                        .pickerStyle(.menu)
                        .tint(palette.accent)
                    }
                    .padding(.vertical, 9)
                    Divider()
                    Button { showPasscode = true } label: {
                        HStack {
                            Text("Change passcode").font(.subheadline).foregroundStyle(palette.text)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(palette.tertiaryText)
                        }
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    Divider()
                    Button { showRemovePasscode = true } label: {
                        HStack {
                            Text("Remove passcode").font(.subheadline).foregroundStyle(palette.danger)
                            Spacer()
                        }
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            SectionHeader(title: "Screen privacy")
            VStack(spacing: 0) {
                Toggle(isOn: Binding(get: { settings.bool("security.block_screenshots") },
                                     set: { settings.setBool("security.block_screenshots", $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Block screenshots and recording").font(.subheadline)
                        Text("Hide Ward in the app switcher and warn when the screen is captured")
                            .font(.caption2).foregroundStyle(palette.secondaryText)
                    }
                }
                .tint(palette.accent)
                .padding(.vertical, 9)
            }
            .padding(.horizontal, 14)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .sheet(isPresented: $showPasscode) {
            SetPasscodeSheet { lock.setEnabled(true) }
        }
        .confirmationDialog("Remove your passcode?", isPresented: $showRemovePasscode, titleVisibility: .visible) {
            Button("Remove passcode and turn off app lock", role: .destructive) { lock.clearPasscode() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct SetPasscodeSheet: View {
    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    var onSaved: (() -> Void)? = nil
    @State private var first = ""
    @State private var second = ""
    @State private var error = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44)).foregroundStyle(palette.accent)
                    .padding(.top, 20)
                Text("Choose a passcode").font(.title3.weight(.bold))
                Text("Use at least four digits. You can still unlock with \(lock.biometricName) when it is available.")
                    .font(.subheadline).foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center).padding(.horizontal, 20)
                SecureField("Passcode", text: $first)
                    .keyboardType(.numberPad).textContentType(.newPassword)
                    .padding(13).background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                SecureField("Confirm passcode", text: $second)
                    .keyboardType(.numberPad).textContentType(.newPassword)
                    .padding(13).background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(palette.danger) }
                Button("Save passcode") {
                    guard first.count == 4 else { error = "Use exactly four digits."; return }
                    guard first == second else { error = "The passcodes do not match."; return }
                    lock.setPasscode(first)
                    onSaved?()
                    lock.authenticate()
                    dismiss()
                }
                .buttonStyle(WardPrimaryButtonStyle())
                Spacer()
            }
            .padding(.horizontal, 24)
            .navigationTitle("App lock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
    }
}

// MARK: - Storage

struct StorageEmbedded: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.ward) private var palette
    @State private var cacheSize: Int64 = 0
    @State private var showClear = false
    @State private var showClearMedia = false
    @State private var showWipe = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader(title: "Local data")
            VStack(spacing: 0) {
                HStack {
                    IconTile(icon: "photo.stack.fill", color: .orange)
                    Text("Media cache").font(.subheadline)
                    Spacer()
                    Text(WardFormat.bytes(cacheSize)).font(.caption).foregroundStyle(palette.secondaryText)
                }
                .padding(.vertical, 10)
                Divider().padding(.leading, 52)
                Button { showClearMedia = true } label: {
                    SettingsRow(icon: "trash.fill", iconColor: .red, title: "Clear downloaded media", subtitle: "Photos and files can be downloaded again", value: "", chevron: false)
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 52)
                Button { showClear = true } label: {
                    SettingsRow(icon: "bubble.left.and.exclamationmark.bubble.right.fill", iconColor: .orange, title: "Clear all messages", subtitle: "Keep chats but delete their local history", value: "", chevron: false)
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 52)
                Button { showWipe = true } label: {
                    SettingsRow(icon: "key.slash.fill", iconColor: .purple, title: "Wipe history and keys", subtitle: "Reset local encryption state", value: "", chevron: false)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .task { cacheSize = AttachmentStore.shared.cacheSize() }
        .confirmationDialog("Clear all messages?", isPresented: $showClear, titleVisibility: .visible) {
            Button("Clear all messages", role: .destructive) {
                Task {
                    if let database = app.database { try? await database.clearAllMessages() }
                    for id in app.chats.map(\.id) { await app.loadMessages(chatId: id) }
                    app.showToast("Message history cleared.")
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Clear downloaded media?", isPresented: $showClearMedia, titleVisibility: .visible) {
            Button("Clear media", role: .destructive) {
                AttachmentStore.shared.deleteAll()
                cacheSize = 0
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Wipe local history and encryption?", isPresented: $showWipe, titleVisibility: .visible) {
            Button("Wipe everything", role: .destructive) {
                Task { await app.wipeEncryptionAndHistory(); app.showToast("Local history and keys wiped.") }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - About

struct AboutPage: View {
    @Environment(\.ward) private var palette
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image("WardLogo").resizable().scaledToFit().frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                Text("Ward").font(.title.weight(.bold))
                Text("Private messaging on the open XMPP network.").font(.subheadline).foregroundStyle(palette.secondaryText)
                Text("Version 1.0.6 (iOS)").font(.caption).foregroundStyle(palette.tertiaryText)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Ward is a native SwiftUI messenger built on the same protocols as Ward for GTK and Ward for Android. It speaks XMPP, encrypts one-to-one chats with its own MIT-licensed OMEMO 2 implementation, and never routes your messages through a Ward server.")
                        .font(.subheadline).foregroundStyle(palette.secondaryText)
                    Divider()
                    Link("Source code", destination: URL(string: "https://github.com/Smiley-McSmiles/Ward-Android")!)
                    Link("Report an issue", destination: URL(string: "https://github.com/Smiley-McSmiles/Ward-Android/issues")!)
                    Link("Privacy policy", destination: URL(string: "https://smiley-mcsmiles.github.io/ward-ios/privacy.html")!)
                    Link("The XMPP Standards Foundation", destination: URL(string: "https://xmpp.org")!)
                    NavigationLink("Support Ward", destination: DonatePage())
                }
                .padding(16)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("MIT licensed. The Ward icon is Ward's icon.")
                    .font(.caption2).foregroundStyle(palette.tertiaryText)
            }
            .padding(20)
        }
        .background(WardBackground())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DonatePage: View {
    @Environment(\.ward) private var palette
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "heart.fill").font(.system(size: 44)).foregroundStyle(palette.pink)
                Text("Keep Ward independent").font(.title3.weight(.bold))
                Text("Ward is built without ads, tracking or a subscription. If it is useful to you, you can support the project.")
                    .font(.subheadline).foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                Link(destination: URL(string: "https://github.com/sponsors/Smiley-McSmiles")!) {
                    HStack {
                        Image(systemName: "heart.circle.fill")
                        Text("GitHub Sponsors")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .padding(14)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .foregroundStyle(palette.text)
            }
            .padding(24)
        }
        .background(WardBackground())
        .navigationTitle("Support Ward")
        .navigationBarTitleDisplayMode(.inline)
    }
}
