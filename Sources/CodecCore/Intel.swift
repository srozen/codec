import Foundation

/// A blank in a script, filled in before it runs: `{{name}}` in the command.
public struct IntelVariable: Equatable, Sendable, Identifiable {
    public var name: String
    public var description: String
    public var defaultValue: String
    /// The values to pick from, when it isn't free text.
    public var choices: [String]

    public var id: String { name }

    public init(name: String, description: String = "", defaultValue: String = "", choices: [String] = []) {
        self.name = name
        self.description = description
        self.defaultValue = defaultValue
        self.choices = choices
    }
}

/// One piece of Intel: a script to run, with variables to fill in, or a Markdown document. Each is a
/// Markdown file with a small YAML header (title, description, kind, variables), readable and editable
/// anywhere. A script's command is the first shell code block in it, or the whole text without one.
public struct IntelItem: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case script, doc
    }

    public var kind: Kind
    public var title: String
    public var description: String
    public var variables: [IntelVariable]
    /// Everything after the header.
    public var body: String

    public init(kind: Kind, title: String, description: String = "", variables: [IntelVariable] = [], body: String = "") {
        self.kind = kind
        self.title = title
        self.description = description
        self.variables = variables
        self.body = body
    }

    /// A script made from a command.
    public static func script(title: String, description: String = "", command: String, variables: [IntelVariable] = []) -> IntelItem {
        var item = IntelItem(kind: .script, title: title, description: description, variables: variables)
        item.command = command
        return item
    }

    // MARK: The command

    private static let shellFences: Set<String> = ["", "sh", "bash", "zsh", "shell", "console", "fish"]

    /// Where the command is in `body`: the first shell code block's contents, or nil when there's none.
    private var commandRange: Range<String.Index>? {
        var index = body.startIndex
        var contentStart: String.Index?
        var marker = ""
        while index < body.endIndex {
            let lineEnd = body[index...].firstIndex(of: "\n") ?? body.endIndex
            let line = body[index..<lineEnd].trimmingCharacters(in: .whitespaces)
            let next = lineEnd < body.endIndex ? body.index(after: lineEnd) : body.endIndex
            if let start = contentStart {
                if line.hasPrefix(marker), line.allSatisfy({ $0 == marker.first }) {
                    // Up to the newline before the closing fence.
                    let end = index > start ? body.index(before: index) : start
                    return start..<max(end, start)
                }
            } else if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let fence = line.prefix { $0 == line.first }
                let info = line.dropFirst(fence.count).trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
                if Self.shellFences.contains(info.lowercased()) {
                    marker = String(fence)
                    contentStart = next
                }
            }
            index = next
        }
        // An unclosed fence runs to the end.
        return contentStart.map { $0..<body.endIndex }
    }

    /// What a script runs.
    public var command: String {
        get {
            if let range = commandRange { return String(body[range]) }
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set {
            if let range = commandRange {
                body.replaceSubrange(range, with: newValue)
            } else {
                body = "```sh\n" + newValue + "\n```\n"
            }
        }
    }

    /// The variables the script uses, in order: the declared ones, then any `{{name}}` in the command that
    /// isn't declared, as plain text.
    public var allVariables: [IntelVariable] {
        let declared = Set(variables.map(\.name))
        return variables + IntelPlaceholders.names(in: command).filter { !declared.contains($0) }.map { IntelVariable(name: $0) }
    }

    /// The command with its variables filled in; ones without a value keep their default.
    public func resolvedCommand(_ values: [String: String]) -> String {
        var filled: [String: String] = [:]
        for variable in allVariables { filled[variable.name] = values[variable.name] ?? variable.defaultValue }
        return IntelPlaceholders.fill(command, with: filled)
    }

    // MARK: Files

    /// Reads a file's text. Without a header it's a document titled `fallbackTitle`.
    public static func parse(_ text: String, fallbackTitle: String) -> IntelItem {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let (header, body) = FrontMatter.split(text) else {
            return IntelItem(kind: .doc, title: fallbackTitle, body: text)
        }
        let fields = FrontMatter.parse(header)
        let title = fields.scalars["title"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
        let kind = fields.scalars["kind"].flatMap { Kind(rawValue: $0.lowercased()) } ?? .doc
        let variables = fields.variables.compactMap { map -> IntelVariable? in
            guard case .scalar(let name)? = map["name"], !name.isEmpty else { return nil }
            var variable = IntelVariable(name: name)
            if case .scalar(let description)? = map["description"] { variable.description = description }
            if case .scalar(let value)? = map["default"] { variable.defaultValue = value }
            if case .list(let choices)? = map["choices"] { variable.choices = choices }
            return variable
        }
        return IntelItem(kind: kind, title: title, description: fields.scalars["description"] ?? "", variables: variables, body: body)
    }

    /// The file's text: the header, then the body.
    public var fileText: String {
        var header = "---\n"
        header += "title: " + FrontMatter.quote(title) + "\n"
        if !description.isEmpty { header += "description: " + FrontMatter.quote(description) + "\n" }
        header += "kind: " + kind.rawValue + "\n"
        if !variables.isEmpty {
            header += "variables:\n"
            for variable in variables {
                header += "  - name: " + FrontMatter.quote(variable.name) + "\n"
                if !variable.description.isEmpty { header += "    description: " + FrontMatter.quote(variable.description) + "\n" }
                if !variable.defaultValue.isEmpty { header += "    default: " + FrontMatter.quote(variable.defaultValue) + "\n" }
                if !variable.choices.isEmpty {
                    header += "    choices: [" + variable.choices.map { FrontMatter.quote($0, inList: true) }.joined(separator: ", ") + "]\n"
                }
            }
        }
        header += "---\n"
        let body = body.hasPrefix("\n") || body.isEmpty ? body : "\n" + body
        return header + body + (body.hasSuffix("\n") || body.isEmpty ? "" : "\n")
    }

    /// A file name for a title: lowercase words joined by dashes, `.md`.
    public static func fileName(for title: String) -> String {
        let words = title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
        let stem = words.prefix(8).joined(separator: "-")
        return (stem.isEmpty ? "untitled" : String(stem.prefix(60))) + ".md"
    }
}

/// `{{name}}` blanks in a command.
public enum IntelPlaceholders {
    private static let pattern = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z_][A-Za-z0-9_-]*)\s*\}\}"#)

    /// The names of the blanks, in order, each once.
    public static func names(in text: String) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        let string = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let name = string.substring(with: match.range(at: 1))
            if seen.insert(name).inserted { names.append(name) }
        }
        return names
    }

    /// Fills in the blanks that have a value; others are left as they are.
    public static func fill(_ text: String, with values: [String: String]) -> String {
        let string = text as NSString
        var result = ""
        var position = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let name = string.substring(with: match.range(at: 1))
            guard let value = values[name] else { continue }
            result += string.substring(with: NSRange(location: position, length: match.range.location - position)) + value
            position = match.range.location + match.range.length
        }
        return result + string.substring(from: position)
    }

    public static func placeholder(_ name: String) -> String { "{{" + name + "}}" }

    /// A variable name made from a label: `Target branch` → `target_branch`.
    public static func name(from label: String) -> String {
        let words = label.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "_" }
        var name = words.joined(separator: "_")
        if let first = name.first, first.isNumber { name = "_" + name }
        return name.isEmpty ? "value" : name
    }
}

