import Foundation

/// What a piece of source code is, for coloring.
public enum SyntaxToken: String, CaseIterable, Sendable {
    case keyword, type, function, string, number, comment, constant, attribute, preprocessor, property, variable, tag
    // Markdown
    case heading, emphasis, strong, code, link, quote, listMarker
}

/// A colored run, in UTF-16 offsets so it maps straight onto `NSRange`.
public struct HighlightSpan: Equatable, Sendable {
    public var location: Int
    public var length: Int
    public var token: SyntaxToken

    public init(location: Int, length: Int, token: SyntaxToken) {
        self.location = location
        self.length = length
        self.token = token
    }

    public var range: NSRange { NSRange(location: location, length: length) }
}

/// The languages the editor colors.
public enum SourceLanguage: String, CaseIterable, Sendable {
    case swift, javascript, typescript, python, ruby, go, rust, c, cpp, objectiveC, java, kotlin, csharp, php, lua, sql, shell
    case json, yaml, toml, markup, css, markdown, plain

    public static func of(fileNamed name: String) -> SourceLanguage {
        switch FileType.of(fileNamed: name) {
        case .swift: .swift
        case .javascript: .javascript
        case .typescript: .typescript
        case .python: .python
        case .ruby: .ruby
        case .go: .go
        case .rust: .rust
        case .c: .c
        case .cpp: .cpp
        case .objectiveC: .objectiveC
        case .java: .java
        case .kotlin: .kotlin
        case .csharp: .csharp
        case .php: .php
        case .lua: .lua
        case .sql: .sql
        case .shell, .environment: .shell
        case .json: .json
        case .yaml: .yaml
        case .toml, .config: .toml
        case .html, .xml, .vector: .markup
        case .css: .css
        case .markdown, .readme: .markdown
        case .manifest:
            switch (name as NSString).pathExtension.lowercased() {
            case "swift": .swift
            case "json": .json
            case "toml": .toml
            case "xml": .markup
            default: name.lowercased() == "gemfile" || name.lowercased() == "podfile" ? .ruby : .shell
            }
        case .docker, .git: .shell
        case .lockfile: (name as NSString).pathExtension.lowercased() == "json" ? .json : .plain
        default: .plain
        }
    }

    /// The language a fenced code block's info string names (```swift, ```ts…).
    public static func of(fence info: String) -> SourceLanguage {
        let word = info.split(separator: " ").first.map { $0.lowercased() } ?? ""
        switch word {
        case "swift": return .swift
        case "js", "javascript", "jsx", "mjs": return .javascript
        case "ts", "typescript", "tsx": return .typescript
        case "py", "python": return .python
        case "rb", "ruby": return .ruby
        case "go", "golang": return .go
        case "rs", "rust": return .rust
        case "c", "h": return .c
        case "cpp", "c++", "cc", "hpp": return .cpp
        case "objc", "objective-c", "m": return .objectiveC
        case "java": return .java
        case "kotlin", "kt": return .kotlin
        case "cs", "csharp", "c#": return .csharp
        case "php": return .php
        case "lua": return .lua
        case "sql": return .sql
        case "sh", "bash", "zsh", "shell", "console", "fish": return .shell
        case "json", "jsonc": return .json
        case "yaml", "yml": return .yaml
        case "toml", "ini": return .toml
        case "html", "xml", "svg", "plist": return .markup
        case "css", "scss": return .css
        case "md", "markdown": return .markdown
        default: return .plain
        }
    }

    /// What starts a line comment, for toggling comments. Nil when the language has none.
    public var lineComment: String? {
        switch self {
        case .python, .ruby, .shell, .yaml, .toml: "#"
        case .sql, .lua: "--"
        case .json, .markup, .css, .markdown, .plain: nil
        default: "//"
        }
    }
}

/// Colors source code: one pass over the text, no regular expressions, so it keeps up with typing.
public enum SyntaxHighlighter {
    public static func spans(in text: String, language: SourceLanguage) -> [HighlightSpan] {
        let units = Array(text.utf16)
        switch language {
        case .plain: return []
        case .json:
            var scanner = JSONScanner(units)
            return scanner.run()
        case .yaml:
            var scanner = YAMLScanner(units)
            return scanner.run()
        case .toml:
            var scanner = TOMLScanner(units)
            return scanner.run()
        case .markup:
            var scanner = MarkupScanner(units)
            return scanner.run()
        case .css:
            var scanner = CSSScanner(units)
            return scanner.run()
        case .markdown:
            var scanner = MarkdownScanner(units)
            return scanner.run()
        default:
            var scanner = CodeScanner(units, grammar: Grammar.for(language))
            return scanner.run()
        }
    }
}

