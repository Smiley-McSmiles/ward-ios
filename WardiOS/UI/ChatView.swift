import UIKit
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

struct ChatView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    let chatId: Int64

    @State private var text = ""
    @State private var replyTo: Message? = nil
    @State private var editing: Message? = nil
    @State private var showDetails = false
    @State private var showSearch = false
    @State private var showAttach = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var showCamera = false
    @State private var showSchedule = false
    @State private var showGIF = false
    @State private var showContactShare = false
    @StateObject private var locationSharer = LocationSharer()
    @State private var photos: [PhotosPickerItem] = []
    @State private var pendingDelete: Message? = nil
    @State private var forwardMessage: Message? = nil
    @State private var atBottom = true
    @StateObject private var recorder = VoiceRecorder()
    @State private var recordingError = false
    @FocusState private var focused: Bool

    private var chat: Chat? { app.chat(id: chatId) }
    private var messages: [Message] { app.messages(for: chatId) }
    private var contact: Contact? {
        guard let chat else { return nil }
        return app.contact(jid: chat.jid, accountId: chat.accountId)
    }
    private var sessionState: ConnectionState? {
        guard let chat else { return nil }
        return app.states[chat.accountId]
    }

    var body: some View {
        ZStack {
            WardBackground()
            if let chat {
                GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if chat.isGroup && !chat.joined {
                                joinBanner(chat)
                            }
                            if !chat.subject.isEmpty && chat.isGroup {
                                subjectBanner(chat)
                            }
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                if needsDateHeader(index) {
                                    DateSeparator(date: message.date)
                                }
                                MessageRow(chat: chat, message: message,
                                           previous: index > 0 ? messages[index - 1] : nil,
                                           showAvatar: showsAvatar(index),
                                           onReply: { startReply(message) },
                                           onReact: { app.react(message, emoji: $0) },
                                           onEdit: { startEdit(message) },
                                           onForward: { forwardMessage = message },
                                           onDelete: {
                                               if message.scheduledAt != nil {
                                                   Task { await app.cancelScheduled(message) }
                                               } else {
                                                   pendingDelete = message
                                               }
                                           },
                                           onDetails: { showDetails = true })
                                    .id(message.id)
                                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                            removal: .opacity))
                            }
                            if let typing = app.typing[chat.id], !typing.isEmpty,
                               app.settings.bool("chats.show_typing") {
                                TypingBubble(name: typing, isGroup: chat.isGroup)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                            Color.clear.frame(height: 6).id("bottom")
                                .onAppear { atBottom = true }
                                .onDisappear { atBottom = false }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 8)
                        .padding(.horizontal, max(0, (geometry.size.width - 860) / 2))
                        .animation(app.settings.bool("appearance.message_animations") ? .spring(response: 0.42, dampingFraction: 0.84) : nil,
                                   value: messages.map(\.id))
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: messages.last?.id) { _, newValue in
                        guard newValue != nil else { return }
                        if atBottom || messages.last?.isOutgoing == true {
                            withAnimation(app.settings.bool("appearance.message_animations") ? .spring(response: 0.42, dampingFraction: 0.82) : .none) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                        if messages.last?.isOutgoing == false {
                            Task { await app.markRead(chat: chat) }
                        }
                    }
                    .onChange(of: app.typing[chat.id]) { _, value in
                        if value != nil && atBottom {
                            withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !atBottom {
                            Button {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
                                Haptics.tap()
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(palette.onAccent)
                                    .frame(width: 34, height: 34)
                                    .background(palette.accent, in: Circle())
                                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                            }
                            .padding(.trailing, 14).padding(.bottom, 8)
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                }
            } else {
                EmptyStateView(icon: "bubble.left.slash", title: "Chat unavailable",
                               subtitle: "This conversation was removed.")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let chat {
                    Button { showDetails = true } label: {
                        HStack(spacing: 9) {
                            AvatarView(name: chat.displayName, jid: chat.jid, size: 32,
                                       presence: chat.isGroup ? nil : (contact?.presence ?? "offline"),
                                       imagePath: chat.avatar.isEmpty ? contact?.avatar : chat.avatar,
                                       group: chat.isGroup)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(chat.displayName).font(.system(size: 16, weight: .semibold, design: .rounded))
                                    .foregroundStyle(palette.text).lineLimit(1)
                                HStack(spacing: 4) {
                                    if chat.isGroup {
                                        Text(chat.joined ? "\(max(chat.memberCount, app.members[chat.jid]?.count ?? 0)) members" : "Not joined")
                                    } else {
                                        Text(WardFormat.presence(contact, state: sessionState))
                                    }
                                    if app.effectiveEncryption(chat) != .off {
                                        Image(systemName: "lock.fill").font(.system(size: 7))
                                    }
                                }
                                .font(.caption2).foregroundStyle(palette.secondaryText).lineLimit(1)
                            }
                            .frame(maxWidth: 190, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let chat {
                ComposerView(chat: chat, text: $text, replyTo: $replyTo, editing: $editing,
                             focused: $focused, recorder: recorder,
                             onSend: send, onAttach: { showAttach = true },
                             onStopTyping: { app.typing(false) },
                             onRecordingError: { recordingError = true },
                             onSendVoice: { url, duration in app.sendVoice(url, duration: duration) },
                             onSchedule: { showSchedule = true })
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
            }
        }
        .task {
            app.selectChat(chatId)
            if let chat { await app.markRead(chat: chat) }
        }
        .onDisappear {
            app.typing(false)
            if let chat {
                Task { await app.setDraft(text) }
            }
        }
        .sheet(isPresented: $showDetails) {
            if let chat { ChatDetailsSheet(chat: chat) }
        }
        .sheet(isPresented: $showSearch) {
            if let chat { ChatSearchSheet(chat: chat) }
        }
        .sheet(item: $forwardMessage) { message in
            ForwardSheet(message: message)
        }
        .sheet(isPresented: $showGIF) {
            GifPickerSheet()
        }
        .sheet(isPresented: $showContactShare) {
            if let chat {
                ContactPickerSheet(accountId: chat.accountId) { contact in
                    app.send("Contact: \(contact.name)\nXMPP: xmpp:\(contact.jid)")
                }
            }
        }
        .sheet(isPresented: $showSchedule) {
            ScheduleSendSheet(text: text) { date in
                Task { await app.scheduleMessage(text, at: date) }
                text = ""
                focused = false
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photos, maxSelectionCount: 8, matching: .images)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        app.sendPhoto(data, name: "photo-\(Int(Date().timeIntervalSince1970)).jpg")
                    }
                }
                photos = []
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { app.sendFiles(urls) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let data = image.jpegData(compressionQuality: 0.9) {
                    app.sendPhoto(data, name: "camera-\(Int(Date().timeIntervalSince1970)).jpg")
                }
            }
        }
        .confirmationDialog("Add an attachment", isPresented: $showAttach, titleVisibility: .visible) {
            Button("Photo library") { showPhotoPicker = true }
            Button("Camera") { showCamera = true }
            Button("File") { showFilePicker = true }
            Button("GIF") { showGIF = true }
            Button("Share a contact") { showContactShare = true }
            Button("Share location") {
                locationSharer.share { text in
                    if let text { app.send(text) }
                    else { app.showToast("Location permission is needed to share a location.", error: true) }
                }
            }
            Button("Voice message") {
                Task {
                    if await recorder.start() { Haptics.soft() } else { recordingError = true }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this message for everyone?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete for everyone", role: .destructive) {
                if let message = pendingDelete { app.retract(message) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The message will be removed for everyone in this conversation.")
        }
        .alert("Microphone access is needed", isPresented: $recordingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Allow microphone access in Settings to record voice messages.")
        }
        .toolbar(.hidden, for: .tabBar)
    }

    private func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editing, !body.isEmpty {
            app.edit(editing, text: body)
            self.editing = nil
            text = ""
            focused = false
            return
        }
        guard !body.isEmpty else { return }
        app.send(body, replyTo: replyTo)
        text = ""
        replyTo = nil
        app.typing(false)
        Haptics.tap()
    }

    private func startReply(_ message: Message) {
        editing = nil
        replyTo = message
        focused = true
        Haptics.tap()
    }

    private func startEdit(_ message: Message) {
        replyTo = nil
        editing = message
        text = message.body
        focused = true
    }

    private func needsDateHeader(_ index: Int) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(messages[index].date, inSameDayAs: messages[index - 1].date)
    }

    private func showsAvatar(_ index: Int) -> Bool {
        guard index > 0 else { return true }
        let current = messages[index]
        let previous = messages[index - 1]
        if current.sender != previous.sender { return true }
        return current.timestamp - previous.timestamp > 5 * 60 * 1000
    }

    private func joinBanner(_ chat: Chat) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "person.3.sequence.fill").font(.system(size: 28)).foregroundStyle(palette.accent)
            Text(chat.joinError.isEmpty ? "Join \(chat.displayName)" : chat.joinError)
                .font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
            Button(chat.joinError.isEmpty ? "Join group" : "Try again") {
                Task { await app.joinGroup(chat) }
            }
            .buttonStyle(WardPrimaryButtonStyle(fullWidth: false))
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func subjectBanner(_ chat: Chat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.quote").font(.caption).foregroundStyle(palette.accent)
            Text(chat.subject).font(.caption).foregroundStyle(palette.secondaryText).lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(palette.surfaceContainer, in: Capsule())
        .padding(.horizontal, 16).padding(.bottom, 6)
    }
}

private struct DateSeparator: View {
    @Environment(\.ward) private var palette
    var date: Date
    var body: some View {
        Text(WardFormat.dayHeader(date))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(palette.secondaryText)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(palette.surfaceContainer, in: Capsule())
            .padding(.vertical, 10)
            .transition(.opacity)
    }
}

private struct TypingBubble: View {
    @Environment(\.ward) private var palette
    var name: String
    var isGroup: Bool
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isGroup {
                AvatarView(name: name, size: 28)
            }
            HStack(spacing: 6) {
                TypingDots(color: palette.secondaryText)
                Text(isGroup ? "\(name) is typing" : "typing")
                    .font(.caption2).foregroundStyle(palette.secondaryText)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(palette.incomingBubble, in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

// MARK: - Camera

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Composer

struct ComposerView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    var chat: Chat
    @Binding var text: String
    @Binding var replyTo: Message?
    @Binding var editing: Message?
    var focused: FocusState<Bool>.Binding
    @ObservedObject var recorder: VoiceRecorder
    var onSend: () -> Void
    var onAttach: () -> Void
    var onStopTyping: () -> Void
    var onRecordingError: () -> Void
    var onSendVoice: (URL, Double) -> Void
    var onSchedule: () -> Void

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if recorder.recording {
                recordingPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                if let editing {
                    banner(icon: "pencil", title: "Editing message", text: editing.body, tint: palette.warning) {
                        self.editing = nil; text = ""
                    }
                } else if let replyTo {
                    banner(icon: "arrowshape.turn.up.left", title: "Replying to \(replyTo.senderName)",
                           text: replyTo.body, tint: palette.accent) {
                        self.replyTo = nil
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    Button(action: onAttach) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(palette.accent)
                            .frame(width: 36, height: 36)
                            .background(palette.surfaceContainer, in: Circle())
                    }
                    .buttonStyle(PressableStyle())

                    HStack(alignment: .bottom, spacing: 6) {
                        TextField(chat.isGroup ? "Message the group" : "Message", text: $text, axis: .vertical)
                            .lineLimit(1...6)
                            .font(.body)
                            .textContentType(.none)
                            .focused(focused)
                            .submitLabel(.send)
                            .onSubmit {
                                if app.settings.string("chats.send_with", "enter") == "enter" { onSend() }
                                else { text += "\n" }
                            }
                            .onChange(of: text) { _, value in
                                app.typing(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                if value.isEmpty { onStopTyping() }
                            }
                        if canSend {
                            Button(action: onSchedule) {
                                Image(systemName: "clock")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(palette.secondaryText)
                                    .frame(width: 30, height: 30)
                            }
                            .buttonStyle(PressableStyle())
                            .transition(.scale.combined(with: .opacity))
                            Button(action: onSend) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(palette.onAccent)
                                    .frame(width: 32, height: 32)
                                    .background(palette.accent, in: Circle())
                            }
                            .buttonStyle(PressableStyle())
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .strokeBorder(palette.outline.opacity(0.35), lineWidth: 0.5))

                    if !canSend {
                        Button {
                            Task {
                                if await recorder.start() { Haptics.soft() }
                                else { onRecordingError() }
                            }
                        } label: {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(palette.onAccent)
                                .frame(width: 36, height: 36)
                                .background(palette.accent, in: Circle())
                        }
                        .buttonStyle(PressableStyle())
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .animation(.snappy(duration: 0.22), value: canSend)
            }
        }
        .animation(.snappy(duration: 0.25), value: recorder.recording)
        .animation(.snappy(duration: 0.25), value: replyTo?.id)
        .animation(.snappy(duration: 0.25), value: editing?.id)
    }

    private func banner(icon: String, title: String, text: String, tint: Color, onClose: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(tint)
                Text(text).font(.caption2).foregroundStyle(palette.secondaryText).lineLimit(1)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(palette.secondaryText)
                    .frame(width: 24, height: 24).background(palette.surfaceContainer, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(palette.surface.opacity(0.9))
    }

    private var recordingPanel: some View {
        HStack(spacing: 12) {
            Button {
                recorder.cancel()
            } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.danger)
                    .frame(width: 34, height: 34).background(palette.danger.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 2) {
                ForEach(Array(recorder.levels.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(palette.accent)
                        .frame(width: 2.5, height: max(3, CGFloat(level) * 28))
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
            .frame(maxWidth: .infinity)
            Text(WardFormat.duration(recorder.duration))
                .font(.caption.monospacedDigit()).foregroundStyle(palette.text)
                .contentTransition(.numericText())
            Button {
                if let result = recorder.stop() { onSendVoice(result.0, result.1) }
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(palette.onAccent)
                    .frame(width: 36, height: 36).background(palette.accent, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(palette.surface)
    }
}


struct ScheduleSendSheet: View {
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    var text: String
    var onSchedule: (Date) -> Void
    @State private var date = Date().addingTimeInterval(3600)

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    IconTile(icon: "clock.badge.checkmark", color: .indigo, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Schedule message").font(.headline)
                        Text("Ward will send it while the app is open or connected.").font(.caption).foregroundStyle(palette.secondaryText)
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("MESSAGE").font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(palette.tertiaryText)
                    Text(text.isEmpty ? "Write a message first." : text)
                        .font(.subheadline).foregroundStyle(text.isEmpty ? palette.tertiaryText : palette.text)
                        .lineLimit(4)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                DatePicker("Send at", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                    .tint(palette.accent)
                Spacer()
                Button("Schedule") {
                    onSchedule(date)
                    dismiss()
                }
                .buttonStyle(WardPrimaryButtonStyle())
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || date < Date())
            }
            .padding(18)
            .background(WardBackground())
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}
