import UIKit
import SwiftUI

struct MarkdownView: View {
    @Environment(\.ward) private var palette
    var text: String
    var foreground: Color
    var outgoing: Bool = false
    var compact: Bool = false

    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            ForEach(blocks) { block in
                switch block {
                case .paragraph(let content):
                    Text(inline(content))
                        .fixedSize(horizontal: false, vertical: true)
                case .heading(let level, let content):
                    Text(inline(content))
                        .font(.system(size: level == 1 ? 20 : level == 2 ? 18 : 16, weight: .bold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let content):
                    CodeBlockView(language: language, code: content, outgoing: outgoing)
                case .quote(let content):
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(outgoing ? Color.white.opacity(0.55) : palette.accent)
                            .frame(width: 3)
                        Text(inline(content))
                            .foregroundStyle(foreground.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 1)
                case .list(let ordered, let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(ordered ? "\(index + 1)." : "•")
                                    .font(.system(.body, design: .rounded).weight(.semibold))
                                    .foregroundStyle(outgoing ? foreground.opacity(0.8) : palette.accent)
                                    .frame(minWidth: ordered ? 18 : 8, alignment: .trailing)
                                Text(inline(item))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case .table(let headers, let rows):
                    TableBlock(headers: headers, rows: rows, foreground: foreground, accent: palette.accent)
                case .divider:
                    Rectangle().fill(foreground.opacity(0.2)).frame(height: 1).padding(.vertical, 3)
                }
            }
        }
        .foregroundStyle(foreground)
        .tint(outgoing ? foreground : palette.accent)
        .textSelection(.enabled)
    }

    private func inline(_ string: String) -> AttributedString {
        var value = (try? AttributedString(markdown: string,
                                           options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(string)
        for run in value.runs {
            value[run.range].foregroundColor = foreground
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                value[run.range].font = .system(size: compact ? 13 : 14, design: .monospaced)
                value[run.range].backgroundColor = foreground.opacity(0.12)
            }
        }
        return value
    }
}

enum MarkdownBlock: Identifiable {
    case paragraph(String)
    case heading(Int, String)
    case code(String, String)
    case quote(String)
    case list(Bool, [String])
    case table([String], [[String]])
    case divider

    var id: String {
        switch self {
        case .paragraph(let text): return "p-\(text.hashValue)"
        case .heading(let level, let text): return "h-\(level)-\(text.hashValue)"
        case .code(let language, let code): return "c-\(language)-\(code.hashValue)"
        case .quote(let text): return "q-\(text.hashValue)"
        case .list(let ordered, let items): return "l-\(ordered)-\(items.joined().hashValue)"
        case .table(let headers, let rows): return "t-\(headers.joined())-\(rows.joined().hashValue)"
        case .divider: return "d-\(UUID().uuidString)"
        }
    }

    static func parse(_ input: String) -> [MarkdownBlock] {
        guard !input.isEmpty else { return [] }
        let lines = input.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flush()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index]); index += 1
                }
                blocks.append(.code(language, code.joined(separator: "\n")))
                index += 1
                continue
            }
            if trimmed.isEmpty {
                flush(); index += 1; continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush(); blocks.append(.divider); index += 1; continue
            }
            if trimmed.hasPrefix("#") {
                flush()
                let hashes = trimmed.prefix { $0 == "#" }.count
                let content = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(min(hashes, 3), content))
                index += 1; continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    quote.append(current.dropFirst().trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
                || trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                flush()
                let ordered = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
                var items: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    if current.hasPrefix("- ") || current.hasPrefix("* ") || current.hasPrefix("+ ") {
                        items.append(String(current.dropFirst(2)))
                    } else if ordered, current.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil,
                              let dot = current.firstIndex(of: ".") {
                        items.append(String(current[current.index(after: dot)...]).trimmingCharacters(in: .whitespaces))
                    } else { break }
                    index += 1
                }
                blocks.append(.list(ordered, items))
                continue
            }
            if trimmed.contains("|"), index + 1 < lines.count,
               lines[index + 1].trimmingCharacters(in: .whitespaces).range(of: #"^\|?[\s:|-]+\|[\s:|-]*$"#, options: .regularExpression) != nil {
                flush()
                let headers = splitRow(trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|") {
                    rows.append(splitRow(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                blocks.append(.table(headers, rows))
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flush()
        return blocks
    }

    private static func splitRow(_ line: String) -> [String] {
        var value = line
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

private struct CodeBlockView: View {
    @Environment(\.ward) private var palette
    var language: String
    var code: String
    var outgoing: Bool
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language.lowercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(outgoing ? Color.white.opacity(0.65) : palette.secondaryText)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Haptics.tap()
                    Task {
                        try? await Task.sleep(nanoseconds: 1_400_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(outgoing ? Color.white.opacity(0.7) : palette.secondaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyntaxHighlighter.highlight(code, language: language, base: outgoing ? .white : palette.text))
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 11).padding(.bottom, 10)
            }
        }
        .background(outgoing ? Color.black.opacity(0.22) : palette.surfaceContainer, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TableBlock: View {
    var headers: [String]
    var rows: [[String]]
    var foreground: Color
    var accent: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        Text(header).font(.caption.weight(.bold)).foregroundStyle(foreground)
                            .padding(.bottom, 3)
                    }
                }
                Rectangle().fill(foreground.opacity(0.2)).frame(height: 1).gridCellColumns(max(1, headers.count))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            Text(cell).font(.caption).foregroundStyle(index == 0 ? foreground : foreground.opacity(0.86))
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(foreground.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

enum SyntaxHighlighter {
    static func highlight(_ code: String, language: String, base: Color) -> AttributedString {
        var result = AttributedString(code)
        result.foregroundColor = base
        let keywords = ["func", "let", "var", "if", "else", "for", "while", "return", "class", "struct",
                        "enum", "import", "public", "private", "static", "async", "await", "try", "catch",
                        "def", "in", "with", "from", "as", "True", "False", "None", "null", "true", "false",
                        "const", "function", "new", "this", "switch", "case", "break", "continue", "throw",
                        "in", "is", "not", "and", "or", "nil", "guard", "defer", "protocol", "extension"]
        let ns = code as NSString
        let keywordPattern = "\\b(" + keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")\\b"
        apply(pattern: keywordPattern, color: Color(hex: "#C586C0"), code: code, ns: ns, result: &result)
        apply(pattern: "#[^\\n]*", color: Color(hex: "#6A9955"), code: code, ns: ns, result: &result)
        apply(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", color: Color(hex: "#CE9178"), code: code, ns: ns, result: &result)
        apply(pattern: "\\b\\d+(?:\\.\\d+)?\\b", color: Color(hex: "#B5CEA8"), code: code, ns: ns, result: &result)
        return result
    }

    private static func apply(pattern: String, color: Color, code: String, ns: NSString, result: inout AttributedString) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        for match in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            guard let swiftRange = Range(match.range, in: code),
                  let lower = AttributedString.Index(swiftRange.lowerBound, within: result),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: result) else { continue }
            result[lower..<upper].foregroundColor = color
        }
    }
}