// MARK: - Characters

private extension UInt16 {
    static let newline: UInt16 = 10, carriageReturn: UInt16 = 13, space: UInt16 = 32, tab: UInt16 = 9
    static let quote: UInt16 = 34, apostrophe: UInt16 = 39, backtick: UInt16 = 96, backslash: UInt16 = 92
    static let slash: UInt16 = 47, star: UInt16 = 42, hash: UInt16 = 35, at: UInt16 = 64, dollar: UInt16 = 36
    static let dot: UInt16 = 46, colon: UInt16 = 58, openParen: UInt16 = 40, openBrace: UInt16 = 123, closeBrace: UInt16 = 125
    static let lessThan: UInt16 = 60, greaterThan: UInt16 = 62, equals: UInt16 = 61, dash: UInt16 = 45, underscore: UInt16 = 95
    static let openBracket: UInt16 = 91, closeBracket: UInt16 = 93, comma: UInt16 = 44, semicolon: UInt16 = 59, exclamation: UInt16 = 33
    static let plus: UInt16 = 43, tilde: UInt16 = 126, closeParen: UInt16 = 41, ampersand: UInt16 = 38, pipe: UInt16 = 124

    var isDigit: Bool { self >= 48 && self <= 57 }
    var isUpper: Bool { self >= 65 && self <= 90 }
    var isLetter: Bool { (self >= 65 && self <= 90) || (self >= 97 && self <= 122) || self > 127 }
    var isIdentifierStart: Bool { isLetter || self == .underscore }
    var isIdentifier: Bool { isIdentifierStart || isDigit }
    var isBlank: Bool { self == .space || self == .tab }
    var isLineEnd: Bool { self == .newline || self == .carriageReturn }
}

private func string(_ units: ArraySlice<UInt16>) -> String {
    String(decoding: units, as: UTF16.self)
}

// MARK: - Grammars for C-like and scripting languages

private struct Grammar {
    var keywords: Set<String> = []
    var constants: Set<String> = ["true", "false", "null"]
    var builtinTypes: Set<String> = []
    var lineComments: [String] = ["//"]
    var blockComment: (open: String, close: String)? = ("/*", "*/")
    /// Delimiters for strings; triple ones span lines.
    var strings: [String] = ["\"", "'"]
    var multilineStrings: [String] = []
    var capitalizedTypes = true
    var attributes = false
    var preprocessor = false
    var variables = false
    /// Ruby: `@name` is an instance variable and names may end in `?` or `!`.
    var rubyNames = false
    var caseInsensitive = false
    /// `#` comments only count at the start of a word (`$#` in shell isn't one).
    var hashNeedsBoundary = false

