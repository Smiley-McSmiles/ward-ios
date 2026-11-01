import SwiftUI
import PhotosUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.ward) private var palette
    @State private var search = ""
    @State private var showAdd = false
    @State private var showSecurity = false
    @State private var showXML = false
    @State private var showDisco = false

    private var filteredPages: [SettingsPageInfo] {
        let pages = SettingsSchema.pages.map { SettingsPageInfo(key: $0.key, title: $0.title) }
        guard !search.isEmpty else { return pages }
        return pages.filter { page in
            page.title.lowercased().contains(search.lowercased()) ||
            SettingsSchema.specs(page: page.key).contains { $0.title.lowercased().contains(search.lowercased()) }
        }
    }

    var body: some View {
        ZStack {
            WardBackground()
            ScrollView {
                VStack(spacing: 16) {
                    profile
                    accountsCard
                    pagesCard
                    quickLinks
                    footer
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 100)
            }
            .scrollIndicators(.hidden)
            .searchable(text: $search, prompt: "Search settings")
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd) { AddAccountSheet() }
        .sheet(isPresented: $showSecurity) { SecurityView() }
        .sheet(isPresented: $showXML) { XmlConsoleView() }
        .sheet(isPresented: $showDisco) { DiscoView() }
    }

    private var profile: some View {
        VStack(spacing: 10) {
            AvatarView(name: app.accounts.first?.displayName ?? "Ward",
                       jid: app.accounts.first?.jid ?? "", size: 72,
                       presence: app.states[app.accounts.first?.id ?? 0]?.state == "online" ? "online" : "offline",
                       imagePath: app.accounts.first?.avatar)
            Text(app.accounts.first?.displayName ?? "Ward").font(.title3.weight(.bold)).foregroundStyle(palette.text)
            Text(app.accounts.first?.jid ?? "").font(.caption).foregroundStyle(palette.secondaryText)
            HStack(spacing: 6) {
                ForEach(app.accounts) { account in
                    ConnectionPill(state: app.states[account.id] ?? ConnectionState())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(
            LinearGradient(colors: [palette.accent.opacity(0.16), palette.surface.opacity(0.9)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(palette.accent.opacity(0.18), lineWidth: 0.5))
    }

    private var accountsCard: some View {
        VStack(spacing: 0) {
            ForEach(app.accounts) { account in
                NavigationLink {
                    AccountSettingsPage(accountId: account.id)
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: account.displayName, jid: account.jid, size: 40,
                                   presence: app.states[account.id]?.state == "online" ? "online" : "offline",
                                   imagePath: account.avatar)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.displayName).font(.subheadline.weight(.medium)).foregroundStyle(palette.text)
                            Text(account.jid).font(.caption2).foregroundStyle(palette.secondaryText)
                        }
                        Spacer()
                        ConnectionPill(state: app.states[account.id] ?? ConnectionState())
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(palette.tertiaryText)
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                if account.id != app.accounts.last?.id { Divider().padding(.leading, 52) }
            }
            Divider().padding(.leading, 52)
            Button { showAdd = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(palette.accent).frame(width: 30)
                    Text("Add account").foregroundStyle(palette.text)
                    Spacer()
                }
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.outline.opacity(0.2), lineWidth: 0.5))
    }

    private var pagesCard: some View {
        VStack(spacing: 0) {
            ForEach(filteredPages) { page in
                NavigationLink {
                    SettingsPageView(pageKey: page.key, title: page.title)
                } label: {
                    HStack(spacing: 12) {
                        IconTile(icon: pageIcon(page.key), color: pageColor(page.key))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(page.title).foregroundStyle(palette.text)
                            if let subtitle = pageSubtitle(page.key) {
                                Text(subtitle).font(.caption).foregroundStyle(palette.secondaryText).lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(palette.tertiaryText)
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                if page.key != filteredPages.last?.key { Divider().padding(.leading, 52) }
            }
        }
        .padding(.horizontal, 14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.outline.opacity(0.2), lineWidth: 0.5))
    }

    private var quickLinks: some View {
        VStack(spacing: 0) {
            Button { showSecurity = true } label: {
                SettingsRow(icon: "faceid", iconColor: .blue, title: "App lock", subtitle: lock.enabled ? "Face ID and passcode" : "Off",
                            value: lock.enabled ? "On" : "Off")
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 52)
            Button { showXML = true } label: {
                SettingsRow(icon: "terminal.fill", iconColor: .black, title: "XML console", subtitle: "Raw stanzas and live log", value: "")
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 52)
            Button { showDisco = true } label: {
                SettingsRow(icon: "network", iconColor: .teal, title: "Service discovery", subtitle: "Browse server features", value: "")
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 52)
            NavigationLink { AboutPage() } label: {
                SettingsRow(icon: "info.circle.fill", iconColor: .gray, title: "About Ward", subtitle: "Version, source and license", value: "")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.outline.opacity(0.2), lineWidth: 0.5))
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Image("WardLogo").resizable().scaledToFit().frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text("Ward for iOS 1.0.6").font(.caption.weight(.medium)).foregroundStyle(palette.secondaryText)
            Text("Made for the open XMPP network").font(.caption2).foregroundStyle(palette.tertiaryText)
        }
        .padding(.top, 10)
    }

    private func pageSubtitle(_ key: String) -> String? {
        switch key {
        case "general": return "Background, updates and startup"
        case "appearance": return "Theme, accent, text and message layout"
        case "chats": return "Typing, receipts, reactions and writing"
        case "calls": return "Call signalling, relay and sounds (media pending)"
        case "attachments": return "Photos, files, downloads and voice"
        case "notifications": return "Alerts, badges and quiet hours"
        case "encryption": return "Encryption status, device trust and keys"
        case "privacy": return "Strangers and photo metadata"
        case "security": return "App lock and screen privacy"
        case "accounts": return "Presence, nickname and connection"
        case "storage": return "Media cache and local history"
        case "advanced": return "Connection, XML and maintenance"
        default: return nil
        }
    }

    private func pageIcon(_ key: String) -> String {
        switch key {
        case "general": return "gearshape.fill"
        case "appearance": return "paintbrush.fill"
        case "chats": return "bubble.left.and.bubble.right.fill"
        case "calls": return "phone.fill"
        case "attachments": return "paperclip"
        case "notifications": return "bell.fill"
        case "encryption": return "lock.shield.fill"
        case "privacy": return "hand.raised.fill"
        case "security": return "shield.lefthalf.filled"
        case "accounts": return "person.crop.circle"
        case "storage": return "externaldrive.fill"
        case "advanced": return "wrench.and.screwdriver.fill"
        default: return "gearshape"
        }
    }

    private func pageColor(_ key: String) -> Color {
        switch key {
        case "general": return .gray
        case "appearance": return .pink
        case "chats": return .blue
        case "calls": return .green
        case "attachments": return .orange
        case "notifications": return .red
        case "encryption": return .indigo
        case "privacy": return .teal
        case "security": return .purple
        case "accounts": return .cyan
        case "storage": return .brown
        case "advanced": return WardAccent.slate.color
        default: return .gray
        }
    }
}

// MARK: - Generated settings page

struct SettingsPageInfo: Identifiable {
    let key: String
    let title: String
    var id: String { key }
}

struct SettingsPageView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.ward) private var palette
    var pageKey: String
    var title: String
    @State private var editingSpec: SettingSpec? = nil
    @State private var editingValue = ""

    private var specs: [SettingSpec] { SettingsSchema.specs(page: pageKey) }
    private var groups: [String] {
        var seen: [String] = []
        for spec in specs where !seen.contains(spec.group) { seen.append(spec.group) }
        return seen
    }

    var body: some View {
        ZStack {
            WardBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pageIntro
                    if pageKey != "security" {
                    ForEach(groups, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 7) {
                            SectionHeader(title: group)
                            VStack(spacing: 0) {
                                let items = specs.filter { $0.group == group }
                                ForEach(items) { spec in
                                    SettingRowView(spec: spec, value: settings.string(spec.key, spec.defaultValue),
                                                   onEditText: {
                                                       editingSpec = spec
                                                       editingValue = settings.string(spec.key, spec.defaultValue)
                                                   })
                                    if spec.id != items.last?.id { Divider().padding(.leading, 2) }
                                }
                            }
                            .padding(.horizontal, 14)
                            .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(palette.outline.opacity(0.2), lineWidth: 0.5))
                        }
                    }
                    }
                    if pageKey == "encryption" {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(palette.warning)
                            Text("OMEMO and OpenPGP message encryption are not wired in this release. Explicitly encrypted chats are blocked rather than sent in plaintext.")
                                .font(.caption).foregroundStyle(palette.secondaryText)
                        }
                        .padding(12)
                        .background(palette.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    if pageKey == "accounts" { accountsLinks }
                    if pageKey == "advanced" { advancedActions }
                    if pageKey == "security" { SecurityEmbedded() }
                    if pageKey == "storage" { StorageEmbedded() }
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingSpec) { spec in
            TextSettingSheet(spec: spec, value: editingValue) { value in
                settings.set(spec.key, value)
            }
        }
    }

    @ViewBuilder private var pageIntro: some View {
        if let subtitle = pageSubtitle {
            HStack(spacing: 10) {
                Image(systemName: pageIcon)
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(palette.accent)
                    .frame(width: 34, height: 34).background(palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(subtitle).font(.footnote).foregroundStyle(palette.secondaryText)
            }
            .padding(.vertical, 2)
        }
    }

    private var pageSubtitle: String? {
        switch pageKey {
        case "general": return "How Ward behaves when it is not on screen."
        case "appearance": return "Make Ward feel like yours. Changes apply immediately."
        case "chats": return "Writing, reactions, receipts and typing indicators."
        case "calls": return "Call signalling and relay settings. Audio/video media is not available yet."
        case "attachments": return "How media is sent and downloaded."
        case "notifications": return "When and how Ward gets your attention."
        case "encryption": return "Message encryption status, device trust and key maintenance."
        case "privacy": return "Control who can reach you and what photos reveal."
        case "security": return "Protect the app and the screen."
        case "storage": return "Clear local data and free up space."
        case "advanced": return "Connection tuning and developer tools."
        case "accounts": return "Manage the accounts on this device."
        default: return nil
        }
    }

    private var pageIcon: String {
        switch pageKey {
        case "general": return "gearshape.fill"
        case "appearance": return "paintbrush.fill"
        case "chats": return "bubble.left.fill"
        case "calls": return "phone.fill"
        case "attachments": return "paperclip"
        case "notifications": return "bell.fill"
        case "encryption": return "lock.shield.fill"
        case "privacy": return "hand.raised.fill"
        case "security": return "shield.lefthalf.filled"
        case "storage": return "externaldrive.fill"
        case "advanced": return "wrench.and.screwdriver.fill"
        default: return "gearshape"
        }
    }

    private var accountsLinks: some View {
        VStack(spacing: 0) {
            ForEach(app.accounts) { account in
                NavigationLink { AccountSettingsPage(accountId: account.id) } label: {
                    SettingsRow(icon: "person.crop.circle.fill", iconColor: .cyan, title: account.displayName,
                                subtitle: account.jid, value: app.states[account.id]?.label ?? "Offline")
                }
                .buttonStyle(.plain)
                if account.id != app.accounts.last?.id { Divider().padding(.leading, 52) }
            }
        }
        .padding(.horizontal, 14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var advancedActions: some View {
        VStack(spacing: 0) {
            NavigationLink { XmlConsoleView() } label: {
                SettingsRow(icon: "terminal.fill", iconColor: .black, title: "XML console", subtitle: "See and send raw stanzas", value: "")
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 52)
            NavigationLink { DiscoView() } label: {
                SettingsRow(icon: "network", iconColor: .teal, title: "Service discovery", subtitle: "Browse server features", value: "")
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 52)
            Button {
                Task {
                    let result = await app.resyncHistory()
                    app.showToast(result)
                }
            } label: {
                SettingsRow(icon: "arrow.triangle.2.circlepath", iconColor: .blue, title: "Re-sync history", subtitle: "Fetch missing messages from the server", value: "", chevron: false)
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 52)
            Button {
                Task { app.showToast(await app.cleanUpKeys()) }
            } label: {
                SettingsRow(icon: "key.slash.fill", iconColor: .orange, title: "Clean up device lists", subtitle: "Remove cached keys for other devices", value: "", chevron: false)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct SettingRowView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.ward) private var palette
    var spec: SettingSpec
    var value: String
    var onEditText: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch spec.kind {
            case .bool:
                Toggle(isOn: Binding(get: { value == "true" }, set: { settings.set(spec.key, $0 ? "true" : "false"); Haptics.selection() })) {
                    labels
                }
                .tint(palette.accent)
                .padding(.vertical, 6)
            case .choice:
                Menu {
                    ForEach(spec.choices) { choice in
                        Button {
                            settings.set(spec.key, choice.value)
                            Haptics.selection()
                        } label: {
                            if choice.value == value { Label(choice.label, systemImage: "checkmark") }
                            else { Text(choice.label) }
                        }
                    }
                } label: {
                    HStack {
                        labels
                        Spacer()
                        Text(spec.choices.first { $0.value == value }?.label ?? value)
                            .font(.caption).foregroundStyle(palette.secondaryText)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(palette.tertiaryText)
                    }
                    .padding(.vertical, 8)
                }
            case .int:
                VStack(spacing: 8) {
                    HStack {
                        labels
                        Spacer()
                        Text("\(value)\(spec.unit)")
                            .font(.caption.monospacedDigit()).foregroundStyle(palette.secondaryText)
                            .contentTransition(.numericText())
                    }
                    Slider(value: Binding(get: { Double(Int(value) ?? 0) },
                                          set: { settings.set(spec.key, String(Int($0))) }),
                           in: Double(spec.min ?? 0)...Double(spec.max ?? 100),
                           step: Double(spec.step))
                        .tint(palette.accent)
                }
                .padding(.vertical, 7)
            case .text, .list, .timeRange:
                Button(action: onEditText) {
                    HStack {
                        labels
                        Spacer()
                        Text(value.isEmpty ? "Not set" : (spec.kind == .list ? "\(value.components(separatedBy: "\n").filter { !$0.isEmpty }.count) items" : value))
                            .font(.caption).foregroundStyle(palette.secondaryText).lineLimit(1)
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(palette.tertiaryText)
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(spec.title).font(.subheadline).foregroundStyle(palette.text)
            if !spec.subtitle.isEmpty {
                Text(spec.subtitle).font(.caption2).foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct TextSettingSheet: View {
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    var spec: SettingSpec
    @State var value: String
    var onSave: (String) -> Void

    init(spec: SettingSpec, value: String, onSave: @escaping (String) -> Void) {
        self.spec = spec
        self._value = State(initialValue: value)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if spec.kind == .list {
                        TextEditor(text: $value).frame(minHeight: 160)
                    } else {
                        TextField(spec.title, text: $value)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    if !spec.subtitle.isEmpty { Text(spec.subtitle) }
                }
            }
            .navigationTitle(spec.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { onSave(value); dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
