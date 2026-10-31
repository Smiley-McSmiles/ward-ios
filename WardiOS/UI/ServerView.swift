import SwiftUI
import UIKit

// MARK: - Server administration

struct ServerView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @State private var search = ""
    @State private var selected: AdminCommand? = nil
    @State private var showXML = false
    @State private var showDisco = false
    @State private var loading = false

    private var adminAccounts: [Account] { app.accounts.filter { $0.isAdmin } }
    private var commands: [AdminCommand] {
        app.commands.filter { search.isEmpty || $0.name.lowercased().contains(search.lowercased()) || $0.node.lowercased().contains(search.lowercased()) }
    }

    var body: some View {
        ZStack {
            WardBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if adminAccounts.isEmpty {
                        adminPrompt
                    }
                    tools
                    commandsList
                    Spacer(minLength: 90)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .refreshable { await app.loadCommands() }
        }
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search commands")
        .sheet(item: $selected) { command in
            AdminCommandView(command: command)
        }
        .sheet(isPresented: $showXML) { XmlConsoleView() }
        .sheet(isPresented: $showDisco) { DiscoView() }
        .task {
            if app.commands.isEmpty {
                loading = true
                await app.loadCommands()
                loading = false
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                IconTile(icon: "server.rack", color: .teal, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Server administration").font(.title3.weight(.bold)).foregroundStyle(palette.text)
                    Text(adminAccounts.isEmpty ? "Enable admin mode on an account to run commands." : "\(adminAccounts.count) administrator account\(adminAccounts.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(palette.secondaryText)
                }
                Spacer()
            }
            ForEach(adminAccounts) { account in
                HStack(spacing: 7) {
                    ConnectionPill(state: app.states[account.id] ?? ConnectionState())
                    Text(account.jid).font(.caption2).foregroundStyle(palette.secondaryText)
                }
            }
        }
        .padding(14)
        .background(
            LinearGradient(colors: [palette.accent.opacity(0.14), palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(palette.accent.opacity(0.18), lineWidth: 0.5))
    }

    private var adminPrompt: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill").foregroundStyle(palette.warning)
            Text("Open an account in Settings and turn on Server administrator to see every command your server advertises.")
                .font(.caption).foregroundStyle(palette.secondaryText)
            Spacer()
        }
        .padding(12)
        .background(palette.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var tools: some View {
        HStack(spacing: 10) {
            ToolButton(icon: "terminal.fill", title: "XML console", color: .black) { showXML = true }
            ToolButton(icon: "network", title: "Discover", color: .teal) { showDisco = true }
            ToolButton(icon: "arrow.clockwise", title: "Refresh", color: .blue) {
                Task { loading = true; await app.loadCommands(); loading = false }
            }
        }
    }

    private var commandsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Commands", subtitle: "XEP-0050 ad-hoc commands")
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Text("\(commands.count)").font(.caption.weight(.semibold)).foregroundStyle(palette.tertiaryText)
            }
            if commands.isEmpty {
                EmptyStateView(icon: "terminal", title: loading ? "Loading commands" : "No commands found",
                               subtitle: loading ? "Asking the server what it can do…" : "Your server may not advertise ad-hoc commands, or admin mode is off.")
                    .frame(minHeight: 300)
            } else {
                VStack(spacing: 0) {
                    ForEach(commands) { command in
                        Button { selected = command } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon(for: command))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(palette.accent)
                                    .frame(width: 32, height: 32)
                                    .background(palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(command.name).font(.subheadline.weight(.medium)).foregroundStyle(palette.text)
                                    Text(command.node).font(.caption2).foregroundStyle(palette.tertiaryText).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(palette.tertiaryText)
                            }
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        if command.id != commands.last?.id { Divider().padding(.leading, 44) }
                    }
                }
                .padding(.horizontal, 14)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.outline.opacity(0.2), lineWidth: 0.5))
            }
        }
    }

    private func icon(for command: AdminCommand) -> String {
        let text = (command.name + " " + command.node).lowercased()
        if text.contains("user") || text.contains("account") { return "person.2.fill" }
        if text.contains("restart") || text.contains("reload") || text.contains("shutdown") { return "power" }
        if text.contains("config") || text.contains("setting") { return "slider.horizontal.3" }
        if text.contains("invite") { return "envelope.fill" }
        if text.contains("stat") || text.contains("uptime") { return "chart.bar.fill" }
        return "terminal.fill"
    }
}