    static func `for`(_ language: SourceLanguage) -> Grammar {
        var grammar = Grammar()
        switch language {
        case .swift:
            grammar.keywords = ["associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
                                "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows",
                                "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default",
                                "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch",
                                "where", "while", "as", "is", "try", "await", "async", "throws", "super", "self", "Self", "some", "any",
                                "lazy", "weak", "unowned", "mutating", "nonmutating", "override", "final", "required", "convenience",
                                "dynamic", "optional", "indirect", "nonisolated", "isolated", "consuming", "borrowing", "actor", "macro",
                                "get", "set", "willSet", "didSet", "package", "sending", "each"]
            grammar.constants = ["true", "false", "nil"]
            grammar.strings = ["\""]
            grammar.multilineStrings = ["\"\"\""]
            grammar.attributes = true
            grammar.preprocessor = true
        case .javascript, .typescript:
            grammar.keywords = ["break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else",
                                "export", "extends", "finally", "for", "function", "if", "import", "in", "instanceof", "new", "return",
                                "super", "switch", "this", "throw", "try", "typeof", "var", "void", "while", "with", "yield", "let",
                                "static", "async", "await", "of", "from", "as", "get", "set"]
            if language == .typescript {
                grammar.keywords.formUnion(["interface", "type", "enum", "implements", "private", "public", "protected", "readonly",
                                            "abstract", "declare", "namespace", "keyof", "infer", "is", "satisfies", "override"])
                grammar.builtinTypes = ["string", "number", "boolean", "any", "unknown", "never", "void", "object", "bigint", "symbol"]
            }
            grammar.constants = ["true", "false", "null", "undefined", "NaN", "Infinity"]
            grammar.multilineStrings = ["`"]
            grammar.attributes = true
        case .python:
            grammar.keywords = ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
                                "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not",
                                "or", "pass", "raise", "return", "try", "while", "with", "yield", "match", "case", "self"]
            grammar.constants = ["True", "False", "None"]
            grammar.builtinTypes = ["int", "str", "float", "bool", "list", "dict", "set", "tuple", "bytes", "object"]
            grammar.lineComments = ["#"]
            grammar.blockComment = nil
            grammar.multilineStrings = ["\"\"\"", "'''"]
            grammar.attributes = true
            grammar.hashNeedsBoundary = true
        case .ruby:
            grammar.keywords = ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end",
                                "ensure", "for", "if", "in", "module", "next", "not", "or", "redo", "rescue", "retry", "return", "self",
                                "super", "then", "undef", "unless", "until", "when", "while", "yield", "require", "attr_reader",
                                "attr_accessor", "private", "protected", "public"]
            grammar.constants = ["true", "false", "nil"]
            grammar.lineComments = ["#"]
            grammar.blockComment = nil
            grammar.hashNeedsBoundary = true
            grammar.variables = true
            grammar.rubyNames = true
        case .go:
            grammar.keywords = ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func",
                                "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct",
                                "switch", "type", "var"]
            grammar.constants = ["true", "false", "nil", "iota"]
            grammar.builtinTypes = ["bool", "byte", "error", "float32", "float64", "int", "int8", "int16", "int32", "int64", "rune",
                                    "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "any"]
            grammar.multilineStrings = ["`"]
        case .rust:
            grammar.keywords = ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn",
                                "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self",
                                "Self", "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while"]
            grammar.builtinTypes = ["i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32",
                                    "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box"]
            grammar.constants = ["true", "false", "None", "Some", "Ok", "Err"]
            grammar.strings = ["\""]
            grammar.preprocessor = true
        case .c, .cpp, .objectiveC:
            grammar.keywords = ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum",
                                "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "return", "short",
                                "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile",
                                "while", "bool"]
            if language == .cpp {
                grammar.keywords.formUnion(["class", "namespace", "template", "typename", "public", "private", "protected", "virtual",
                                            "override", "new", "delete", "this", "using", "try", "catch", "throw", "constexpr",
                                            "auto", "nullptr", "operator", "friend", "explicit", "noexcept", "final"])
            }
            if language == .objectiveC {
                grammar.keywords.formUnion(["self", "super", "id", "instancetype", "nonatomic", "strong", "weak", "copy", "assign",
                                            "readonly", "readwrite", "nullable", "nonnull"])
                grammar.attributes = true
            }
            grammar.constants = ["true", "false", "NULL", "nullptr", "nil", "YES", "NO"]
            grammar.preprocessor = true
        case .java, .kotlin, .csharp:
            grammar.keywords = ["abstract", "break", "case", "catch", "class", "continue", "default", "do", "else", "enum", "extends",
                                "final", "finally", "for", "if", "implements", "import", "instanceof", "interface", "new", "package",
                                "private", "protected", "public", "return", "static", "super", "switch", "synchronized", "this",
                                "throw", "throws", "try", "void", "while", "var", "val", "fun", "object", "when", "is", "in", "as",
                                "override", "open", "data", "sealed", "companion", "suspend", "using", "namespace", "readonly",
                                "async", "await", "out", "ref", "get", "set", "init", "record", "struct", "lateinit", "internal"]
            grammar.builtinTypes = ["int", "long", "short", "byte", "char", "boolean", "float", "double", "string", "bool", "object"]
            grammar.multilineStrings = ["\"\"\""]
            grammar.attributes = true
        case .php:
            grammar.keywords = ["abstract", "and", "array", "as", "break", "case", "catch", "class", "clone", "const", "continue",
                                "declare", "default", "do", "echo", "else", "elseif", "empty", "enum", "extends", "final", "finally",
                                "fn", "for", "foreach", "function", "global", "if", "implements", "include", "instanceof", "interface",
                                "isset", "list", "match", "namespace", "new", "or", "print", "private", "protected", "public",
                                "readonly", "require", "return", "static", "switch", "throw", "trait", "try", "unset", "use", "while",
                                "yield"]
            grammar.lineComments = ["//", "#"]
            grammar.variables = true
            grammar.hashNeedsBoundary = true
        case .lua:
            grammar.keywords = ["and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "local", "not",
                                "or", "repeat", "return", "then", "until", "while"]
            grammar.constants = ["true", "false", "nil"]
            grammar.lineComments = ["--"]
            grammar.blockComment = ("--[[", "]]")
        case .sql:
            grammar.keywords = ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table",
                                "drop", "alter", "add", "index", "on", "join", "left", "right", "inner", "outer", "full", "group",
                                "by", "order", "having", "limit", "offset", "as", "and", "or", "not", "in", "is", "like", "between",
                                "distinct", "union", "all", "case", "when", "then", "else", "end", "primary", "key", "foreign",
                                "references", "default", "unique", "exists", "view", "with", "returning", "asc", "desc", "begin",
                                "commit", "rollback", "transaction", "if", "constraint", "cascade"]
            grammar.constants = ["true", "false", "null"]
            grammar.builtinTypes = ["int", "integer", "bigint", "smallint", "text", "varchar", "char", "boolean", "date", "timestamp",
                                    "float", "real", "double", "decimal", "numeric", "json", "jsonb", "uuid", "serial", "blob"]
            grammar.lineComments = ["--"]
            grammar.capitalizedTypes = false
            grammar.caseInsensitive = true
        case .shell:
            grammar.keywords = ["if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done", "in",
                                "function", "select", "time", "return", "exit", "local", "export", "readonly", "declare", "unset",
                                "source", "alias", "set", "shift", "break", "continue", "eval", "exec", "trap", "echo", "printf",
                                "cd", "test", "typeset", "setopt", "unsetopt", "autoload", "bindkey", "zle", "FROM", "RUN", "CMD",
                                "COPY", "ADD", "ENV", "ARG", "WORKDIR", "EXPOSE", "ENTRYPOINT", "USER", "VOLUME", "LABEL"]
            grammar.constants = ["true", "false"]
            grammar.lineComments = ["#"]
            grammar.blockComment = nil
            grammar.capitalizedTypes = false
            grammar.variables = true
            grammar.hashNeedsBoundary = true
        default:
            break
        }
        return grammar
    }
}

