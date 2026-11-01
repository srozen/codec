import Foundation

/// Turns Markdown (CommonMark's common ground plus GitHub's tables, task lists, strikethrough and
/// autolinks) into an HTML fragment for the preview. Code blocks are colored by `SyntaxHighlighter`,
/// as `<span class="hl-keyword">` and so on.
public struct MarkdownRenderer: Sendable {
    /// Rewrites an image's source, so relative paths can be served to the preview.
    public var resolveImage: @Sendable (String) -> String
    /// Puts Run and Insert links on shell code blocks: `codec-run:run/N` and `codec-run:insert/N`, N
    /// counting shell blocks from 0 in the order `shellBlocks(in:)` lists them.
    public var runnableShellBlocks: Bool
    private var shellBlocks: ShellBlocks?

    public static let runScheme = "codec-run"

    private final class ShellBlocks: @unchecked Sendable {
        var code: [String] = []
    }

    public init(runnableShellBlocks: Bool = false, resolveImage: @escaping @Sendable (String) -> String = { $0 }) {
        self.runnableShellBlocks = runnableShellBlocks
        self.resolveImage = resolveImage
    }

    public func html(from markdown: String) -> String {
        render(markdown).html
    }

    /// The HTML, and the shell code blocks in it, in order.
    public func render(_ markdown: String) -> (html: String, shellBlocks: [String]) {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        // A YAML header (as Intel files have) is metadata, not part of the document.
        if let (_, body) = FrontMatter.split(text) { text = body }
        let lines = text.replacingOccurrences(of: "\t", with: "    ").components(separatedBy: "\n")
        var renderer = self
        let collected = ShellBlocks()
        renderer.shellBlocks = collected
        var slugs: [String: Int] = [:]
        let html = renderer.blocks(lines[...], tight: false, slugs: &slugs)
        return (html, collected.code)
    }

    /// The shell code blocks in a document, in order.
    public static func shellBlocks(in markdown: String) -> [String] {
        MarkdownRenderer().render(markdown).shellBlocks
    }

    // MARK: Blocks

    private func blocks(_ lines: ArraySlice<String>, tight: Bool, slugs: inout [String: Int]) -> String {
        var html = ""
        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }
            let indent = Self.indentation(line)