/// Parts of a command that are likely to change from one run to the next, offered as variables when a
/// command is saved: the branch, paths, URLs, numbers, quoted text.
public enum IntelSuggestions {
    public struct Candidate: Equatable, Sendable {
        /// Where it is in the command, in characters.
        public var range: Range<Int>
        public var value: String
        public var name: String

        public init(range: Range<Int>, value: String, name: String) {
            self.range = range
            self.value = value
            self.name = name
        }
    }

    public static func candidates(in command: String, branch: String? = nil) -> [Candidate] {
        let characters = Array(command)
        var candidates: [Candidate] = []
        var index = 0
        var previousWord = ""
        while index < characters.count {
            if characters[index].isWhitespace { index += 1; continue }
            // A quoted string, as a whole.
            if characters[index] == "\"" || characters[index] == "'" {
                let quote = characters[index]
                var end = index + 1
                while end < characters.count, characters[end] != quote {
                    if characters[end] == "\\", quote == "\"" { end += 1 }
                    end += 1
                }
                if end < characters.count, end - index > 1 {
                    let value = String(characters[(index + 1)..<end])
                    if !value.contains("{{") {
                        candidates.append(Candidate(range: (index + 1)..<end, value: value,
                                                    name: name(after: previousWord, fallback: "message")))
                    }
                }
                previousWord = ""
                index = end + 1
                continue
            }
            var end = index
            while end < characters.count, !characters[end].isWhitespace, !";|&<>()".contains(characters[end]) { end += 1 }
            if end == index { index += 1; previousWord = ""; continue }
            let word = String(characters[index..<end])
            // `--flag=value`: the value.
            if word.hasPrefix("-"), let equals = word.firstIndex(of: "=") {
                let offset = word.distance(from: word.startIndex, to: equals) + 1
                let value = String(word[word.index(after: equals)...])
                let flag = String(word[..<equals]).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                if let kind = kind(of: value, branch: branch) {
                    candidates.append(Candidate(range: (index + offset)..<end, value: value,
                                                name: IntelPlaceholders.name(from: flag.isEmpty ? kind : flag)))
                }
            } else if !word.hasPrefix("-"), !word.contains("{{"), !isCommandName(at: index, in: characters),
                      let kind = kind(of: word, branch: branch) {
                candidates.append(Candidate(range: index..<end, value: word, name: name(after: previousWord, fallback: kind)))
            }
            previousWord = word
            index = end
        }
        // One suggestion per name: `path`, `path_2`…
        var counts: [String: Int] = [:]
        return candidates.map { candidate in
            var candidate = candidate
            counts[candidate.name, default: 0] += 1
            if let count = counts[candidate.name], count > 1 { candidate.name += "_\(count)" }
            return candidate
        }
    }

