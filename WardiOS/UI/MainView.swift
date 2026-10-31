import SwiftUI

struct MainView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var tab: AppTab = .chats
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
                } detail: {
                    NavigationStack {
                        content
                            .navigationTitle(tab.title)
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    .tint(settings.accentColor)
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                TabView(selection: $tab) {
                    ForEach(AppTab.allCases) { item in
                        NavigationStack {
                            content(for: item)
                        }
                        .tabItem { Label(item.title, systemImage: item.icon) }
                        .tag(item)
                    }
                }
                .tint(settings.accentColor)
            }
        }
        .background(WardBackground())
        .onReceive(NotificationCenter.default.publisher(for: .wardOpenChat)) { _ in
            withAnimation(.snappy) { tab = .chats }
        }
    }

    @ViewBuilder private var content: some View {
        content(for: tab)
    }

    @ViewBuilder private func content(for item: AppTab) -> some View {
        switch item {
        case .chats: ChatsView()
        case .contacts: ContactsView()
        case .server: ServerView()
        case .settings: SettingsView()
        }
    }

    private var sidebar: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image("WardLogo").resizable().scaledToFit().frame(width: 42, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Ward").font(.headline)
                            Text(accountSummary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ConnectionSummary()
                }
                .padding(.vertical, 4)
            }
            Section {
                ForEach(AppTab.allCases) { item in
                    Button {
                        withAnimation(.snappy) { tab = item }
                    } label: {
                        Label {
                            HStack {
                                Text(item.title)
                                Spacer()
                                if item == .chats, totalUnread > 0 {
                                    Text("\(totalUnread)")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(settings.accentColor, in: Capsule())
                                        .foregroundStyle(.white)
                                }
                            }
                        } icon: {
                            Image(systemName: item.icon)
                        }
                        .font(.body.weight(tab == item ? .semibold : .regular))
                        .foregroundStyle(tab == item ? settings.accentColor : .primary)
                    }
                    .listRowBackground(tab == item ? settings.accentColor.opacity(0.12) : Color.clear)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(WardBackground())
    }

    private var accountSummary: String {
        if app.accounts.count == 1 { return app.accounts[0].jid }
        return "\(app.accounts.count) accounts"
    }
    private var totalUnread: Int { app.chats.filter { !$0.archived }.reduce(0) { $0 + $1.unread } }
}

private struct ConnectionSummary: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    var body: some View {
        HStack(spacing: 6) {
            ForEach(app.accounts) { account in
                HStack(spacing: 4) {
                    Circle()
                        .fill(color(app.states[account.id]))
                        .frame(width: 6, height: 6)
                    Text(JID.local(account.jid)).font(.caption2).foregroundStyle(palette.secondaryText)
                }
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(palette.surfaceContainer, in: Capsule())
            }
        }
    }
    private func color(_ state: ConnectionState?) -> Color {
        switch state?.state {
        case "online": return palette.success
        case "connecting": return palette.warning
        case "error": return palette.danger
        default: return palette.tertiaryText
        }
    }
}

// MARK: - Chats