// MARK: - Scanning

private struct Emitter {
    var spans: [HighlightSpan] = []

    mutating func add(_ start: Int, _ end: Int, _ token: SyntaxToken) {
        guard end > start else { return }
        spans.append(HighlightSpan(location: start, length: end - start, token: token))
    }
}

private func matches(_ units: [UInt16], _ index: Int, _ text: String) -> Bool {
    var position = index
    for unit in text.utf16 {
        guard position < units.count, units[position] == unit else { return false }
        position += 1
    }
    return true
}

private func lineEnd(_ units: [UInt16], from index: Int) -> Int {
    var position = index
    while position < units.count, !units[position].isLineEnd { position += 1 }
    return position
}

/// The end of a string that opened at `index` with `delimiter`.
private func stringEnd(_ units: [UInt16], from index: Int, delimiter: String, multiline: Bool, escapes: Bool = true) -> Int {
    let length = delimiter.utf16.count
    var position = index + length
    while position < units.count {
        let unit = units[position]
        if escapes, unit == .backslash { position += 2; continue }
        if !multiline, unit.isLineEnd { return position }
        if matches(units, position, delimiter) { return position + length }
        position += 1
    }
    return units.count
}

private func numberEnd(_ units: [UInt16], from index: Int) -> Int {
    var position = index
    var previous: UInt16 = 0
    while position < units.count {
        let unit = units[position]
        let exponentSign = (unit == .plus || unit == .dash) && (previous == 101 || previous == 69) && !isHex(units, index)
        guard unit.isIdentifier || unit == .dot || exponentSign else { break }
        // A dot followed by a letter is a member access (`1.description`), not a fraction.
        if unit == .dot, position + 1 < units.count, !units[position + 1].isDigit { break }
        previous = unit
        position += 1
    }
    return position
}

private func isHex(_ units: [UInt16], _ index: Int) -> Bool {
    index + 1 < units.count && units[index] == 48 && (units[index + 1] == 120 || units[index + 1] == 88)
}

private struct CodeScanner {
    let units: [UInt16]
    let grammar: Grammar
    var out = Emitter()

    init(_ units: [UInt16], grammar: Grammar) {
        self.units = units
        self.grammar = grammar
    }

