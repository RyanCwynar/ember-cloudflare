import Foundation
import SwiftUI

// Ember stores a message's body as Action Text markup (packages/richtext): paragraphs, inline
// formatting, links, code, quotes, lists, mentions (`<action-text-attachment sgid=…>`) and link
// previews (an attachment whose content-type is the opengraph embed's). This file parses that markup
// and turns it into blocks SwiftUI can draw, and turns what the composer holds back into markup.

// MARK: - Parsing

indirect enum HTMLNode: Equatable {
    case text(String)
    case element(name: String, attrs: [String: String], children: [HTMLNode])
}

enum HTMLParser {
    private static let voidElements: Set<String> = ["br", "img", "hr", "input", "meta", "link", "source", "wbr"]

    /// A forgiving parser for the canonical markup the room stores: it never throws, closes what's left
    /// open, and ignores stray end tags.
    static func parse(_ html: String) -> [HTMLNode] {
        final class Open {
            let name: String
            let attrs: [String: String]
            var children: [HTMLNode] = []
            init(_ name: String, _ attrs: [String: String]) { self.name = name; self.attrs = attrs }
        }
        let root = Open("#root", [:])
        var stack = [root]
        func append(_ node: HTMLNode) { stack[stack.count - 1].children.append(node) }
        func close(_ open: Open) -> HTMLNode { .element(name: open.name, attrs: open.attrs, children: open.children) }

        let chars = Array(html.unicodeScalars)
        var i = 0
        var text = String.UnicodeScalarView()
        func flushText() {
            if !text.isEmpty { append(.text(decodeEntities(String(text)))); text = String.UnicodeScalarView() }
        }

        while i < chars.count {
            let c = chars[i]
            guard c == "<" else { text.append(c); i += 1; continue }
            // Comments
            if i + 3 < chars.count, chars[i + 1] == "!", chars[i + 2] == "-", chars[i + 3] == "-" {
                flushText()
                var j = i + 4
                while j + 2 < chars.count, !(chars[j] == "-" && chars[j + 1] == "-" && chars[j + 2] == ">") { j += 1 }
                i = min(chars.count, j + 3)
                continue
            }
            // Find the tag's end, respecting quotes.
            var j = i + 1
            var quote: Unicode.Scalar?
            while j < chars.count {
                let d = chars[j]
                if let q = quote { if d == q { quote = nil } } else if d == "\"" || d == "'" { quote = d } else if d == ">" { break }
                j += 1
            }
            guard j < chars.count else { text.append(c); i += 1; continue }
            let inner = String(String.UnicodeScalarView(chars[(i + 1)..<j]))
            i = j + 1
            flushText()
            if inner.hasPrefix("/") {
                let name = inner.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
                guard let index = stack.lastIndex(where: { $0.name == name }), index > 0 else { continue }
                while stack.count > index {
                    let open = stack.removeLast()
                    append(close(open))
                }
                continue
            }
            if inner.hasPrefix("!") || inner.hasPrefix("?") { continue }
            let (name, attrs, selfClosing) = parseTag(inner)
            guard !name.isEmpty else { continue }
            if voidElements.contains(name) || selfClosing {
                append(.element(name: name, attrs: attrs, children: []))
            } else {
                stack.append(Open(name, attrs))
            }
        }
        flushText()
        while stack.count > 1 {
            let open = stack.removeLast()
            append(close(open))
        }
        return root.children
    }