private struct ToolButton: View {
    @Environment(\.ward) private var palette
    var icon: String
    var title: String
    var color: Color
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(color)
                    .frame(width: 40, height: 40).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(title).font(.caption2.weight(.medium)).foregroundStyle(palette.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Command form

struct AdminCommandView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    var command: AdminCommand
    @State private var form: AdminForm? = nil
    @State private var loading = true
    @State private var submitting = false
    @State private var error = ""

    var body: some View {
        NavigationStack {
            ZStack {
                WardBackground()
                if loading {
                    ProgressView("Running \(command.name)…")
                } else if let form {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(form.title).font(.title3.weight(.bold))
                                if !form.instructions.isEmpty {
                                    Text(form.instructions).font(.subheadline).foregroundStyle(palette.secondaryText)
                                }
                                Text(form.status.capitalized + " · \(command.jid)")
                                    .font(.caption2).foregroundStyle(palette.tertiaryText)
                            }
                            if !form.notes.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(form.notes.enumerated()), id: \.offset) { _, note in
                                        HStack(alignment: .top, spacing: 7) {
                                            Image(systemName: "info.circle.fill").foregroundStyle(palette.accent).font(.caption)
                                            Text(note).font(.subheadline).foregroundStyle(palette.text)
                                        }
                                    }
                                }
                                .padding(12)
                                .background(palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            if !form.fields.isEmpty {
                                VStack(spacing: 14) {
                                    ForEach(form.fields) { field in
                                        AdminFieldView(field: field, form: $form)
                                    }
                                }
                                .padding(14)
                                .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            if !error.isEmpty {
                                Text(error).font(.caption).foregroundStyle(palette.danger)
                            }
                            if form.status == "executing" || form.status == "completed" {
                                actionButtons(form)
                            }
                            Spacer(minLength: 20)
                        }
                        .padding(16)
                    }
                } else {
                    EmptyStateView(icon: "exclamationmark.triangle", title: "No response",
                                   subtitle: error.isEmpty ? "The server did not return a form for this command." : error)
                }
            }
            .navigationTitle(command.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await run(action: "execute") }
        }
    }

    private func actionButtons(_ form: AdminForm) -> some View {
        VStack(spacing: 9) {
            if form.status == "completed" {
                Button("Done") { dismiss() }
                    .buttonStyle(WardPrimaryButtonStyle())
            } else {
                Button {
                    Task { await run(action: "complete") }
                } label: {
                    HStack {
                        if submitting { ProgressView().tint(palette.onAccent) }
                        Text("Submit")
                    }
                }
                .buttonStyle(WardPrimaryButtonStyle())
                .disabled(submitting)
                HStack(spacing: 9) {
                    if form.actions.contains("prev") {
                        Button("Back") { Task { await run(action: "prev") } }
                            .buttonStyle(WardSecondaryButtonStyle())
                    }
                    if form.actions.contains("next") {
                        Button("Next") { Task { await run(action: "next") } }
                            .buttonStyle(WardSecondaryButtonStyle())
                    }
                    Button("Cancel", role: .destructive) { dismiss() }
                        .buttonStyle(WardSecondaryButtonStyle())
                }
            }
        }
    }

    private func run(action: String) async {
        submitting = true
        error = ""
        if let current = form {
            form = await app.submitForm(current, action: action) ?? current
        } else {
            form = await app.executeCommand(command)
            if form == nil { error = "The command could not be started." }
        }
        submitting = false
        loading = false
    }
}

struct AdminFieldView: View {
    @Environment(\.ward) private var palette
    var field: AdminField
    @Binding var form: AdminForm?

    private var valueBinding: Binding<String> {
        Binding(
            get: { form?.fields.first { $0.id == field.id }?.value ?? field.value },
            set: { newValue in
                guard var current = form, let index = current.fields.firstIndex(where: { $0.id == field.id }) else { return }
                current.fields[index].value = newValue
                form = current
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if field.type != "fixed" && field.type != "hidden" {
                HStack(spacing: 4) {
                    Text(field.label).font(.caption.weight(.semibold)).foregroundStyle(palette.secondaryText)
                    if field.required { Text("*").foregroundStyle(palette.danger) }
                }
            }
            switch field.type {
            case "fixed":
                Text(field.value).font(.subheadline).foregroundStyle(palette.text).padding(.vertical, 2)
            case "hidden":
                EmptyView()
            case "boolean":
                Toggle(field.label, isOn: Binding(get: { valueBinding.wrappedValue == "1" || valueBinding.wrappedValue.lowercased() == "true" },
                                                 set: { valueBinding.wrappedValue = $0 ? "1" : "0" }))
                    .tint(palette.accent)
            case "list-single":
                Menu {
                    ForEach(Array(field.options.enumerated()), id: \.offset) { _, option in
                        Button(option.0.isEmpty ? option.1 : option.0) { valueBinding.wrappedValue = option.1 }
                    }
                } label: {
                    HStack {
                        Text(field.options.first { $0.1 == valueBinding.wrappedValue }?.0 ?? (valueBinding.wrappedValue.isEmpty ? "Choose" : valueBinding.wrappedValue))
                            .foregroundStyle(palette.text)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(palette.tertiaryText)
                    }
                    .padding(11)
                    .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            case "list-multi":
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(field.options.enumerated()), id: \.offset) { _, option in
                        let selected = valueBinding.wrappedValue.components(separatedBy: "\n").contains(option.1)
                        Button {
                            var values = valueBinding.wrappedValue.components(separatedBy: "\n").filter { !$0.isEmpty }
                            if selected { values.removeAll { $0 == option.1 } } else { values.append(option.1) }
                            valueBinding.wrappedValue = values.joined(separator: "\n")
                        } label: {
                            HStack {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected ? palette.accent : palette.tertiaryText)
                                Text(option.0.isEmpty ? option.1 : option.0).font(.subheadline).foregroundStyle(palette.text)
                                Spacer()
                            }
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                    }
                }
            case "text-multi", "jid-multi":
                TextEditor(text: valueBinding)
                    .frame(minHeight: 80)
                    .font(.subheadline)
                    .padding(6)
                    .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.outline.opacity(0.3), lineWidth: 0.5))
            default:
                TextField(field.label, text: valueBinding)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(11)
                    .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let media = field.media {
                if media.hasPrefix("data:"), let comma = media.firstIndex(of: ","),
                   let data = Data(base64Encoded: String(media[media.index(after: comma)...])),
                   let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if let url = URL(string: media), url.scheme == "https" || url.scheme == "http" {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit().frame(maxHeight: 130)
                    } placeholder: { ProgressView() }
                }
            }
            if !field.desc.isEmpty {
                Text(field.desc).font(.caption2).foregroundStyle(palette.tertiaryText)
            }
        }
    }
}