    mutating func run() -> [HighlightSpan] {
        var index = 0
        var lineStart = true
        let count = units.count
        while index < count {
            let unit = units[index]
            if unit.isLineEnd { lineStart = true; index += 1; continue }
            if unit.isBlank { index += 1; continue }
            let wasLineStart = lineStart
            lineStart = false

            if let block = grammar.blockComment, matches(units, index, block.open) {
                var end = index + block.open.utf16.count
                while end < count, !matches(units, end, block.close) { end += 1 }
                end = min(count, end + block.close.utf16.count)
                out.add(index, end, .comment)
                index = end
                continue
            }
            if let comment = grammar.lineComments.first(where: { matches(units, index, $0) }),
               !(comment == "#" && grammar.hashNeedsBoundary && index > 0 && !units[index - 1].isBlank && !units[index - 1].isLineEnd) {
                let end = lineEnd(units, from: index)
                out.add(index, end, .comment)
                index = end
                continue
            }
            if grammar.preprocessor, unit == .hash, wasLineStart || grammar.attributes {
                var end = index + 1
                while end < count, units[end].isIdentifier { end += 1 }
                if end > index + 1 {
                    out.add(index, end, .preprocessor)
                    index = end
                    continue
                }
            }
            if let delimiter = grammar.multilineStrings.first(where: { matches(units, index, $0) }) {
                let end = stringEnd(units, from: index, delimiter: delimiter, multiline: true)
                out.add(index, end, .string)
                index = end
                continue
            }
            if let delimiter = grammar.strings.first(where: { matches(units, index, $0) }) {
                let end = stringEnd(units, from: index, delimiter: delimiter, multiline: false)
                out.add(index, end, .string)
                index = end
                continue
            }
            if unit.isDigit, index == 0 || !units[index - 1].isIdentifier {
                let end = numberEnd(units, from: index)
                out.add(index, end, .number)
                index = end
                continue
            }
            if grammar.attributes, unit == .at, index + 1 < count, units[index + 1].isIdentifierStart {
                var end = index + 1
                while end < count, units[end].isIdentifier || units[end] == .dot { end += 1 }
                out.add(index, end, .attribute)
                index = end
                continue
            }
            if grammar.variables, unit == .dollar || (unit == .at && grammar.rubyNames), index + 1 < count {
                var end = index + 1
                if units[end] == .openBrace {
                    while end < count, units[end] != .closeBrace, !units[end].isLineEnd { end += 1 }
                    end = min(count, end + 1)
                } else {
                    while end < count, units[end].isIdentifier || (end == index + 1 && "?#@*!0123456789".utf16.contains(units[end])) {
                        end += 1
                    }
                }
                if end > index + 1 {
                    out.add(index, end, .variable)
                    index = end
                    continue
                }
            }
            if unit.isIdentifierStart {
                var end = index + 1
                while end < count, units[end].isIdentifier { end += 1 }
                if grammar.rubyNames, end < count, units[end] == 63 || units[end] == .exclamation { end += 1 }
                classify(index, end)
                index = end
                continue
            }
            index += 1
        }
        return out.spans
    }

    private mutating func classify(_ start: Int, _ end: Int) {
        let word = string(units[start..<end])
        let key = grammar.caseInsensitive ? word.lowercased() : word
        if grammar.keywords.contains(key) { return out.add(start, end, .keyword) }
        if grammar.constants.contains(key) { return out.add(start, end, .constant) }
        if grammar.builtinTypes.contains(key) { return out.add(start, end, .type) }
        var next = end
        while next < units.count, units[next].isBlank { next += 1 }
        let calls = next < units.count && units[next] == .openParen
        var previous = start - 1
        while previous >= 0, units[previous].isBlank { previous -= 1 }
        let member = previous >= 0 && units[previous] == .dot
        if grammar.capitalizedTypes, units[start].isUpper {
            // SCREAMING_CASE is a constant, not a type.
            let isConstant = word.count > 1 && word.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
            return out.add(start, end, isConstant ? .constant : .type)
        }
        if calls { return out.add(start, end, .function) }
        if member { return out.add(start, end, .property) }
    }
}

// MARK: - Data formats

private struct JSONScanner {
    let units: [UInt16]
    var out = Emitter()
    init(_ units: [UInt16]) { self.units = units }

    mutating func run() -> [HighlightSpan] {
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == .quote {
                let end = stringEnd(units, from: index, delimiter: "\"", multiline: false)
                var next = end
                while next < units.count, units[next].isBlank || units[next].isLineEnd { next += 1 }
                out.add(index, end, next < units.count && units[next] == .colon ? .property : .string)
                index = end
            } else if unit == .slash, matches(units, index, "//") {
                let end = lineEnd(units, from: index)
                out.add(index, end, .comment)
                index = end
            } else if unit.isDigit || (unit == .dash && index + 1 < units.count && units[index + 1].isDigit) {
                let end = numberEnd(units, from: index + 1)
                out.add(index, end, .number)
                index = end
            } else if unit.isLetter {
                var end = index
                while end < units.count, units[end].isLetter { end += 1 }
                if ["true", "false", "null"].contains(string(units[index..<end])) { out.add(index, end, .constant) }
                index = end
            } else {
                index += 1
            }
        }
        return out.spans
    }
}