    private static func parseTag(_ inner: String) -> (String, [String: String], Bool) {
        var s = Substring(inner)
        var selfClosing = false
        if s.hasSuffix("/") { selfClosing = true; s = s.dropLast() }
        let nameEnd = s.firstIndex(where: { $0.isWhitespace }) ?? s.endIndex
        let name = s[..<nameEnd].lowercased()
        var attrs: [String: String] = [:]
        var rest = s[nameEnd...]
        while true {
            rest = rest.drop(while: { $0.isWhitespace })
            guard !rest.isEmpty else { break }
            let keyEnd = rest.firstIndex(where: { $0 == "=" || $0.isWhitespace }) ?? rest.endIndex
            let key = rest[..<keyEnd].lowercased()
            rest = rest[keyEnd...].drop(while: { $0.isWhitespace })
            if rest.first == "=" {
                rest = rest.dropFirst().drop(while: { $0.isWhitespace })
                if let q = rest.first, q == "\"" || q == "'" {
                    rest = rest.dropFirst()
                    let end = rest.firstIndex(of: q) ?? rest.endIndex
                    attrs[key] = decodeEntities(String(rest[..<end]))
                    rest = end < rest.endIndex ? rest[rest.index(after: end)...] : rest[end...]
                } else {
                    let end = rest.firstIndex(where: { $0.isWhitespace }) ?? rest.endIndex
                    attrs[key] = decodeEntities(String(rest[..<end]))
                    rest = rest[end...]
                }
            } else if !key.isEmpty {
                attrs[key] = ""
            } else {
                rest = rest.dropFirst()
            }
        }
        return (name, attrs, selfClosing)
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#39": "'", "nbsp": "\u{00A0}",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let entity = String(s[s.index(after: i)..<semi])
                var replacement: String?
                if let value = named[entity] {
                    replacement = value
                } else if entity.hasPrefix("#x") || entity.hasPrefix("#X"), let code = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                    replacement = String(Character(scalar))
                } else if entity.hasPrefix("#"), let code = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(code) {
                    replacement = String(Character(scalar))
                }
                if let replacement {
                    out += replacement
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}

// MARK: - Blocks

struct LinkPreview: Hashable {
    let title: String
    let href: URL?
    let description: String
    let image: URL?
}

enum RichBlock: Hashable {
    case paragraph(AttributedString)
    case heading(AttributedString)
    case code(String)
    case quote([RichBlock])
    case list(ordered: Bool, items: [[RichBlock]])
    case preview(LinkPreview)
    case divider
}

/// Turns stored markup into blocks. `name(for:)` gives a mentioned person's current name.
struct RichTextRenderer {
    static let mentionContentType = "application/vnd.campfire.mention"
    static let previewContentType = "application/vnd.actiontext.opengraph-embed"
    /// Links in rendered text that open someone's profile rather than a web page.
    static let personScheme = "ember-person"

    var name: (String) -> String?
    var server: URL?

    func blocks(_ html: String) -> [RichBlock] {
        let blocks = blocks(of: HTMLParser.parse(html))
        return blocks.map(autolinked)
    }

    private static let blockNames: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "ul", "ol", "li", "hr", "table", "figure"]

    private func blocks(of nodes: [HTMLNode]) -> [RichBlock] {
        var result: [RichBlock] = []
        var inline: [HTMLNode] = []
        func flushInline() {
            let text = self.inline(inline, style: Style())
            if !text.characters.allSatisfy(\.isWhitespace) { result.append(.paragraph(trimmed(text))) }
            inline = []
        }
        for node in nodes {
            guard case let .element(name, attrs, children) = node else { inline.append(node); continue }
            if name == "action-text-attachment", attrs["content-type"] == Self.previewContentType {
                flushInline()
                result.append(.preview(preview(attrs)))
                continue
            }
            guard Self.blockNames.contains(name) else { inline.append(node); continue }
            flushInline()
            switch name {
            case "p", "figure":
                let text = self.inline(children, style: Style())
                if !text.characters.allSatisfy(\.isWhitespace) { result.append(.paragraph(trimmed(text))) }
            case "div", "li":
                result.append(contentsOf: blocks(of: children))
            case "h1", "h2", "h3", "h4", "h5", "h6":
                result.append(.heading(trimmed(self.inline(children, style: Style(bold: true)))))
            case "blockquote":
                result.append(.quote(blocks(of: children)))
            case "pre":
                result.append(.code(plainText(children)))
            case "ul", "ol":
                let items = children.compactMap { child -> [RichBlock]? in
                    guard case let .element("li", _, itemChildren) = child else { return nil }
                    return blocks(of: itemChildren)
                }
                result.append(.list(ordered: name == "ol", items: items))
            case "hr":
                result.append(.divider)
            case "table":
                // Tables are rare in chat; show each row as a line of cells.
                result.append(contentsOf: tableRows(children).map { .paragraph(AttributedString($0)) })
            default:
                break
            }
        }
        flushInline()
        return result
    }