    /// The command's own name (the first word, or the first after a `|`, `;` or `&&`) is never a variable.
    private static func isCommandName(at index: Int, in characters: [Character]) -> Bool {
        var position = index - 1
        while position >= 0, characters[position].isWhitespace { position -= 1 }
        return position < 0 || ";|&(".contains(characters[position])
    }

    private static func kind(of word: String, branch: String?) -> String? {
        if let branch, word == branch || word.hasSuffix("/" + branch) { return "branch" }
        if word.contains("://") { return "url" }
        if word.allSatisfy(\.isNumber), word.count >= 2 { return "number" }
        if word.contains(":"), word.split(separator: ":").last.map({ $0.allSatisfy(\.isNumber) && !$0.isEmpty }) == true {
            return "address"
        }
        if word.contains("/") || word.hasPrefix("~") { return "path" }
        if let dot = word.lastIndex(of: "."), dot != word.startIndex,
           word[word.index(after: dot)...].count.isBetween(1, 5), word[word.index(after: dot)...].allSatisfy(\.isLetter) {
            return "file"
        }
        return nil
    }

    /// Named after the flag before it when there is one (`-p 8080` → `p`, `--port 8080` → `port`).
    private static func name(after previous: String, fallback: String) -> String {
        guard previous.hasPrefix("-"), !previous.contains("=") else { return fallback }
        let flag = previous.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return flag.count > 1 ? IntelPlaceholders.name(from: flag) : fallback
    }
}

private extension Int {
    func isBetween(_ low: Int, _ high: Int) -> Bool { self >= low && self <= high }
}

// MARK: - Front matter

/// The YAML subset Intel files use: `key: value` scalars, and a list of maps under `variables:`, whose
/// values are scalars or lists (`[a, b]`, or `- a` lines).
enum FrontMatter {
    enum Value: Equatable {
        case scalar(String)
        case list([String])
    }

    struct Fields {
        var scalars: [String: String] = [:]
        var variables: [[String: Value]] = []
    }