            if indent >= 4, !tight {
                var end = index
                var code: [String] = []
                while end < lines.endIndex, Self.indentation(lines[end]) >= 4 || lines[end].trimmingCharacters(in: .whitespaces).isEmpty {
                    code.append(String(lines[end].dropFirst(min(4, Self.indentation(lines[end])))))
                    end += 1
                }
                while code.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { code.removeLast() }
                html += "<pre><code>" + Self.escape(code.joined(separator: "\n")) + "</code></pre>\n"
                index = end
                continue
            }
            if let fence = Self.fence(trimmed), indent < 4 {
                var end = index + 1
                var code: [String] = []
                while end < lines.endIndex, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix(fence.marker) {
                    code.append(String(lines[end].dropFirst(min(indent, Self.indentation(lines[end])))))
                    end += 1
                }
                html += codeBlock(code.joined(separator: "\n"), info: fence.info)
                index = min(end + 1, lines.endIndex)
                continue
            }
            if let heading = Self.heading(trimmed) {
                html += headingHTML(level: heading.level, text: heading.text, slugs: &slugs)
                index += 1
                continue
            }
            if Self.isRule(trimmed) {
                html += "<hr>\n"
                index += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                var end = index
                var quoted: [String] = []
                while end < lines.endIndex {
                    let current = lines[end].trimmingCharacters(in: .whitespaces)
                    if current.hasPrefix(">") {
                        var rest = current.dropFirst()
                        if rest.first == " " { rest = rest.dropFirst() }
                        quoted.append(String(rest))
                    } else if !current.isEmpty, !quoted.isEmpty, !(quoted.last ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
                              !startsBlock(current) {
                        quoted.append(current)  // A lazy continuation of the quoted paragraph.
                    } else {
                        break
                    }
                    end += 1
                }
                html += "<blockquote>\n" + blocks(quoted[...], tight: false, slugs: &slugs) + "</blockquote>\n"
                index = end
                continue
            }
            if Self.listItem(line) != nil {
                index = list(lines, from: index, into: &html, slugs: &slugs)
                continue
            }
            if index + 1 < lines.endIndex, trimmed.contains("|"), let alignments = Self.tableAlignments(lines[index + 1]) {
                index = table(lines, from: index, alignments: alignments, into: &html)
                continue
            }
            if trimmed.hasPrefix("<"), let second = trimmed.dropFirst().first, second.isLetter || second == "!" || second == "/" {
                var end = index
                var raw: [String] = []
                while end < lines.endIndex, !lines[end].trimmingCharacters(in: .whitespaces).isEmpty {
                    raw.append(lines[end])
                    end += 1
                }
                html += raw.joined(separator: "\n") + "\n"
                index = end
                continue
            }
            // A paragraph, perhaps underlined into a heading.
            var end = index
            var text: [String] = []
            while end < lines.endIndex {
                let current = lines[end]
                let currentTrimmed = current.trimmingCharacters(in: .whitespaces)
                if currentTrimmed.isEmpty { break }
                if end > index {
                    if let level = Self.setextLevel(currentTrimmed) {
                        html += headingHTML(level: level, text: text.joined(separator: " "), slugs: &slugs)
                        text = []
                        end += 1
                        break
                    }
                    if startsBlock(currentTrimmed) || Self.listItem(current) != nil { break }
                }
                text.append(current)
                end += 1
            }
            if !text.isEmpty {
                let content = inline(Self.joinLines(text))
                html += tight ? content + "\n" : "<p>" + content + "</p>\n"
            }
            index = end
        }
        return html
    }

    /// Whether a line starts a block that interrupts a paragraph.
    private func startsBlock(_ trimmed: String) -> Bool {
        Self.fence(trimmed) != nil || Self.heading(trimmed) != nil || Self.isRule(trimmed) || trimmed.hasPrefix(">")
    }

    private func headingHTML(level: Int, text: String, slugs: inout [String: Int]) -> String {
        var slug = Self.slug(text)
        if let count = slugs[slug] {
            slugs[slug] = count + 1
            slug += "-\(count)"
        } else {
            slugs[slug] = 1
        }
        return "<h\(level) id=\"\(slug)\">" + inline(text) + "</h\(level)>\n"
    }

    private func codeBlock(_ code: String, info: String) -> String {
        let language = SourceLanguage.of(fence: info)
        let label = info.split(separator: " ").first.map { " data-language=\"\(Self.escape(String($0)))\"" } ?? ""
        let pre = "<pre\(label)><code>" + Self.highlighted(code, language: language) + "</code></pre>\n"
        guard language == .shell, let shellBlocks else { return pre }
        let index = shellBlocks.code.count
        shellBlocks.code.append(code)
        guard runnableShellBlocks else { return pre }
        return "<div class=\"run\"><a href=\"\(Self.runScheme):run/\(index)\">▶ Run</a>"
            + "<a href=\"\(Self.runScheme):insert/\(index)\">Insert</a></div>\n" + pre
    }

    /// Code as HTML with its tokens wrapped in classed spans.
    public static func highlighted(_ code: String, language: SourceLanguage) -> String {
        let string = code as NSString
        var html = ""
        var position = 0
        for span in SyntaxHighlighter.spans(in: code, language: language) where span.location >= position {
            html += escape(string.substring(with: NSRange(location: position, length: span.location - position)))
            html += "<span class=\"hl-\(span.token.rawValue)\">" + escape(string.substring(with: span.range)) + "</span>"
            position = span.location + span.length
        }
        return html + escape(string.substring(from: min(position, string.length)))
    }

    // MARK: Lists

    private struct ListItem {
        var indent: Int
        var ordered: Bool
        var number: Int
        /// Where the item's text starts.
        var contentIndent: Int
        var text: String
    }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = indentation(line)
        let body = line.dropFirst(indent)
        guard let first = body.first else { return nil }
        if "-*+".contains(first) {
            let rest = body.dropFirst()
            guard rest.isEmpty || rest.first == " " else { return nil }
            let text = rest.drop(while: { $0 == " " })
            // "* * *" and "---" are rules.
            if isRule(String(body)) { return nil }
            return ListItem(indent: indent, ordered: false, number: 0, contentIndent: indent + 1 + min(4, max(1, rest.count - text.count)), text: String(text))
        }
        let digits = body.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let afterDigits = body.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
        let rest = afterDigits.dropFirst()
        guard rest.isEmpty || rest.first == " " else { return nil }
        let text = rest.drop(while: { $0 == " " })
        return ListItem(indent: indent, ordered: true, number: Int(digits) ?? 1, contentIndent: indent + digits.count + 1 + min(4, max(1, rest.count - text.count)),
                        text: String(text))
    }

    /// Renders the list starting at `start`; returns the line after it.
    private func list(_ lines: ArraySlice<String>, from start: Int, into html: inout String, slugs: inout [String: Int]) -> Int {
        guard let first = Self.listItem(lines[start]) else { return start + 1 }
        var items: [[String]] = []
        var index = start
        var loose = false
        var sawBlank = false
        while index < lines.endIndex {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                sawBlank = true
                if !items.isEmpty { items[items.count - 1].append("") }
                index += 1
                continue
            }
            if let item = Self.listItem(line), item.indent < first.contentIndent, item.indent >= first.indent - 3 {
                guard item.ordered == first.ordered else { break }
                if sawBlank, !items.isEmpty { loose = true }
                sawBlank = false
                items.append([item.text])
                index += 1
                continue
            }
            let indent = Self.indentation(line)
            if indent >= first.contentIndent || (!sawBlank && !startsBlock(line.trimmingCharacters(in: .whitespaces))) {
                if sawBlank { loose = true }
                sawBlank = false
                items[items.count - 1].append(String(line.dropFirst(min(indent, first.contentIndent))))
                index += 1
                continue
            }
            break
        }
        // A blank line after the last item doesn't make the list loose.
        let tag = first.ordered ? "ol" : "ul"
        let startAttribute = first.ordered && first.number != 1 ? " start=\"\(first.number)\"" : ""
        let tasks = items.contains { Self.taskState($0.first ?? "") != nil }
        html += "<\(tag)\(startAttribute)\(tasks ? " class=\"tasks\"" : "")>\n"
        for var item in items {
            while item.last?.isEmpty == true { item.removeLast() }
            var checkbox = ""
            if let state = Self.taskState(item[0]) {
                checkbox = "<input type=\"checkbox\" disabled\(state ? " checked" : "")> "
                item[0] = String(item[0].dropFirst(4))
            }
            let content = blocks(item[...], tight: !loose, slugs: &slugs)
            html += "<li>" + checkbox + content.trimmingCharacters(in: .newlines) + "</li>\n"
        }
        html += "</\(tag)>\n"
        return index
    }

    private static func taskState(_ text: String) -> Bool? {
        if text.hasPrefix("[ ] ") || text == "[ ]" { return false }
        if text.lowercased().hasPrefix("[x] ") || text.lowercased() == "[x]" { return true }
        return nil
    }

    // MARK: Tables

    private enum Alignment { case none, left, center, right }

    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = []
        var current = ""
        var previous: Character = " "
        var inCode = false
        for character in trimmed {
            if character == "`" { inCode.toggle() }
            if character == "|", previous != "\\", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    private static func tableAlignments(_ line: String) -> [Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.allSatisfy({ "|:- ".contains($0) }) else { return nil }
        let alignments = cells(line).map { cell -> Alignment? in
            guard cell.contains("-"), cell.allSatisfy({ ":-".contains($0) }) else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (true, false): return .left
            case (false, true): return .right
            default: return Alignment.none
            }
        }
        guard !alignments.contains(where: { $0 == nil }) else { return nil }
        return alignments.compactMap { $0 }
    }

    private func table(_ lines: ArraySlice<String>, from start: Int, alignments: [Alignment], into html: inout String) -> Int {
        func row(_ cells: [String], tag: String) -> String {
            var html = "<tr>"
            for (index, alignment) in alignments.enumerated() {
                let style = switch alignment {
                case .none: ""
                case .left: " style=\"text-align:left\""
                case .center: " style=\"text-align:center\""
                case .right: " style=\"text-align:right\""
                }
                html += "<\(tag)\(style)>" + inline(index < cells.count ? cells[index] : "") + "</\(tag)>"
            }
            return html + "</tr>\n"
        }
        html += "<table>\n<thead>\n" + row(Self.cells(lines[start]), tag: "th") + "</thead>\n<tbody>\n"
        var index = start + 2
        while index < lines.endIndex, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            html += row(Self.cells(lines[index]), tag: "td")
            index += 1
        }
        html += "</tbody>\n</table>\n"
        return index
    }

    // MARK: Inline

    /// Inline Markdown as HTML. Code spans and the HTML made along the way are set aside while
    /// emphasis is found, so underscores in URLs and code stay put.
    func inline(_ text: String) -> String {
        var stash: [String] = []
        func keep(_ html: String) -> String {
            stash.append(html)
            return "\u{E000}\(stash.count - 1)\u{E001}"
        }

        // Code spans, backslash escapes, then everything else is escaped.
        var output = ""
        var characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, "\\`*_{}[]()#+-.!|~<>".contains(characters[index + 1]) {
                output += keep(Self.escape(String(characters[index + 1])))
                index += 2
                continue
            }
            if character == "`" {
                var run = 0
                while index + run < characters.count, characters[index + run] == "`" { run += 1 }
                var close = index + run
                while close < characters.count {
                    if characters[close] == "`" {
                        var closeRun = 0
                        while close + closeRun < characters.count, characters[close + closeRun] == "`" { closeRun += 1 }
                        if closeRun == run { break }
                        close += closeRun
                    } else {
                        close += 1
                    }
                }
                if close < characters.count {
                    var code = String(characters[(index + run)..<close])
                    if code.hasPrefix(" "), code.hasSuffix(" "), code.count > 1 { code = String(code.dropFirst().dropLast()) }
                    output += keep("<code>" + Self.escape(code) + "</code>")
                    index = close + run
                    continue
                }
                output += String(repeating: "`", count: run)
                index += run
                continue
            }
            output.append(character)
            index += 1
        }
        characters = []
        var html = Self.escape(output)

        // Images, then links: the URL is set aside; link text keeps its formatting.
        html = Self.replace(#"!\[([^\]]*)\]\(\s*([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\s*\)"#, in: html) { groups in
            let source = resolveImage(Self.unescape(groups[2]))
            return keep("<img src=\"\(Self.escape(source))\" alt=\"\(groups[1])\">")
        }
        html = Self.replace(#"\[([^\]]+)\]\(\s*([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\s*\)"#, in: html) { groups in
            keep("<a href=\"\(groups[2])\">") + groups[1] + keep("</a>")
        }
        html = Self.replace(#"&lt;((?:https?|mailto):[^\s&]+)&gt;"#, in: html) { groups in
            keep("<a href=\"\(groups[1])\">\(groups[1])</a>")
        }
        html = Self.replace(#"(?<![\w/])(https?://[^\s<\x{E000}]+[^\s<.,:;!?)\]\x{E000}])"#, in: html) { groups in
            keep("<a href=\"\(groups[1])\">\(groups[1])</a>")
        }
        html = Self.replace(#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, in: html) { "<strong>\($0[1])</strong>" }
        html = Self.replace(#"(?<![\w])__(?=\S)(.+?)(?<=\S)__(?![\w])"#, in: html) { "<strong>\($0[1])</strong>" }
        html = Self.replace(#"(?<![\*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\*\w])"#, in: html) { "<em>\($0[1])</em>" }
        html = Self.replace(#"(?<![_\w])_(?=\S)(.+?)(?<=\S)_(?![_\w])"#, in: html) { "<em>\($0[1])</em>" }
        html = Self.replace(#"~~(?=\S)(.+?)(?<=\S)~~"#, in: html) { "<del>\($0[1])</del>" }
        html = html.replacingOccurrences(of: "\u{E002}", with: "<br>")

        // Put back what was set aside; it can nest, so repeat until nothing's left.
        for _ in 0..<8 where html.contains("\u{E000}") {
            html = Self.replace(#"\x{E000}(\d+)\x{E001}"#, in: html) { stash[Int($0[1]) ?? 0] }
        }
        return html
    }

    /// Joins a paragraph's lines, keeping hard breaks (two trailing spaces or a backslash).
    private static func joinLines(_ lines: [String]) -> String {
        var joined = ""
        for (index, line) in lines.enumerated() {
            var text = line.trimmingCharacters(in: .whitespaces)
            let last = index == lines.count - 1
            if !last, line.hasSuffix("  ") {
                joined += text + "\u{E002}"
            } else if !last, text.hasSuffix("\\") {
                text.removeLast()
                joined += text + "\u{E002}"
            } else {
                joined += text + (last ? "" : "\n")
            }
        }
        return joined
    }

    // MARK: Helpers

    private static func indentation(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func fence(_ trimmed: String) -> (marker: String, info: String)? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            let info = trimmed.drop(while: { $0 == marker.first }).trimmingCharacters(in: .whitespaces)
            if marker == "```", info.contains("`") { return nil }
            return (marker, info)
        }
        return nil
    }

    private static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Closing hashes are decoration.
        if let range = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(range) }
        if text.allSatisfy({ $0 == "#" }) { text = "" }
        return (hashes, text)
    }

    private static func setextLevel(_ trimmed: String) -> Int? {
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }), trimmed.count >= 2 { return 2 }
        return nil
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    /// A heading's anchor, as GitHub makes them.
    static func slug(_ text: String) -> String {
        let plain = text.replacingOccurrences(of: #"[`*_~\[\]()]"#, with: "", options: .regularExpression).lowercased()
        let kept = plain.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "_" }
        return String(String.UnicodeScalarView(kept)).replacingOccurrences(of: " ", with: "-")
    }

    public static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func replace(_ pattern: String, in text: String, with transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var result = ""
        var position = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: position, length: match.range.location - position))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            result += transform(groups)
            position = match.range.location + match.range.length
        }
        return result + source.substring(from: position)
    }
}