/// YAML, by line: comments, keys, then a scalar value.
private struct YAMLScanner {
    let units: [UInt16]
    var out = Emitter()
    init(_ units: [UInt16]) { self.units = units }

    mutating func run() -> [HighlightSpan] {
        var index = 0
        while index < units.count {
            let end = lineEnd(units, from: index)
            line(index, end)
            index = end + 1
        }
        return out.spans
    }

    private mutating func line(_ start: Int, _ end: Int) {
        var position = start
        while position < end, units[position].isBlank { position += 1 }
        if position < end, units[position] == .hash { return out.add(position, end, .comment) }
        if matches(units, position, "---") || matches(units, position, "...") { return out.add(position, end, .keyword) }
        if position < end, units[position] == .dash { out.add(position, position + 1, .listMarker); position += 1 }
        while position < end, units[position].isBlank { position += 1 }
        // key: value
        var colon = position
        var inQuote: UInt16 = 0
        while colon < end {
            let unit = units[colon]
            if inQuote != 0 { if unit == inQuote { inQuote = 0 } } else if unit == .quote || unit == .apostrophe { inQuote = unit }
            else if unit == .colon, colon + 1 == end || units[colon + 1].isBlank { break }
            else if unit == .hash, colon > position, units[colon - 1].isBlank { colon = end; break }
            colon += 1
        }
        if colon < end {
            out.add(position, colon, .property)
            position = colon + 1
        }
        value(position, end)
    }

    private mutating func value(_ start: Int, _ end: Int) {
        var position = start
        while position < end, units[position].isBlank { position += 1 }
        guard position < end else { return }
        var valueEnd = end
        // A trailing comment.
        var scan = position
        while scan < end {
            if units[scan] == .hash, scan > position, units[scan - 1].isBlank { valueEnd = scan; out.add(scan, end, .comment); break }
            scan += 1
        }
        while valueEnd > position, units[valueEnd - 1].isBlank { valueEnd -= 1 }
        let text = string(units[position..<valueEnd])
        let first = units[position]
        if first == .quote || first == .apostrophe { return out.add(position, valueEnd, .string) }
        if first == .ampersand || first == .star { return out.add(position, valueEnd, .variable) }
        if ["true", "false", "null", "yes", "no", "on", "off", "~"].contains(text.lowercased()) { return out.add(position, valueEnd, .constant) }
        if Double(text) != nil { return out.add(position, valueEnd, .number) }
        if first == .pipe || first == .greaterThan { return out.add(position, valueEnd, .keyword) }
        if first != .openBrace, first != .openBracket { out.add(position, valueEnd, .string) }
    }
}

/// TOML and INI: sections, keys, values.
private struct TOMLScanner {
    let units: [UInt16]
    var out = Emitter()
    init(_ units: [UInt16]) { self.units = units }

    mutating func run() -> [HighlightSpan] {
        var index = 0
        while index < units.count {
            let end = lineEnd(units, from: index)
            var position = index
            while position < end, units[position].isBlank { position += 1 }
            if position < end {
                let unit = units[position]
                if unit == .hash || unit == .semicolon {
                    out.add(position, end, .comment)
                } else if unit == .openBracket {
                    out.add(position, end, .heading)
                } else {
                    var equals = position
                    while equals < end, units[equals] != .equals { equals += 1 }
                    if equals < end {
                        out.add(position, equals, .property)
                        value(equals + 1, end)
                    }
                }
            }
            index = end + 1
        }
        return out.spans
    }

    private mutating func value(_ start: Int, _ end: Int) {
        var position = start
        while position < end {
            let unit = units[position]
            if unit == .quote || unit == .apostrophe {
                let delimiter = unit == .quote ? "\"" : "'"
                let stop = min(stringEnd(units, from: position, delimiter: delimiter, multiline: false, escapes: unit == .quote), end)
                out.add(position, stop, .string)
                position = stop
            } else if unit == .hash {
                return out.add(position, end, .comment)
            } else if unit.isDigit || unit == .dash || unit == .plus {
                let stop = numberEnd(units, from: position + 1)
                out.add(position, min(stop, end), .number)
                position = max(stop, position + 1)
            } else if unit.isLetter {
                var stop = position
                while stop < end, units[stop].isLetter { stop += 1 }
                if ["true", "false"].contains(string(units[position..<stop])) { out.add(position, stop, .constant) }
                position = stop
            } else {
                position += 1
            }
        }
    }
}

