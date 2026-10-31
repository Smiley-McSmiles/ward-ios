import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import UIKit
import SwiftUI

enum ChatExport {
    static func html(chat: Chat, messages: [Message], contact: Contact?) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let title = chat.displayName
        let subtitle = chat.isGroup ? "Group chat · \(chat.jid)" : (contact?.jid ?? chat.jid)
        var rows = ""
        for message in messages {
            let sender = message.isOutgoing ? "You" : message.senderName
            let time = formatter.string(from: message.date)
            var body = message.retracted ? "<em>Message deleted</em>" : XML.escape(message.body)
                .replacingOccurrences(of: "\n", with: "<br>")
            if !message.reactions.isEmpty {
                let emoji = message.reactions.flatMap { $0.emoji }.joined(separator: " ")
                body += " <span class=\"reactions\">\(XML.escape(emoji))</span>"
            }
            var attachments = ""
            for attachment in message.attachments {
                let label = attachment.name.isEmpty ? "Attachment" : attachment.name
                attachments += "<div class=\"attachment\">📎 <a href=\"\(XML.escape(attachment.url))\">\(XML.escape(label))</a>"
                if attachment.size > 0 { attachments += " · \(WardFormat.bytes(attachment.size))" }
                attachments += "</div>"
            }
            rows += """
            <article class="\(message.isOutgoing ? "out" : "in")">
              <header><strong>\(XML.escape(sender))</strong><time>\(XML.escape(time))</time></header>
              <div class="body">\(body)</div>
              \(attachments)
            </article>
            """
        }
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(XML.escape(title)) · Ward</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 15px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; max-width: 760px; margin: 0 auto; padding: 28px 18px 60px; background: #f5f5fa; color: #17171c; }
        h1 { font-size: 26px; margin: 0 0 4px; }
        .meta { color: #777; font-size: 13px; margin-bottom: 26px; }
        article { margin: 0 0 12px; padding: 11px 14px; border-radius: 16px; background: #fff; box-shadow: 0 1px 2px rgba(0,0,0,.05); }
        article.out { background: #3584e4; color: #fff; margin-left: 16%; }
        article.in { margin-right: 16%; }
        header { display: flex; justify-content: space-between; gap: 12px; font-size: 11px; opacity: .72; margin-bottom: 4px; }
        .body { white-space: normal; overflow-wrap: anywhere; }
        .reactions { background: rgba(127,127,127,.18); border-radius: 8px; padding: 1px 5px; font-size: 12px; }
        .attachment { font-size: 12px; margin-top: 5px; opacity: .85; }
        a { color: inherit; }
        @media (prefers-color-scheme: dark) { body { background: #18151d; color: #eee; } article { background: #2b2632; } article.out { background: #356fae; } }
        </style>
        </head>
        <body>
        <h1>\(XML.escape(title))</h1>
        <div class="meta">\(XML.escape(subtitle)) · exported from Ward · \(formatter.string(from: Date()))</div>
        \(rows)
        </body>
        </html>
        """
    }

    static func write(chat: Chat, messages: [Message], contact: Contact?) throws -> URL {
        let safeName = chat.displayName.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ward-\(safeName)-\(Int(Date().timeIntervalSince1970)).html")
        try html(chat: chat, messages: messages, contact: contact).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}