    private struct Style {
        var bold = false
        var italic = false
        var strike = false
        var underline = false
        var code = false
        var highlight = false
        var link: URL?
    }

    private func inline(_ nodes: [HTMLNode], style: Style) -> AttributedString {
        var out = AttributedString()
        for node in nodes {
            switch node {
            case let .text(text):
                out += styled(text, style)
            case let .element(name, attrs, children):
                var s = style
                switch name {
                case "br":
                    out += AttributedString("\n")
                    continue
                case "strong", "b": s.bold = true
                case "em", "i": s.italic = true
                case "s", "del", "strike": s.strike = true
                case "u": s.underline = true
                case "code": s.code = true
                case "mark": s.highlight = true
                case "a":
                    if let href = attrs["href"], let url = URL(string: href, relativeTo: server)?.absoluteURL { s.link = url }
                case "action-text-attachment":
                    out += attachment(attrs)
                    continue
                case "img":
                    if let alt = attrs["alt"], !alt.isEmpty { out += styled(alt, s) }
                    continue
                default: break
                }
                out += inline(children, style: s)
            }
        }
        return out
    }

    private func styled(_ text: String, _ style: Style) -> AttributedString {
        var a = AttributedString(text)
        var font = Font.body
        if style.code { font = .system(.body, design: .monospaced) }
        if style.bold { font = font.bold() }
        if style.italic { font = font.italic() }
        a.font = font
        if style.strike { a.strikethroughStyle = .single }
        if style.underline { a.underlineStyle = .single }
        if style.code { a.backgroundColor = Color.secondary.opacity(0.15) }
        if style.highlight { a.backgroundColor = Color.yellow.opacity(0.35) }
        if let link = style.link { a.link = link }
        return a
    }

    private func attachment(_ attrs: [String: String]) -> AttributedString {
        guard let sgid = attrs["sgid"] else { return AttributedString() }
        let shown = name(sgid) ?? "someone"
        var a = AttributedString("@\(shown)")
        a.font = Font.body.weight(.semibold)
        a.foregroundColor = Brand.accent
        a.link = URL(string: "\(Self.personScheme):\(sgid)")
        return a
    }

    private func preview(_ attrs: [String: String]) -> LinkPreview {
        let href = attrs["href"].flatMap { URL(string: $0) }
        return LinkPreview(
            title: attrs["filename"] ?? attrs["href"] ?? "",
            href: href,
            description: attrs["description"] ?? "",
            image: attrs["url"].flatMap { URL(string: $0, relativeTo: server)?.absoluteURL })
    }

    private func plainText(_ nodes: [HTMLNode]) -> String {
        nodes.map { node -> String in
            switch node {
            case let .text(t): t
            case .element("br", _, _): "\n"
            case let .element(_, _, children): plainText(children)
            }
        }.joined()
    }

