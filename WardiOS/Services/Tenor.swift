import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor TenorService {
    static let shared = TenorService()
    private var cache: [String: [String]] = [:]

    func search(_ query: String) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = trimmed.isEmpty ? "trending" : trimmed
        if let cached = cache[slug.lowercased()] { return cached }
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "trending"
        guard let url = URL(string: "https://tenor.com/search/\(encoded)-gifs") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return [] }
        let html = String(decoding: data, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: #"https://media\.tenor\.com/[^"'\s]+\.(?:gif|webp)"#) else { return [] }
        var seen: Set<String> = []
        var results: [String] = []
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let url = String(html[range]).replacingOccurrences(of: "\\u0026", with: "&")
            if seen.insert(url).inserted { results.append(url) }
            if results.count >= 40 { break }
        }
        cache[slug.lowercased()] = results
        return results
    }
}
