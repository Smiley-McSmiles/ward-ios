import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftUI

struct LinkPreview: Codable, Identifiable, Hashable {
    var url: String
    var title: String = ""
    var summary: String = ""
    var imageURL: String = ""
    var siteName: String = ""
    var id: String { url }
}

/// Fetches Open Graph metadata for links in messages. Results are kept in memory only: the
/// preview tells the remote site that this device fetched the page, so it is never stored in the
/// chat database.
actor LinkPreviewService {
    static let shared = LinkPreviewService()
    private var cache: [String: LinkPreview] = [:]
    private var order: [String] = []

    func preview(for urlString: String) async -> LinkPreview? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        if let cached = cache[trimmed] { return cached }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Ward/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              data.count <= 1_500_000 else { return nil }
        let html = String(decoding: data.prefix(400_000), as: UTF8.self)
        var preview = LinkPreview(url: trimmed)
        let meta = Self.metaTags(html)
        preview.title = meta["og:title"] ?? meta["twitter:title"] ?? Self.titleTag(html) ?? ""
        preview.summary = meta["og:description"] ?? meta["twitter:description"] ?? meta["description"] ?? ""
        preview.imageURL = meta["og:image"] ?? meta["twitter:image"] ?? ""
        preview.siteName = meta["og:site_name"] ?? url.host ?? ""
        preview.title = Self.decode(preview.title)
        preview.summary = Self.decode(preview.summary)
        preview.siteName = Self.decode(preview.siteName)
        // Resolve relative image URLs.
        if !preview.imageURL.isEmpty, let image = URL(string: preview.imageURL, relativeTo: url)?.absoluteURL {
            preview.imageURL = image.absoluteString
        }
        guard !preview.title.isEmpty || !preview.summary.isEmpty else { return nil }
        store(preview, key: trimmed)
        return preview
    }

    private func store(_ preview: LinkPreview, key: String) {
        cache[key] = preview
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > 80 {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private static func metaTags(_ html: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"<meta\s+([^>]+)>"#, options: [.caseInsensitive]) else { return [:] }
        var output: [String: String] = [:]
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let attributes = String(html[range])
            let values = attributePairs(attributes)
            let key = (values["property"] ?? values["name"] ?? "").lowercased()
            guard !key.isEmpty, let content = values["content"], !content.isEmpty else { continue }
            output[key] = content
        }
        return output
    }

    private static func attributePairs(_ source: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*[\"']([^\"']*)[\"']"#) else { return [:] }
        var output: [String: String] = [:]
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let keyRange = Range(match.range(at: 1), in: source),
                  let valueRange = Range(match.range(at: 2), in: source) else { continue }
            output[String(source[keyRange]).lowercased()] = String(source[valueRange])
        }
        return output
    }

    private static func titleTag(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"<title[^>]*>(.*?)</title>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decode(_ value: String) -> String {
        XML.unescape(value)
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#x2F;", with: "/")
            .replacingOccurrences(of: "&#8217;", with: "’")
            .replacingOccurrences(of: "&#8211;", with: "–")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LinkPreviewCard: View {
    @Environment(\.ward) private var palette
    @Environment(\.openURL) private var openURL
    var urlString: String
    @State private var preview: LinkPreview? = nil
    @State private var loading = true

    var body: some View {
        Group {
            if let preview {
                Button {
                    if let url = URL(string: preview.url) { openURL(url) }
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        if !preview.imageURL.isEmpty, let imageURL = URL(string: preview.imageURL) {
                            AsyncImage(url: imageURL) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                } else {
                                    Rectangle().fill(palette.surfaceContainer)
                                }
                            }
                            .frame(height: 120)
                            .clipped()
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            if !preview.siteName.isEmpty {
                                Text(preview.siteName.uppercased())
                                    .font(.system(size: 8, weight: .bold)).tracking(0.7)
                                    .foregroundStyle(palette.tertiaryText)
                            }
                            Text(preview.title)
                                .font(.caption.weight(.semibold)).foregroundStyle(palette.text)
                                .lineLimit(2).multilineTextAlignment(.leading)
                            if !preview.summary.isEmpty {
                                Text(preview.summary)
                                    .font(.system(size: 10)).foregroundStyle(palette.secondaryText)
                                    .lineLimit(3).multilineTextAlignment(.leading)
                            }
                        }
                        .padding(9)
                    }
                    .frame(width: 260, alignment: .leading)
                    .background(palette.surface.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(palette.outline.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            } else if loading {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("Loading preview…").font(.system(size: 9)).foregroundStyle(palette.tertiaryText)
                }
                .frame(width: 260, alignment: .leading)
                .padding(8)
                .background(palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .task(id: urlString) {
            loading = true
            preview = await LinkPreviewService.shared.preview(for: urlString)
            loading = false
        }
    }
}