    private func tableRows(_ nodes: [HTMLNode]) -> [String] {
        var rows: [String] = []
        for node in nodes {
            guard case let .element(name, _, children) = node else { continue }
            if name == "tr" {
                let cells = children.compactMap { cell -> String? in
                    guard case let .element(n, _, c) = cell, n == "td" || n == "th" else { return nil }
                    return plainText(c).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                rows.append(cells.joined(separator: "  ·  "))
            } else {
                rows.append(contentsOf: tableRows(children))
            }
        }
        return rows
    }

    private func trimmed(_ text: AttributedString) -> AttributedString {
        var t = text
        while let first = t.characters.first, first == "\n" || first == " " { t.removeSubrange(t.startIndex..<t.index(afterCharacter: t.startIndex)) }
        while let last = t.characters.last, last == "\n" || last == " " { t.removeSubrange(t.index(beforeCharacter: t.endIndex)..<t.endIndex) }
        return t
    }

    // MARK: Autolinking

    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private func autolinked(_ block: RichBlock) -> RichBlock {
        switch block {
        case let .paragraph(text): .paragraph(autolink(text))
        case let .heading(text): .heading(autolink(text))
        case let .quote(blocks): .quote(blocks.map(autolinked))
        case let .list(ordered, items): .list(ordered: ordered, items: items.map { $0.map(autolinked) })
        default: block
        }
    }

    /// Links bare addresses in text that isn't already linked, as the web app's auto_link does.
    private func autolink(_ text: AttributedString) -> AttributedString {
        var text = text
        let plain = String(text.characters)
        let ns = plain as NSString
        for match in Self.detector.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, let range = Range(match.range, in: plain),
                  let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            if text[lower..<upper].runs.contains(where: { $0.link != nil }) { continue }
            text[lower..<upper].link = url
        }
        return text
    }
}

// MARK: - Composer markup

/// What the composer sends: its text with light Markdown and its @mentions turned into the markup the
/// room keeps. Mentions are matched by the exact "@Name" text the picker inserted.
enum ComposerMarkup {
    struct Mention: Hashable {
        let id: String
        let name: String
    }