/// HTML and XML: tags, attributes and their values, comments, entities.
private struct MarkupScanner {
    let units: [UInt16]
    var out = Emitter()
    init(_ units: [UInt16]) { self.units = units }

    mutating func run() -> [HighlightSpan] {
        var index = 0
        let count = units.count
        while index < count {
            if matches(units, index, "<!--") {
                var end = index + 4
                while end < count, !matches(units, end, "-->") { end += 1 }
                end = min(count, end + 3)
                out.add(index, end, .comment)
                index = end
            } else if units[index] == .lessThan, index + 1 < count,
                      units[index + 1].isLetter || units[index + 1] == .slash || units[index + 1] == .exclamation || units[index + 1] == 63 {
                index = tag(index)
            } else if units[index] == .ampersand {
                var end = index + 1
                while end < count, units[end].isIdentifier || units[end] == .hash { end += 1 }
                if end < count, units[end] == .semicolon { out.add(index, end + 1, .constant); index = end + 1 } else { index += 1 }
            } else {
                index += 1
            }
        }
        return out.spans
    }

    private mutating func tag(_ start: Int) -> Int {
        var position = start + 1
        let count = units.count
        while position < count, units[position] == .slash || units[position] == .exclamation || units[position] == 63 { position += 1 }
        let nameStart = position
        while position < count, units[position].isIdentifier || units[position] == .dash || units[position] == .colon { position += 1 }
        out.add(nameStart, position, .tag)
        while position < count, units[position] != .greaterThan {
            let unit = units[position]
            if unit == .quote || unit == .apostrophe {
                let end = stringEnd(units, from: position, delimiter: unit == .quote ? "\"" : "'", multiline: true, escapes: false)
                out.add(position, end, .string)
                position = end
            } else if unit.isIdentifierStart {
                var end = position
                while end < count, units[end].isIdentifier || units[end] == .dash || units[end] == .colon { end += 1 }
                out.add(position, end, .attribute)
                position = end
            } else if unit == .lessThan {
                return position
            } else {
                position += 1
            }
        }
        return min(count, position + 1)
    }
}

/// CSS: selectors, properties, values, at-rules.
private struct CSSScanner {
    let units: [UInt16]
    var out = Emitter()
    init(_ units: [UInt16]) { self.units = units }

    /// Whether a `{` comes before the next `;` or `}`: then this is a selector, not a property.
    private func opensBlock(from index: Int) -> Bool {
        var position = index
        while position < units.count {
            switch units[position] {
            case .openBrace: return true
            case .semicolon, .closeBrace: return false
            default: position += 1
            }
        }
        return false
    }

    mutating func run() -> [HighlightSpan] {
        var index = 0
        var depth = 0
        var inValue = false
        let count = units.count
        while index < count {
            let unit = units[index]
            if matches(units, index, "/*") {
                var end = index + 2
                while end < count, !matches(units, end, "*/") { end += 1 }
                end = min(count, end + 2)
                out.add(index, end, .comment)
                index = end
            } else if matches(units, index, "//") {
                let end = lineEnd(units, from: index)
                out.add(index, end, .comment)
                index = end
            } else if unit == .quote || unit == .apostrophe {
                let end = stringEnd(units, from: index, delimiter: unit == .quote ? "\"" : "'", multiline: false)
                out.add(index, end, .string)
                index = end
            } else if unit == .openBrace {
                depth += 1; inValue = false; index += 1
            } else if unit == .closeBrace {
                depth = max(0, depth - 1); inValue = false; index += 1
            } else if unit == .semicolon {
                inValue = false; index += 1
            } else if unit == .colon, depth > 0, !inValue {
                inValue = true; index += 1
            } else if unit == .at {
                var end = index + 1
                while end < count, units[end].isIdentifier || units[end] == .dash { end += 1 }
                out.add(index, end, .keyword)
                index = end
            } else if unit == .hash, inValue {
                var end = index + 1
                while end < count, units[end].isIdentifier { end += 1 }
                out.add(index, end, .number)
                index = end
            } else if unit.isDigit || (unit == .dot && index + 1 < count && units[index + 1].isDigit) {
                var end = index
                while end < count, units[end].isIdentifier || units[end] == .dot || units[end] == 37 { end += 1 }
                out.add(index, end, .number)
                index = end
            } else if unit.isIdentifierStart || unit == .dash || unit == .dot || unit == .hash {
                var end = index + 1
                while end < count, units[end].isIdentifier || units[end] == .dash { end += 1 }
                if depth > 0, !inValue, !opensBlock(from: end) {
                    out.add(index, end, .property)
                } else if !inValue || unit == .dot || unit == .hash {
                    out.add(index, end, unit == .dot || unit == .hash ? .attribute : .tag)
                } else if end < count, units[end] == .openParen {
                    out.add(index, end, .function)
                } else {
                    out.add(index, end, .constant)
                }
                index = end
            } else {
                index += 1
            }
        }
        return out.spans
    }
}

