import SwiftUI
import UIKit

// MARK: - Formatting

enum WardFormat {
    static func chatListTime(_ date: Date, settings: SettingsStore) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return time(date, settings: settings)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    static func time(_ date: Date, settings: SettingsStore) -> String {
        var format: Date.FormatStyle = settings.string("appearance.time_format", "system") == "12"
            ? .dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute()
            : settings.string("appearance.time_format") == "24"
                ? .dateTime.hour(.twoDigits(amPM: .omitted)).minute()
                : .dateTime.hour().minute()
        if settings.bool("appearance.time_seconds") {
            format = format.second()
        }
        return date.formatted(format)
    }

    static func dayHeader(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        return date.formatted(.dateTime.year().month(.wide).day())
    }

    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: value)
    }

    static func presence(_ contact: Contact?, state: ConnectionState?) -> String {
        guard let contact else { return state?.state == "online" ? "Online" : "Offline" }
        switch contact.presence {
        case "online", "available", "chat": return contact.status.isEmpty ? "Online" : contact.status
        case "away": return contact.status.isEmpty ? "Away" : contact.status
        case "dnd": return contact.status.isEmpty ? "Do not disturb" : contact.status
        case "xa": return contact.status.isEmpty ? "Away for a while" : contact.status
        default:
            if contact.lastSeen > 0 {
                return "Last seen " + Date(millis: contact.lastSeen).formatted(.relative(presentation: .named))
            }
            return "Offline"
        }
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    static func fingerprint(_ value: String) -> String {
        stride(from: 0, to: value.count, by: 8).map { index -> String in
            let start = value.index(value.startIndex, offsetBy: index)
            let end = value.index(start, offsetBy: min(8, value.count - index))
            return String(value[start..<end])
        }.joined(separator: " ")
    }
}

// MARK: - Haptics

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func soft() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}

// MARK: - Avatar

struct AvatarView: View {
    @Environment(\.ward) private var palette
    var name: String
    var jid: String = ""
    var size: CGFloat = 46
    var presence: String? = nil
    var imagePath: String? = nil
    var imageURL: String? = nil
    var group: Bool = false
    var rounded: Bool = false