    /// The header between the opening and closing `---`, and what follows.
    static func split(_ text: String) -> (header: String, body: String)? {
        guard text.hasPrefix("---\n") else { return nil }
        let rest = text.dropFirst(4)
        var lineStart = rest.startIndex
        while lineStart < rest.endIndex {
            let lineEnd = rest[lineStart...].firstIndex(of: "\n") ?? rest.endIndex
            let line = rest[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
            if line == "---" || line == "..." {
                let body = lineEnd < rest.endIndex ? rest[rest.index(after: lineEnd)...] : ""
                return (String(rest[..<lineStart]), String(body))
            }
            lineStart = lineEnd < rest.endIndex ? rest.index(after: lineEnd) : rest.endIndex
        }
        return nil
    }

    static func parse(_ header: String) -> Fields {
        var fields = Fields()
        var inVariables = false
        var current: [String: Value]?
        var listKey: String?
        func flush() {
            if let current { fields.variables.append(current) }
            current = nil
        }
        for raw in header.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 {
                flush()
                listKey = nil
                guard let (key, value) = pair(trimmed) else { continue }
                inVariables = key == "variables"
                if !inVariables { fields.scalars[key] = scalar(value) }
                continue
            }
            guard inVariables else { continue }
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                let item = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                // A `- value` line under `choices:`, deeper than the variable's own `- name:`.
                if let listKey, current != nil, pair(item) == nil || indent > 4 {
                    if case .list(let values)? = current?[listKey] {
                        current?[listKey] = .list(values + [scalar(item)])
                    } else {
                        current?[listKey] = .list([scalar(item)])
                    }
                    continue
                }
                flush()
                current = [:]
                listKey = nil
                if let (key, value) = pair(item) { assign(key, value, to: &current, listKey: &listKey) }
                continue
            }
            if current != nil, let (key, value) = pair(trimmed) { assign(key, value, to: &current, listKey: &listKey) }
        }
        flush()
        return fields
    }

    private static func assign(_ key: String, _ value: String, to map: inout [String: Value]?, listKey: inout String?) {
        if value.hasPrefix("[") {
            map?[key] = .list(list(value))
            listKey = nil
        } else if value.isEmpty {
            listKey = key
        } else {
            map?[key] = .scalar(scalar(value))
            listKey = nil
        }
    }

    /// `key: value`, splitting at the first colon outside quotes.
    private static func pair(_ text: String) -> (String, String)? {
        guard let colon = text.firstIndex(of: ":"), !text.hasPrefix("\""), !text.hasPrefix("'") else { return nil }
        let key = text[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(" ") else { return nil }
        return (key, text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    /// A scalar without its quotes; a ` #` comment after an unquoted one is dropped.
    static func scalar(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            var result = ""
            var escaping = false
            for character in text.dropFirst().dropLast() {
                if escaping {
                    switch character {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    default: result.append(character)
                    }
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else {
                    result.append(character)
                }
            }
            return result
        }
        if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if let comment = text.range(of: " #") { return text[..<comment.lowerBound].trimmingCharacters(in: .whitespaces) }
        return text
    }

    /// `[a, "b, c", d]`.
    static func list(_ text: String) -> [String] {
        let inner = text.trimmingCharacters(in: .whitespaces).dropFirst().dropLast(text.hasSuffix("]") ? 1 : 0)
        var items: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        for character in inner {
            if escaping { current.append(character); escaping = false; continue }
            if let open = quote {
                current.append(character)
                if character == "\\", open == "\"" { escaping = true } else if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "," {
                items.append(scalar(current))
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { items.append(scalar(current)) }
        return items
    }

    /// A value as YAML, quoted when it would otherwise read as something else.
    static func quote(_ value: String, inList: Bool = false) -> String {
        let special = value.isEmpty || value != value.trimmingCharacters(in: .whitespaces)
            || value.contains(": ") || value.contains(" #") || value.hasSuffix(":") || value.contains("\n") || value.contains("\"")
            || (inList && (value.contains(",") || value.contains("]") || value.contains("[")))
            || "[]{}&*!|>'\"%@`#-?,".contains(value.first ?? " ")
            || ["true", "false", "yes", "no", "null", "~", "on", "off"].contains(value.lowercased())
            || Double(value) != nil
        guard special else { return value }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
        return "\"" + escaped + "\""
    }
}