struct ChatsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @State private var search = ""
    @State private var accountFilter: Int64? = nil
    @State private var showNewChat = false
    @State private var showArchived = false
    @State private var showRequests = false
    @State private var showProfile = false
    @State private var showGlobalSearch = false
    @State private var pendingDelete: Chat? = nil
    @State private var refreshing = false

    private var filtered: [Chat] {
        app.chats.filter { chat in
            guard !chat.archived else { return false }
            if let accountFilter, chat.accountId != accountFilter { return false }
            if !search.isEmpty {
                let needle = search.lowercased()
                return chat.displayName.lowercased().contains(needle)
                    || chat.preview.lowercased().contains(needle)
                    || chat.jid.lowercased().contains(needle)
            }
            return true
        }
    }
    private var archivedCount: Int { app.chats.filter { $0.archived }.count }
    private var requestChats: [Chat] { app.chats.filter { $0.isRequest && !$0.archived } }

    var body: some View {
        ZStack {
            WardBackground()
            List {
                header
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                if !app.requests.isEmpty || !requestChats.isEmpty {
                    requestsRow
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 4, trailing: 16))
                }
                if !refreshing && filtered.isEmpty && search.isEmpty && accountFilter == nil {
                    EmptyStateView(icon: "bubble.left.and.bubble.right",
                                   title: "No conversations yet",
                                   subtitle: "Start a chat with a contact, join a group, or wait for someone to write to you.",
                                   action: { showNewChat = true }, actionTitle: "New chat")
                        .frame(minHeight: 380)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(filtered) { chat in
                        ChatRow(chat: chat,
                                contact: app.contact(jid: chat.jid, accountId: chat.accountId),
                                typing: app.typing[chat.id],
                                account: app.account(id: chat.accountId))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Haptics.selection()
                                app.selectChat(chat.id)
                            }
                            .contextMenu { menu(for: chat) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { pendingDelete = chat } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button { Task { await app.setArchived(chat, true) } } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                .tint(.indigo)
                            }
                            .swipeActions(edge: .leading) {
                                Button { Task { await app.setPinned(chat, !chat.pinned) } } label: {
                                    Label(chat.pinned ? "Unpin" : "Pin", systemImage: chat.pinned ? "pin.slash" : "pin")
                                }
                                .tint(.orange)
                                Button { Task { await app.setMuted(chat, chat.isMuted ? 0 : Date().addingTimeInterval(86400).millis) } } label: {
                                    Label(chat.isMuted ? "Unmute" : "Mute", systemImage: chat.isMuted ? "bell" : "bell.slash")
                                }
                                .tint(.gray)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .opacity.combined(with: .scale(scale: 0.96))))
                    }
                }
                if archivedCount > 0 && search.isEmpty {
                    Button { showArchived = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "archivebox.fill").foregroundStyle(palette.accent)
                            Text("Archived").foregroundStyle(palette.text)
                            Spacer()
                            Text("\(archivedCount)").foregroundStyle(palette.secondaryText)
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(palette.tertiaryText)
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
                Color.clear
                    .frame(height: 70)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .refreshable { await refresh() }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search chats")
            .animation(.snappy(duration: 0.3), value: filtered.map(\.id))
        }
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showProfile = true } label: {
                    AvatarView(name: app.accounts.first?.displayName ?? "Ward",
                               jid: app.accounts.first?.jid ?? "", size: 30,
                               presence: app.states[app.accounts.first?.id ?? 0]?.state == "online" ? "online" : "offline",
                               imagePath: app.accounts.first?.avatar)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if app.accounts.count > 1 {
                        Picker("Account", selection: $accountFilter) {
                            Text("All accounts").tag(Int64?.none)
                            ForEach(app.accounts) { account in
                                Text(account.jid).tag(Int64?.some(account.id))
                            }
                        }
                    }
                    Divider()
                    Button { showNewChat = true } label: { Label("New chat", systemImage: "square.and.pencil") }
                    Button { showGlobalSearch = true } label: { Label("Search messages", systemImage: "text.magnifyingglass") }
                    Button { Task { await app.markAllRead() } } label: { Label("Mark all read", systemImage: "checkmark.circle") }
                    Button { showArchived = true } label: { Label("Archived", systemImage: "archivebox") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewChat = true } label: {
                    Image(systemName: "square.and.pencil")
                        .symbolEffect(.bounce, value: showNewChat)
                }
            }
        }
        .navigationDestination(item: Binding(get: { app.selectedChatId }, set: { app.selectChat($0) })) { id in
            ChatView(chatId: id)
        }
        .sheet(isPresented: $showNewChat) {
            NewChatSheet()
        }
        .sheet(isPresented: $showArchived) {
            ArchivedChatsView()
        }
        .sheet(isPresented: $showRequests) {
            RequestsView()
        }
        .sheet(isPresented: $showProfile) {
            ProfileSheet()
        }
        .sheet(isPresented: $showGlobalSearch) {
            GlobalSearchView()
        }
        .confirmationDialog("Delete this chat?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete for me", role: .destructive) {
                if let chat = pendingDelete { Task { await app.deleteChat(chat) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The conversation will be removed from this device. Other people keep their copy.")
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(greeting).font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.text)
                    HStack(spacing: 6) {
                        ForEach(app.accounts) { account in
                            ConnectionPill(state: app.states[account.id] ?? ConnectionState())
                        }
                    }
                }
                Spacer()
                if totalUnread > 0 {
                    VStack(spacing: 1) {
                        Text("\(totalUnread)").font(.title3.weight(.bold))
                        Text("unread").font(.caption2)
                    }
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(title: "All", count: filtered.count, selected: accountFilter == nil && !showRequests) {
                        accountFilter = nil; showRequests = false
                    }
                    ForEach(app.accounts) { account in
                        FilterChip(title: JID.local(account.jid), count: app.chats.filter { $0.accountId == account.id && !$0.archived }.count,
                                   selected: accountFilter == account.id) {
                            accountFilter = account.id
                        }
                    }
                    if !app.requests.isEmpty {
                        FilterChip(title: "Requests", count: app.requests.count, selected: showRequests,
                                   icon: "person.crop.circle.badge.questionmark") { showRequests = true }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 10)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 5 { return "Good night" }
        if hour < 12 { return "Good morning" }
        if hour < 18 { return "Good afternoon" }
        return "Good evening"
    }

    private var totalUnread: Int { app.chats.filter { !$0.archived }.reduce(0) { $0 + $1.unread } }

    private var requestsRow: some View {
        Button { showRequests = true } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(palette.warning.opacity(0.16)).frame(width: 44, height: 44)
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .foregroundStyle(palette.warning).font(.system(size: 20, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Message requests").font(.subheadline.weight(.semibold)).foregroundStyle(palette.text)
                    Text("\(app.requests.count) waiting for you").font(.caption).foregroundStyle(palette.secondaryText)
                }
                Spacer()
                Text("\(app.requests.count)").font(.caption.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(palette.warning, in: Capsule())
            }
            .padding(12)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(palette.warning.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(PressableStyle())
    }

    @ViewBuilder private func menu(for chat: Chat) -> some View {
        Button { app.selectChat(chat.id) } label: { Label("Open", systemImage: "bubble.left") }
        Button { Task { await app.setPinned(chat, !chat.pinned) } } label: {
            Label(chat.pinned ? "Unpin" : "Pin", systemImage: chat.pinned ? "pin.slash" : "pin")
        }
        Button {
            Task { await app.setMuted(chat, chat.isMuted ? 0 : Date().addingTimeInterval(86400).millis) }
        } label: {
            Label(chat.isMuted ? "Unmute" : "Mute for a day", systemImage: chat.isMuted ? "bell" : "bell.slash")
        }
        Button { Task { await app.setArchived(chat, true) } } label: { Label("Archive", systemImage: "archivebox") }
        Divider()
        Button(role: .destructive) { pendingDelete = chat } label: { Label("Delete", systemImage: "trash") }
    }

    private func refresh() async {
        refreshing = true
        for account in app.accounts {
            _ = await app.resyncHistory(accountId: account.id)
        }
        refreshing = false
        app.showToast("History re-synced.")
    }
}

struct FilterChip: View {
    @Environment(\.ward) private var palette
    var title: String
    var count: Int? = nil
    var selected: Bool
    var icon: String? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.caption2) }
                Text(title)
                if let count {
                    Text("\(count)").font(.caption2.weight(.semibold)).opacity(0.7)
                        .contentTransition(.numericText())
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(selected ? palette.onAccent : palette.secondaryText)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(selected ? palette.accent : palette.surfaceContainer, in: Capsule())
            .overlay(Capsule().strokeBorder(palette.outline.opacity(selected ? 0 : 0.35), lineWidth: 0.5))
        }
        .buttonStyle(PressableStyle())
        .animation(.snappy(duration: 0.22), value: selected)
    }
}