    private var hue: Double {
        let source = name.isEmpty ? jid : name
        var hash: UInt64 = 5381
        for byte in source.utf8 { hash = ((hash << 5) &+ hash) &+ UInt64(byte) }
        return Double(hash % 360) / 360
    }
    private var initials: String {
        let source = name.isEmpty ? JID.local(jid) : name
        let words = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" }).prefix(2)
        let letters = words.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? String(source.prefix(2)).uppercased() : letters.uppercased()
    }
    private var gradient: LinearGradient {
        LinearGradient(colors: [
            Color(hue: hue, saturation: 0.55, brightness: 0.78),
            Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.62, brightness: 0.58)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let path = imagePath, let image = UIImage(contentsOfFile: path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if let urlString = imageURL, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: size, height: size)
            .clipShape(rounded || !group ? RoundedRectangle(cornerRadius: rounded ? size * 0.28 : size / 2, style: .continuous)
                       : RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .overlay {
                if group && !rounded {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .strokeBorder(palette.outline.opacity(0.25), lineWidth: 0.5)
                }
            }
            .shadow(color: .black.opacity(0.12), radius: size > 50 ? 10 : 4, y: 3)

            if let presence, size >= 32 {
                PresenceDot(show: presence, size: max(9, size * 0.24))
                    .offset(x: 1, y: 1)
            }
        }
        .accessibilityLabel(Text(name.isEmpty ? JID.local(jid) : name))
    }

    private var placeholder: some View {
        ZStack {
            gradient
            if group {
                Image(systemName: "person.3.fill")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            } else {
                Text(initials)
                    .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }
}

struct PresenceDot: View {
    @Environment(\.ward) private var palette
    var show: String
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(palette.presenceColor(show))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(palette.background, lineWidth: max(1.5, size * 0.2)))
            .accessibilityHidden(true)
    }
}

// MARK: - Common controls

struct IconTile: View {
    @Environment(\.ward) private var palette
    var icon: String
    var color: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct WardCard<Content: View>: View {
    @Environment(\.ward) private var palette
    @ViewBuilder var content: Content
    var padding: CGFloat = 16

    var body: some View {
        content
            .padding(padding)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(palette.outline.opacity(0.35), lineWidth: 0.5)
            }
    }
}

struct WardPrimaryButtonStyle: ButtonStyle {
    @Environment(\.ward) private var palette
    var fullWidth = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(palette.onAccent)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(palette.accent, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

struct WardSecondaryButtonStyle: ButtonStyle {
    @Environment(\.ward) private var palette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(palette.text)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(palette.surfaceContainer, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

struct EmptyStateView: View {
    @Environment(\.ward) private var palette
    var icon: String
    var title: String
    var subtitle: String
    var action: (() -> Void)? = nil
    var actionTitle: String = ""

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(palette.accent.opacity(0.10)).frame(width: 92, height: 92)
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .symbolEffect(.pulse, options: .repeating.speed(0.35), isActive: true)
            }
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(palette.text)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let action {
                Button(actionTitle, action: action).buttonStyle(WardPrimaryButtonStyle(fullWidth: false))
                    .padding(.top, 6)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SectionHeader: View {
    @Environment(\.ward) private var palette
    var title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.7)
                .foregroundStyle(palette.tertiaryText)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(palette.tertiaryText)
            }
        }
        .padding(.leading, 4)
    }
}

struct SettingsRow: View {
    @Environment(\.ward) private var palette
    var icon: String
    var iconColor: Color
    var title: String
    var subtitle: String? = nil
    var value: String? = nil
    var chevron = true
    var body: some View {
        HStack(spacing: 12) {
            IconTile(icon: icon, color: iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(palette.text)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(palette.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value).font(.subheadline).foregroundStyle(palette.secondaryText).lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    .foregroundStyle(palette.tertiaryText.opacity(0.7))
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

// MARK: - Feedback

struct ToastView: View {
    @Environment(\.ward) private var palette
    var text: String
    var error: Bool = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(error ? palette.danger : palette.success)
            Text(text).font(.subheadline.weight(.medium)).foregroundStyle(palette.text)
                .lineLimit(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.outline.opacity(0.3), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 16, y: 8)
        .padding(.horizontal, 20)
    }
}

struct TypingDots: View {
    @Environment(\.ward) private var palette
    var color: Color? = nil
    var body: some View {
        PhaseAnimator([0, 1, 2]) { active in
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(color ?? palette.secondaryText)
                        .frame(width: 5, height: 5)
                        .offset(y: active == index ? -3 : 0)
                        .opacity(active == index ? 1 : 0.45)
                }
            }
        } animation: { _ in
            .easeInOut(duration: 0.32)
        }
    }
}

struct ConnectionPill: View {
    @Environment(\.ward) private var palette
    var state: ConnectionState
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.7), radius: 4)
                .symbolEffect(.pulse, isActive: state.state == "connecting")
            Text(state.label).font(.caption2.weight(.medium)).foregroundStyle(palette.secondaryText)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(palette.surfaceContainer.opacity(0.85), in: Capsule())
        .animation(.snappy, value: state.state)
    }
    private var color: Color {
        switch state.state {
        case "online": return palette.success
        case "connecting": return palette.warning
        case "error": return palette.danger
        default: return palette.tertiaryText
        }
    }
}


// MARK: - Glass background

struct WardBackground: View {
    @Environment(\.ward) private var palette
    var body: some View {
        ZStack {
            palette.background
            RadialGradient(colors: [palette.accent.opacity(palette.dark ? 0.15 : 0.07), .clear],
                           center: .topTrailing, startRadius: 10, endRadius: 520)
            RadialGradient(colors: [Color(hex: "#9141AC").opacity(palette.dark ? 0.09 : 0.04), .clear],
                           center: .bottomLeading, startRadius: 10, endRadius: 440)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Async loading image with local cache

final class ImageLoader: ObservableObject {
    @Published var image: UIImage? = nil
    private var task: URLSessionDataTask?
    private static let cache = NSCache<NSString, UIImage>()

    func load(_ url: URL?) {
        guard let url else { return }
        if let cached = Self.cache.object(forKey: url.absoluteString as NSString) {
            image = cached; return
        }
        task?.cancel()
        task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            Self.cache.setObject(image, forKey: url.absoluteString as NSString)
            DispatchQueue.main.async { self?.image = image }
        }
        task?.resume()
    }

    deinit { task?.cancel() }
}
