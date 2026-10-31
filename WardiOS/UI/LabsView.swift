import UIKit
import SwiftUI

// MARK: - XML console

struct XmlConsoleView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var accountFilter: Int64? = nil
    @State private var search = ""
    @State private var showSend = false
    @State private var raw = ""

    private var entries: [XmlLogEntry] {
        app.xmlLog.filter { entry in
            (accountFilter == nil || entry.accountId == accountFilter) &&
            (search.isEmpty || entry.text.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                (palette.dark ? Color(hex: "#111014") : Color(hex: "#F8F8FB")).ignoresSafeArea()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            if entries.isEmpty {
                                EmptyStateView(icon: "terminal", title: "No stanzas yet",
                                               subtitle: "Incoming and outgoing XML will appear here as Ward talks to the server.")
                                    .frame(minHeight: 340)
                            }
                            ForEach(entries) { entry in
                                entryRow(entry)
                                    .id(entry.id)
                            }
                            Color.clear.frame(height: 1).id("xml-bottom")
                        }
                        .padding(10)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: app.xmlLog.count) { _, _ in
                        withAnimation(.linear(duration: 0.15)) { proxy.scrollTo("xml-bottom", anchor: .bottom) }
                    }
                }
            }
            .navigationTitle("XML console")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Filter stanzas")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("All accounts") { accountFilter = nil }
                        ForEach(app.accounts) { account in
                            Button(account.jid) { accountFilter = account.id }
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Button { showSend = true } label: { Image(systemName: "paperplane") }
                        Button("Clear") { app.clearXML() }
                        Button("Done") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $showSend) {
                NavigationStack {
                    Form {
                        Section("Raw stanza") {
                            TextEditor(text: $raw)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: 180)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Section {
                            Button("Send") {
                                if app.sendRawXml(raw) {
                                    app.showToast("Stanza sent.")
                                    raw = ""
                                    showSend = false
                                } else {
                                    app.showToast("No connected account.", error: true)
                                }
                            }
                            .disabled(raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        } footer: {
                            Text("Advanced: stanzas are sent exactly as typed. Invalid XML can close the stream.")
                        }
                    }
                    .navigationTitle("Send stanza")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { showSend = false } } }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func entryRow(_ entry: XmlLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: entry.incoming ? "arrow.down.left" : "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(entry.incoming ? palette.success : palette.accent)
                Text(entry.time.formatted(.dateTime.hour().minute().second()))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(palette.tertiaryText)
                if let account = app.account(id: entry.accountId) {
                    Text(JID.local(account.jid)).font(.system(size: 9, design: .monospaced)).foregroundStyle(palette.tertiaryText)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = entry.text
                    app.showToast("Copied.")
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 9)).foregroundStyle(palette.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            Text(entry.text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(entry.incoming ? palette.text : palette.accent)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .background(entry.incoming ? palette.surface.opacity(0.6) : palette.accent.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(entry.incoming ? palette.outline.opacity(0.15) : palette.accent.opacity(0.18), lineWidth: 0.5))
    }
}

// MARK: - Service discovery

struct DiscoView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var accountId: Int64 = 0
    @State private var jid = ""
    @State private var info: XMLNode? = nil
    @State private var items: [DiscoItem] = []
    @State private var loading = false
    @State private var error = ""
    @State private var showRaw = false
    @State private var history: [String] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    searchCard
                    if loading {
                        ProgressView("Looking up \(jid)…").frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else if !error.isEmpty {
                        Text(error).font(.caption).foregroundStyle(palette.danger)
                    }
                    if let info, let query = info.child("query", xmlns: NS.discoInfo) {
                        identities(query)
                        features(query)
                        if showRaw {
                            Text(info.xmlString()).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(palette.secondaryText).textSelection(.enabled)
                                .padding(10).background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            SectionHeader(title: "Items")
                            VStack(spacing: 0) {
                                ForEach(items) { item in
                                    HStack(spacing: 11) {
                                        IconTile(icon: "shippingbox.fill", color: .teal)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name).font(.subheadline.weight(.medium)).foregroundStyle(palette.text).lineLimit(1)
                                            Text(item.jid + (item.node.isEmpty ? "" : " · \(item.node)")).font(.caption2).foregroundStyle(palette.tertiaryText).lineLimit(1)
                                        }
                                        Spacer()
                                        Button { browse(item.jid) } label: { Image(systemName: "chevron.right") }
                                            .buttonStyle(.plain).foregroundStyle(palette.tertiaryText)
                                    }
                                    .padding(.vertical, 9)
                                    if item.id != items.last?.id { Divider().padding(.leading, 44) }
                                }
                            }
                            .padding(.horizontal, 14)
                            .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    Spacer(minLength: 20)
                }
                .padding(16)
            }
            .background(WardBackground())
            .navigationTitle("Discovery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Button { showRaw.toggle() } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                        Button("Done") { dismiss() }
                    }
                }
            }
            .onAppear {
                if accountId == 0 { accountId = app.accounts.first?.id ?? 0 }
                if jid.isEmpty { jid = app.account(id: accountId)?.domain ?? "" }
                if info == nil { browse(jid) }
            }
        }
    }

    private var searchCard: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.secondaryText)
                TextField("Service address", text: $jid)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Look up") { browse(jid) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .tint(palette.accent)
            }
            HStack(spacing: 7) {
                ForEach(app.accounts) { account in
                    Button(JID.domain(account.jid)) { accountId = account.id; jid = account.domain; browse(jid) }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(accountId == account.id ? palette.onAccent : palette.secondaryText)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(accountId == account.id ? palette.accent : palette.surfaceContainer, in: Capsule())
                }
                Spacer()
            }
        }
        .padding(12)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func identities(_ query: XMLNode) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader(title: "Identities")
            VStack(spacing: 0) {
                ForEach(Array(query.children("identity").enumerated()), id: \.offset) { _, identity in
                    HStack(spacing: 11) {
                        IconTile(icon: "person.crop.square.fill", color: .blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(identity.attr("name", identity.attr("type", "Service"))).font(.subheadline).foregroundStyle(palette.text)
                            Text("\(identity.attr("category", "?")) / \(identity.attr("type", "?"))")
                                .font(.caption2).foregroundStyle(palette.tertiaryText)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 14)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func features(_ query: XMLNode) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader(title: "Features", subtitle: "\(query.children("feature").count) advertised")
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(query.children("feature").map { $0.attr("var", "") }.filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, feature in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 9)).foregroundStyle(palette.success).padding(.top, 2)
                        Text(feature).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(palette.secondaryText)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func browse(_ target: String) {
        guard !target.isEmpty else { return }
        loading = true
        error = ""
        items = []
        info = nil
        Task {
            jid = target
            let infoText = await app.discoInfo(accountId: accountId, jid: target)
            items = await app.discoItems(accountId: accountId, jid: target)
            info = XML.parse(infoText)
            if info == nil { error = "No response from \(target)." }
            loading = false
        }
    }
}