// MARK: - Chat row

struct ChatRow: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.ward) private var palette
    var chat: Chat
    var contact: Contact?
    var typing: String?
    var account: Account?
    @State private var appeared = false

    private var presence: String? {
        guard !chat.isGroup else { return nil }
        return contact?.presence ?? "offline"
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                AvatarView(name: chat.displayName, jid: chat.jid, size: settings.string("appearance.list_density") == "compact" ? 42 : 50,
                           presence: presence, imagePath: chat.avatar.isEmpty ? contact?.avatar : chat.avatar,
                           group: chat.isGroup)
                if chat.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(palette.accent, in: Circle())
                        .offset(x: 4, y: -3)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if chat.isRequest {
                        Text("REQUEST").font(.system(size: 8, weight: .heavy)).tracking(0.6)
                            .foregroundStyle(palette.warning)
                    }
                    Text(chat.displayName)
                        .font(.system(size: 16, weight: chat.unread > 0 ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    if chat.isGroup {
                        Image(systemName: "person.3.fill").font(.system(size: 9)).foregroundStyle(palette.tertiaryText)
                    }
                    if chat.isMuted {
                        Image(systemName: "bell.slash.fill").font(.system(size: 9)).foregroundStyle(palette.tertiaryText)
                    }
                    Spacer(minLength: 4)
                    Text(WardFormat.chatListTime(Date(millis: chat.lastActivity), settings: app.settings))
                        .font(.caption2)
                        .foregroundStyle(chat.unread > 0 ? palette.accent : palette.tertiaryText)
                }
                HStack(spacing: 6) {
                    if let typing, !typing.isEmpty, settings.bool("chats.show_typing") {
                        TypingDots(color: palette.accent)
                        Text("\(chat.isGroup ? typing : "typing")…")
                            .font(.subheadline).foregroundStyle(palette.accent).lineLimit(1)
                    } else if chat.draft.isEmpty {
                        if !chat.previewSender.isEmpty && !chat.isGroup {
                            Text(chat.previewSender == "You" ? "You: " : "")
                                .font(.subheadline).foregroundStyle(palette.tertiaryText)
                        }
                        Text(chat.preview.isEmpty ? (chat.isGroup ? (chat.subject.isEmpty ? "No messages yet" : chat.subject) : "No messages yet") : chat.preview)
                            .font(.subheadline)
                            .foregroundStyle(chat.unread > 0 ? palette.secondaryText : palette.tertiaryText)
                            .lineLimit(1)
                    } else {
                        Image(systemName: "pencil").font(.caption2).foregroundStyle(palette.danger)
                        Text("Draft: \(chat.draft)").font(.subheadline).foregroundStyle(palette.danger).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if chat.mentions > 0 {
                        Text("@").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 18, height: 18).background(palette.accent, in: Circle())
                    }
                    if chat.unread > 0 && chat.mentions == 0 {
                        Text("\(chat.unread)").font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, chat.unread > 99 ? 5 : 0)
                            .frame(minWidth: 19, minHeight: 19)
                            .background(chat.isMuted ? palette.tertiaryText : palette.accent, in: Capsule())
                            .contentTransition(.numericText())
                    }
                }
            }
        }
        .padding(.vertical, settings.string("appearance.list_density") == "compact" ? 7 : 10)
        .padding(.horizontal, 10)
        .background(palette.surface.opacity(chat.unread > 0 ? 1 : 0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(palette.outline.opacity(chat.unread > 0 ? 0.35 : 0.16), lineWidth: 0.5))
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 6)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { appeared = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(chat.displayName), \(chat.unread) unread. \(chat.preview)")
    }
}

