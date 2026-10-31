import UIKit
import SwiftUI
import AVKit
import QuickLook
import PhotosUI

struct MessageRow: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    var chat: Chat
    var message: Message
    var previous: Message?
    var showAvatar: Bool
    var onReply: () -> Void
    var onReact: (String) -> Void
    var onEdit: () -> Void
    var onForward: () -> Void
    var onDelete: () -> Void
    var onDetails: () -> Void
    @State private var viewerImage: UIImage? = nil
    @State private var viewerVideo: URL? = nil
    @State private var viewerFile: URL? = nil

    private var outgoing: Bool { message.isOutgoing }
    private var layout: String { app.settings.string("appearance.layout", "cozy") }
    private var avatarSetting: String { app.settings.string("appearance.avatars", "always") }
    private var showAvatarHere: Bool {
        guard !outgoing else { return false }
        switch avatarSetting {
        case "never": return false
        case "groups": return chat.isGroup && showAvatar
        default: return showAvatar
        }
    }
    private var bubbleColor: Color { outgoing ? palette.outgoingBubble : palette.incomingBubble }
    private var textColor: Color { outgoing ? palette.outgoingText : palette.incomingText }
    private var maxWidth: CGFloat { 520 }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !outgoing && layout != "compact" {
                if showAvatarHere {
                    AvatarView(name: message.senderName, jid: message.senderJid, size: 30,
                               imagePath: avatarPath)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Color.clear.frame(width: 30, height: 1)
                }
            }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 3) {
                if chat.isGroup && !outgoing && showAvatar && layout != "compact" {
                    Text(message.senderName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.accent)
                        .padding(.leading, 8)
                }
                if !message.replyTo.isEmpty {
                    replyQuote
                }
                bubble
                if !message.reactions.isEmpty {
                    reactionBar
                }
                if !message.error.isEmpty, message.status == -1 {
                    Text(message.error).font(.caption2).foregroundStyle(palette.danger)
                        .multilineTextAlignment(outgoing ? .trailing : .leading)
                        .frame(maxWidth: 300, alignment: outgoing ? .trailing : .leading)
                }
            }
            .frame(maxWidth: maxWidth, alignment: outgoing ? .trailing : .leading)
            Spacer(minLength: 36)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, layout == "compact" ? 1 : 2)
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
        .contentShape(Rectangle())
        .contextMenu { contextMenu }
        .onTapGesture(count: 2) {
            onReact("❤️")
            Haptics.soft()
        }
        .fullScreenCover(item: viewerImageBinding) { item in
            ImageViewer(image: item.image)
        }
        .sheet(item: viewerVideoBinding) { item in
            VideoPlayerScreen(url: item.url)
        }
        .sheet(item: viewerFileBinding) { item in
            QuickLookScreen(url: item.url)
        }
    }

    private var avatarPath: String? {
        if chat.isGroup {
            return app.contact(jid: message.senderJid, accountId: chat.accountId)?.avatar
        }
        return app.contact(jid: chat.jid, accountId: chat.accountId)?.avatar ?? chat.avatar
    }

    @ViewBuilder private var bubble: some View {
        if message.retracted {
            Text("This message was deleted")
                .italic().font(.subheadline)
                .foregroundStyle(textColor.opacity(0.7))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(bubbleColor.opacity(outgoing ? 0.7 : 1), in: BubbleShape(outgoing: outgoing))
        } else {
            VStack(alignment: .leading, spacing: 5) {
                if !message.attachments.isEmpty {
                    ForEach(message.attachments) { attachment in
                        AttachmentView(attachment: attachment, outgoing: outgoing,
                                       onImage: { viewerImage = $0 },
                                       onVideo: { viewerVideo = $0 },
                                       onFile: { viewerFile = $0 })
                    }
                }
                if !message.body.isEmpty {
                    if isOnlyEmoji && app.settings.bool("appearance.large_emoji") && message.attachments.isEmpty {
                        Text(message.body.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 44))
                            .padding(.horizontal, 4).padding(.vertical, 2)
                    } else {
                        MarkdownView(text: displayBody, foreground: textColor, outgoing: outgoing,
                                     compact: layout == "compact")
                    }
                }
                HStack(spacing: 4) {
                    if message.edited {
                        Text("edited").font(.system(size: 9)).foregroundStyle(textColor.opacity(0.62))
                    }
                    if !message.encryption.isEmpty {
                        Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(textColor.opacity(0.6))
                    }
                    Spacer(minLength: 6)
                    Text(WardFormat.time(message.date, settings: app.settings))
                        .font(.system(size: 9.5))
                        .foregroundStyle(textColor.opacity(0.62))
                        .contentTransition(.numericText())
                    if outgoing { statusIcon }
                }
                .padding(.top, 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(bubbleColor, in: BubbleShape(outgoing: outgoing))
            .overlay(alignment: .bottomTrailing) {
                if outgoing {
                    BubbleShape(outgoing: true)
                        .stroke(palette.accent.opacity(0.2), lineWidth: 0.5)
                }
            }
            .shadow(color: .black.opacity(palette.dark ? 0.18 : 0.05), radius: 4, y: 2)
        }
    }

    private var displayBody: String {
        if message.kind == MessageKind.me.rawValue {
            return "*\(message.senderName) \(message.body.replacingOccurrences(of: "/me ", with: ""))*"
        }
        return message.body
    }

    private var isOnlyEmoji: Bool {
        let scalars = message.body.unicodeScalars
        guard !scalars.isEmpty else { return false }
        return scalars.allSatisfy { $0.properties.isEmojiPresentation || $0.properties.isEmojiModifier || $0.isWhitespace || $0.value == 0x200D || $0.properties.isEmoji }
    }

    @ViewBuilder private var statusIcon: some View {
        switch message.status {
        case -1:
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(palette.danger)
        case 0:
            Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(textColor.opacity(0.6))
        case 1:
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(textColor.opacity(0.7))
        case 2:
            Image(systemName: "checkmark.circle").font(.system(size: 9, weight: .bold)).foregroundStyle(textColor.opacity(0.7))
        default:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(outgoing ? Color.white : palette.success)
        }
    }

    private var replyQuote: some View {
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5).fill(palette.accent).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(message.replyAuthor.isEmpty ? "Reply" : message.replyAuthor)
                    .font(.caption2.weight(.semibold)).foregroundStyle(palette.accent)
                Text(message.replyPreview.isEmpty ? "Original message" : message.replyPreview)
                    .font(.caption2).foregroundStyle(palette.secondaryText).lineLimit(2)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 2)
        .frame(maxWidth: 280, alignment: .leading)
    }

    private var reactionBar: some View {
        let grouped = Dictionary(grouping: message.reactions.flatMap { reaction in
            reaction.emoji.map { ($0, reaction.mine) }
        }, by: { $0.0 })
        return HStack(spacing: 4) {
            ForEach(grouped.keys.sorted(), id: \.self) { emoji in
                let items = grouped[emoji] ?? []
                Button {
                    onReact(emoji)
                    Haptics.tap()
                } label: {
                    HStack(spacing: 3) {
                        Text(emoji).font(.system(size: 13))
                        if items.count > 1 {
                            Text("\(items.count)").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(items.contains(where: { $0.1 }) ? palette.onAccent : palette.secondaryText)
                        }
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(items.contains(where: { $0.1 }) ? palette.accent.opacity(0.9) : palette.surfaceContainer,
                                in: Capsule())
                    .overlay(Capsule().strokeBorder(palette.outline.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var contextMenu: some View {
        Button { onReply() } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        Menu {
            ForEach(quickReactions, id: \.self) { emoji in
                Button(emoji) { onReact(emoji) }
            }
        } label: { Label("React", systemImage: "face.smiling") }
        Button {
            UIPasteboard.general.string = message.body
            Haptics.tap()
        } label: { Label("Copy", systemImage: "doc.on.doc") }
        if outgoing && message.kind != MessageKind.system.rawValue && !message.retracted {
            Button { onEdit() } label: { Label("Edit", systemImage: "pencil") }
        }
        Button { onForward() } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
        Button { onDetails() } label: { Label("Details", systemImage: "info.circle") }
        if outgoing && !message.retracted {
            Divider()
            Button(role: .destructive) { onDelete() } label: { Label("Delete for everyone", systemImage: "trash") }
        }
    }

    private var quickReactions: [String] {
        let list = app.settings.list("chats.quick_reactions")
        return list.isEmpty ? SettingsSchema.defaultReactions : list
    }

    // Identifiable wrappers for sheets.
    private struct ImageItem: Identifiable { let id = UUID(); let image: UIImage }
    private struct URLItem: Identifiable { let id = UUID(); let url: URL }
    private var viewerImageBinding: Binding<ImageItem?> {
        Binding(get: { viewerImage.map { ImageItem(image: $0) } }, set: { if $0 == nil { viewerImage = nil } })
    }
    private var viewerVideoBinding: Binding<URLItem?> {
        Binding(get: { viewerVideo.map { URLItem(url: $0) } }, set: { if $0 == nil { viewerVideo = nil } })
    }
    private var viewerFileBinding: Binding<URLItem?> {
        Binding(get: { viewerFile.map { URLItem(url: $0) } }, set: { if $0 == nil { viewerFile = nil } })
    }
}

// MARK: - Attachments

struct AttachmentView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    var attachment: Attachment
    var outgoing: Bool
    var onImage: (UIImage) -> Void
    var onVideo: (URL) -> Void
    var onFile: (URL) -> Void
    @State private var localURL: URL?
    @State private var loading = false
    @State private var failed = false
    @State private var image: UIImage?
    @State private var videoThumb: UIImage?
    @ObservedObject private var playback = AudioPlayback.shared

    private var isImage: Bool { attachment.mime.hasPrefix("image/") }
    private var isVideo: Bool { attachment.mime.hasPrefix("video/") }
    private var isAudio: Bool { attachment.mime.hasPrefix("audio/") || attachment.isVoice }

    var body: some View {
        Group {
            if isAudio {
                voiceView
            } else if isImage {
                imageView
            } else if isVideo {
                videoView
            } else {
                fileView
            }
        }
        .task(id: attachment.url) { await load() }
    }

    private func load() async {
        guard localURL == nil else { return }
        if let path = attachment.localPath, FileManager.default.fileExists(atPath: path) {
            localURL = URL(fileURLWithPath: path)
            if isImage { image = UIImage(contentsOfFile: path) }
            if isVideo { videoThumb = await VideoThumbnail.make(url: URL(fileURLWithPath: path)) }
            return
        }
        loading = true
        localURL = await AttachmentStore.shared.localFile(for: attachment, settings: app.settings)
        loading = false
        if let localURL {
            if isImage { image = UIImage(contentsOfFile: localURL.path) }
            if isVideo { videoThumb = await VideoThumbnail.make(url: localURL) }
        }
    }

    private func manualDownload() {
        guard !loading else { return }
        loading = true
        Task {
            do {
                let url = try await AttachmentStore.shared.download(attachment)
                localURL = url
                if isImage { image = UIImage(contentsOfFile: url.path) }
                if isVideo { videoThumb = await VideoThumbnail.make(url: url) }
            } catch {
                failed = true
            }
            loading = false
        }
    }

    private var imageHeight: CGFloat {
        guard attachment.width > 0, attachment.height > 0 else { return 190 }
        return min(340, max(140, 260 * CGFloat(attachment.height / attachment.width)))
    }

    private var imageView: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 260, height: imageHeight)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onTapGesture { onImage(image) }
                    .overlay(alignment: .bottomTrailing) {
                        if attachment.encrypted {
                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.white)
                                .padding(5).background(.black.opacity(0.45), in: Circle()).padding(6)
                        }
                    }
            } else {
                placeholder(icon: "photo", title: attachment.name)
            }
        }
    }

    private var videoView: some View {
        ZStack {
            if let videoThumb {
                Image(uiImage: videoThumb).resizable().scaledToFill()
            } else {
                palette.surfaceContainer
            }
            Circle().fill(.black.opacity(0.45)).frame(width: 46, height: 46)
            Image(systemName: "play.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(.white).offset(x: 2)
            VStack {
                Spacer()
                HStack {
                    if attachment.duration > 0 {
                        Text(WardFormat.duration(attachment.duration)).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    }
                    Spacer()
                }
                .padding(7)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom))
            }
        }
        .frame(width: 260, height: CGFloat(attachment.height > 0 ? min(330, 260 * attachment.height / max(attachment.width, 1)) : 180))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if let localURL { onVideo(localURL) } else { manualDownload() }
        }
    }

    private var voiceView: some View {
        HStack(spacing: 10) {
            Button {
                guard let localURL else { manualDownload(); return }
                AudioPlayback.shared.toggle(url: localURL, id: attachment.id, duration: attachment.duration)
            } label: {
                Image(systemName: playback.playingID == attachment.id ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(outgoing ? palette.accent : palette.onAccent)
                    .frame(width: 34, height: 34)
                    .background(outgoing ? Color.white : palette.accent, in: Circle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 2) {
                ForEach(0..<30, id: \.self) { index in
                    let base = bars[index % bars.count]
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill((outgoing ? Color.white : palette.accent).opacity(progress > Double(index) / 30 ? 1 : 0.35))
                        .frame(width: 2.5, height: CGFloat(max(4, base * 26)))
                }
            }
            Text(WardFormat.duration(attachment.duration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(outgoing ? Color.white.opacity(0.75) : palette.secondaryText)
        }
        .padding(.vertical, 3)
        .onAppear {
            if let path = attachment.localPath, FileManager.default.fileExists(atPath: path) {
                localURL = URL(fileURLWithPath: path)
            }
        }
    }

    private var progress: Double {
        playback.playingID == attachment.id ? playback.progress : 0
    }

    private var bars: [Double] {
        let seed = attachment.name.hashValue
        return (0..<14).map { index in
            let value = abs((seed &+ index &* 37) % 100)
            return 0.2 + Double(value) / 100 * 0.8
        }
    }

    private var fileView: some View {
        Button {
            if let localURL { onFile(localURL) } else { manualDownload() }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill((outgoing ? Color.white : palette.accent).opacity(0.14))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(outgoing ? Color.white : palette.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name.isEmpty ? "Attachment" : attachment.name)
                        .font(.subheadline.weight(.medium)).lineLimit(2)
                        .foregroundStyle(outgoing ? Color.white : palette.text)
                    Text(attachment.size > 0 ? WardFormat.bytes(attachment.size) : "Tap to download")
                        .font(.caption2).foregroundStyle(outgoing ? Color.white.opacity(0.7) : palette.secondaryText)
                }
                Spacer(minLength: 6)
                if loading {
                    ProgressView().controlSize(.small).tint(outgoing ? .white : palette.accent)
                } else {
                    Image(systemName: "arrow.down.circle").foregroundStyle(outgoing ? Color.white.opacity(0.8) : palette.accent)
                }
            }
            .padding(8)
            .background((outgoing ? Color.white : palette.accent).opacity(0.09), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var icon: String {
        if attachment.mime.hasPrefix("application/pdf") { return "doc.richtext" }
        if attachment.mime.hasPrefix("application/zip") { return "archivebox" }
        if attachment.mime.hasPrefix("text/") { return "doc.text" }
        return "doc.fill"
    }

    private func placeholder(icon: String, title: String) -> some View {
        Button(action: manualDownload) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(palette.surfaceContainer)
                    .frame(width: 250, height: 160)
                if loading {
                    ProgressView()
                } else {
                    VStack(spacing: 7) {
                        Image(systemName: failed ? "exclamationmark.triangle" : icon)
                            .font(.system(size: 28)).foregroundStyle(failed ? palette.danger : palette.secondaryText)
                        Text(failed ? "Download failed" : title).font(.caption).foregroundStyle(palette.secondaryText).lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

enum VideoThumbnail {
    static func make(url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        let time = CMTime(seconds: 0.15, preferredTimescale: 600)
        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, _ in
                continuation.resume(returning: image.map { UIImage(cgImage: $0) })
            }
        }
    }
}

// MARK: - Viewers

struct ImageViewer: View {
    var image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var drag: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.96 - Double(drag) / 900).ignoresSafeArea()
            Image(uiImage: image)
                .resizable().scaledToFit()
                .scaleEffect(zoom)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { zoom = max(1, min(5, $1)) }
                        .onEnded { _ in if zoom < 1.05 { withAnimation(.snappy) { zoom = 1 } } }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            if zoom <= 1.01 { drag = max(0, value.translation.height) }
                            offset = value.translation
                        }
                        .onEnded { value in
                            if value.translation.height > 130 && zoom <= 1.01 { dismiss() }
                            else { withAnimation(.snappy) { offset = .zero; drag = 0 } }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.snappy) { zoom = zoom > 1 ? 1 : 2.2 }
                }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white).padding(11).background(.black.opacity(0.45), in: Circle())
                    }
                }
                .padding()
                Spacer()
            }
        }
        .statusBarHidden()
    }
}

struct VideoPlayerScreen: View {
    var url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VideoPlayer(player: AVPlayer(url: url))
                .ignoresSafeArea()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .navigationTitle("Video")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct QuickLookScreen: UIViewControllerRepresentable {
    var url: URL
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

struct BubbleShape: Shape {
    var outgoing: Bool
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: 18, style: .continuous)
    }
}