// MARK: - Markdown

/// Markdown source: headings, quotes, list markers, fences (colored in their own language), and
/// inline code, emphasis and links.
private struct MarkdownScanner {
    let units: [UInt16]
    var out = Emitter()
    init(_ units: [UInt16]) { self.units = units }

    mutating func run() -> [HighlightSpan] {
        var index = 0
        let count = units.count
        while index < count {
            let end = lineEnd(units, from: index)
            var position = index
            while position < end, units[position].isBlank { position += 1 }
            if matches(units, position, "```") || matches(units, position, "~~~") {
                index = fence(index, position, end)
                continue
            }
            if position < end, units[position] == .hash {
                var level = position
                while level < end, units[level] == .hash { level += 1 }
                if level - position <= 6, level == end || units[level].isBlank {
                    out.add(position, end, .heading)
                    index = end + 1
                    continue
                }
            }
            if position < end, units[position] == .greaterThan {
                out.add(position, end, .quote)
                index = end + 1
                continue
            }
            if position + 1 < end, [UInt16.dash, .star, .plus].contains(units[position]), units[position + 1].isBlank {
                out.add(position, position + 1, .listMarker)
                position += 1
            } else {
                var digits = position
                while digits < end, units[digits].isDigit { digits += 1 }
                if digits > position, digits + 1 < end, units[digits] == .dot || units[digits] == .closeParen, units[digits + 1].isBlank {
                    out.add(position, digits + 1, .listMarker)
                    position = digits + 1
                }
            }
            if matches(units, position, " [ ]") || matches(units, position, " [x]") || matches(units, position, " [X]") {
                out.add(position + 1, position + 4, .listMarker)
            }
            inline(position, end)
            index = end + 1
        }
        return out.spans
    }

    private mutating func fence(_ lineStart: Int, _ position: Int, _ end: Int) -> Int {
        let marker = string(units[position..<(position + 3)])
        let info = string(units[(position + 3)..<end]).trimmingCharacters(in: .whitespaces)
        out.add(position, end, .code)
        var bodyStart = end + 1
        var close = bodyStart
        while close < units.count {
            let stop = lineEnd(units, from: close)
            var first = close
            while first < stop, units[first].isBlank { first += 1 }
            if matches(units, first, marker) {
                highlightBody(bodyStart, close, info: info)
                out.add(first, stop, .code)
                return stop + 1
            }
            close = stop + 1
        }
        bodyStart = min(bodyStart, units.count)
        highlightBody(bodyStart, units.count, info: info)
        return units.count
    }

    private mutating func highlightBody(_ start: Int, _ end: Int, info: String) {
        guard start < end else { return }
        let language = SourceLanguage.of(fence: info)
        let body = string(units[start..<end])
        let inner = language == .plain || language == .markdown ? [] : SyntaxHighlighter.spans(in: body, language: language)
        if inner.isEmpty { return out.add(start, end, .code) }
        for span in inner { out.add(start + span.location, start + span.location + span.length, span.token) }
    }

    private mutating func inline(_ start: Int, _ end: Int) {
        var position = start
        while position < end {
            let unit = units[position]
            if unit == .backtick {
                var close = position + 1
                while close < end, units[close] != .backtick { close += 1 }
                if close < end { out.add(position, close + 1, .code); position = close + 1; continue }
            } else if unit == .star || unit == .underscore, position + 1 < end {
                let strong = units[position + 1] == unit
                let width = strong ? 2 : 1
                var close = position + width
                while close + width <= end, !(units[close] == unit && (!strong || units[close + 1] == unit)) { close += 1 }
                if close + width <= end, close > position + width, !units[position + width].isBlank {
                    out.add(position, close + width, strong ? .strong : .emphasis)
                    position = close + width
                    continue
                }
            } else if unit == .openBracket || (unit == .exclamation && position + 1 < end && units[position + 1] == .openBracket) {
                var close = position + 1
                while close < end, units[close] != .closeBracket { close += 1 }
                if close + 1 < end, units[close + 1] == .openParen {
                    var paren = close + 2
                    while paren < end, units[paren] != .closeParen { paren += 1 }
                    if paren < end { out.add(position, paren + 1, .link); position = paren + 1; continue }
                }
            }
            position += 1
        }
    }
}