// MARK: - Contacts

struct ContactsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @State private var search = ""
    @State private var showAdd = false
    @State private var showRequests = false
    @State private var showNewGroup = false

    private var filtered: [Contact] {
        app.contacts
            .filter { $0.inRoster || $0.presence != "offline" }
            .filter {
                guard !search.isEmpty else { return true }
                return $0.name.lowercased().contains(search.lowercased()) || $0.jid.lowercased().contains(search.lowercased())
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var grouped: [ContactGroup] {
        let dictionary = Dictionary(grouping: filtered) { contact -> String in
            let first = contact.name.first.map(String.init) ?? "#"
            return first.rangeOfCharacter(from: .letters) == nil ? "#" : first.uppercased()
        }
        return dictionary.keys.sorted().map { ContactGroup(id: $0, contacts: dictionary[$0] ?? []) }
    }

    var body: some View {
        ZStack {
            WardBackground()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if !app.requests.isEmpty {
                        Button { showRequests = true } label: {
                            HStack(spacing: 12) {
                                IconTile(icon: "person.crop.circle.badge.questionmark", color: palette.warning, size: 42)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Contact requests").font(.subheadline.weight(.semibold)).foregroundStyle(palette.text)
                                    Text("\(app.requests.count) waiting").font(.caption).foregroundStyle(palette.secondaryText)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(palette.tertiaryText)
                            }
                            .padding(12)
                            .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(PressableStyle())
                        .padding(.horizontal, 16).padding(.bottom, 8)
                    }

                    if filtered.isEmpty {
                        EmptyStateView(icon: "person.2",
                                       title: search.isEmpty ? "No contacts yet" : "No matches",
                                       subtitle: search.isEmpty ? "Add someone by their XMPP address to start a conversation." : "Try a different name or address.",
                                       action: search.isEmpty ? { showAdd = true } : nil,
                                       actionTitle: "Add contact")
                            .frame(minHeight: 380)
                    }

                    ForEach(grouped) { group in
                        let letter = group.id
                        let contacts = group.contacts
                        Section {
                            VStack(spacing: 0) {
                                ForEach(contacts) { contact in
                                    ContactRowView(contact: contact, account: app.account(id: contact.accountId))
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            Task { await app.openChat(accountId: contact.accountId, jid: contact.jid) }
                                        }
                                        .contextMenu {
                                            Button { Task { await app.openChat(accountId: contact.accountId, jid: contact.jid) } } label: {
                                                Label("Message", systemImage: "bubble.left")
                                            }
                                            Button { Task { await app.block(contact, blocked: !contact.blocked) } } label: {
                                                Label(contact.blocked ? "Unblock" : "Block", systemImage: contact.blocked ? "hand.raised.slash" : "hand.raised")
                                            }
                                            Divider()
                                            Button(role: .destructive) { Task { await app.removeContact(contact) } } label: {
                                                Label("Remove contact", systemImage: "person.badge.minus")
                                            }
                                        }
                                    if contact.id != contacts.last?.id {
                                        Divider().padding(.leading, 58).opacity(0.5)
                                    }
                                }
                            }
                            .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.outline.opacity(0.2), lineWidth: 0.5))
                            .padding(.horizontal, 16)
                            .padding(.bottom, 10)
                        } header: {
                            Text(letter)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(palette.tertiaryText)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(palette.background.opacity(0.92))
                        }
                    }
                    Spacer(minLength: 90)
                }
            }
            .scrollIndicators(.hidden)
            .searchable(text: $search, prompt: "Search contacts")
        }
        .navigationTitle("Contacts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showAdd = true } label: { Label("Add contact", systemImage: "person.badge.plus") }
                    Button { showNewGroup = true } label: { Label("New group", systemImage: "person.3.sequence") }
                } label: { Image(systemName: "plus.circle") }
            }
        }
        .sheet(isPresented: $showAdd) { AddContactSheet() }
        .sheet(isPresented: $showNewGroup) { NewGroupSheet() }
        .sheet(isPresented: $showRequests) { RequestsView() }
        .navigationDestination(item: Binding(get: { app.selectedChatId }, set: { app.selectChat($0) })) { id in
            ChatView(chatId: id)
        }
    }
}

private struct ContactGroup: Identifiable {
    let id: String
    let contacts: [Contact]
}

private struct ContactRowView: View {
    @Environment(\.ward) private var palette
    var contact: Contact
    var account: Account?
    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: contact.name, jid: contact.jid, size: 40, presence: contact.presence, imagePath: contact.avatar)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(contact.name).font(.subheadline.weight(.medium)).foregroundStyle(palette.text)
                    if contact.blocked {
                        Image(systemName: "hand.raised.fill").font(.system(size: 9)).foregroundStyle(palette.danger)
                    }
                }
                Text(contact.status.isEmpty ? contact.jid : contact.status)
                    .font(.caption).foregroundStyle(palette.secondaryText).lineLimit(1)
            }
            Spacer()
            if let account, account.id != contact.accountId {
                Text(JID.local(account.jid)).font(.caption2).foregroundStyle(palette.tertiaryText)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