    static func markup(from text: String, mentions: [Mention]) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var html = ""
        var paragraph: [String] = []
        var i = 0
        func flushParagraph() {
            // Blank lines inside a paragraph run separate paragraphs, as Lexxy writes them.
            if !paragraph.isEmpty {
                html += "<p>" + paragraph.map { inline($0, mentions) }.joined(separator: "<br>") + "</p>"
                paragraph = []
            }
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                html += "<pre>" + escape(code.joined(separator: "\n")) + "</pre>"
                i += 1
                continue
            }
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quoted.append(String(t.dropFirst().drop(while: { $0 == " " })))
                    i += 1
                }
                html += "<blockquote>" + quoted.map { inline($0, mentions) }.joined(separator: "<br>") + "</blockquote>"
                continue
            }
            if let marker = listMarker(trimmed) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, let m = listMarker(lines[i].trimmingCharacters(in: .whitespaces)), m.ordered == marker.ordered {
                    items.append(m.rest); i += 1
                }
                let tag = marker.ordered ? "ol" : "ul"
                html += "<\(tag)>" + items.map { "<li>\(inline($0, mentions))</li>" }.joined() + "</\(tag)>"
                continue
            }
            if trimmed.isEmpty { flushParagraph() } else { paragraph.append(line) }
            i += 1
        }
        flushParagraph()
        return html.isEmpty ? "<p></p>" : html
    }

    private static func listMarker(_ line: String) -> (ordered: Bool, rest: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") { return (false, String(line.dropFirst(2))) }
        if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
           line[line.index(after: dot)...].hasPrefix(" ") {
            return (true, String(line[line.index(dot, offsetBy: 2)...]))
        }
        return nil
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\u{00A0}", with: "&nbsp;")
    }

    /// Escapes a line, turns @mentions into attachments, and `code`, **bold**, *italic*/_italic_ and
    /// ~~strike~~ into their tags. Code spans are cut out first so their contents stay literal.
    static func inline(_ line: String, _ mentions: [Mention]) -> String {
        var out = ""
        var rest = Substring(line)
        while let tick = rest.firstIndex(of: "`") {
            let after = rest[rest.index(after: tick)...]
            guard let close = after.firstIndex(of: "`") else { break }
            out += formatted(String(rest[..<tick]), mentions)
            out += "<code>" + escape(String(after[..<close])) + "</code>"
            rest = after[after.index(after: close)...]
        }
        out += formatted(String(rest), mentions)
        return out
    }

    private static func formatted(_ text: String, _ mentions: [Mention]) -> String {
        // Protect mentions with placeholders before escaping and emphasis.
        var text = text
        var placeholders: [String: String] = [:]
        for (index, mention) in mentions.enumerated().sorted(by: { $0.element.name.count > $1.element.name.count }) {
            let token = "\u{E000}\(index)\u{E001}"
            if text.contains("@\(mention.name)") {
                text = text.replacingOccurrences(of: "@\(mention.name)", with: token)
                placeholders[token] = "<action-text-attachment content-type=\"\(RichTextRenderer.mentionContentType)\" sgid=\"\(escape(mention.id))\"></action-text-attachment>"
            }
        }
        var html = escape(text)
        html = replacePairs(html, "**", "strong")
        html = replacePairs(html, "~~", "s")
        html = replacePairs(html, "*", "em")
        html = replaceUnderscores(html)
        for (token, markup) in placeholders { html = html.replacingOccurrences(of: token, with: markup) }
        return html
    }

    private static func replacePairs(_ s: String, _ marker: String, _ tag: String) -> String {
        let parts = s.components(separatedBy: marker)
        guard parts.count >= 3 else { return s }
        var out = parts[0]
        var open = false
        for (index, part) in parts.dropFirst().enumerated() {
            let isLast = index == parts.count - 2
            if !open && isLast {
                out += marker + part  // an unpaired marker stays as typed
            } else {
                out += (open ? "</\(tag)>" : "<\(tag)>") + part
                open.toggle()
            }
        }
        return out
    }

    /// `_italic_` only at word boundaries, so snake_case names stay as typed.
    private static func replaceUnderscores(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\w])_([^_\n]+?)_(?![\w])"#) else { return s }
        return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "<em>$1</em>")
    }

    /// A stored body as the composer shows it for editing: light Markdown and "@Name" for mentions.
    static func editableText(from html: String, name lookup: (String) -> String?) -> (String, [Mention]) {
        var mentions: [Mention] = []
        func text(_ nodes: [HTMLNode]) -> String {
            nodes.map { node -> String in
                switch node {
                case let .text(t): return t
                case let .element(name, attrs, children):
                    switch name {
                    case "br": return "\n"
                    case "strong", "b": return "**\(text(children))**"
                    case "em", "i": return "*\(text(children))*"
                    case "s", "del", "strike": return "~~\(text(children))~~"
                    case "code": return "`\(text(children))`"
                    case "pre": return "```\n\(text(children))\n```\n"
                    case "p", "div", "h1", "h2", "h3", "h4", "h5", "h6": return text(children) + "\n\n"
                    case "blockquote": return text(children).split(separator: "\n", omittingEmptySubsequences: true).map { "> \($0)" }.joined(separator: "\n") + "\n\n"
                    case "ul", "ol":
                        var n = 0
                        return children.compactMap { child -> String? in
                            guard case let .element("li", _, c) = child else { return nil }
                            n += 1
                            return (name == "ol" ? "\(n). " : "- ") + text(c).trimmingCharacters(in: .newlines)
                        }.joined(separator: "\n") + "\n\n"
                    case "action-text-attachment":
                        if attrs["content-type"] == RichTextRenderer.previewContentType { return "" }
                        guard let id = attrs["sgid"] else { return "" }
                        let shown = lookup(id) ?? "someone"
                        mentions.append(Mention(id: id, name: shown))
                        return "@\(shown)"
                    default: return text(children)
                    }
                }
            }.joined()
        }
        let result = text(HTMLParser.parse(html)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (result, mentions)
    }
}
