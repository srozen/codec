import Testing
import Foundation
@testable import CodecCore

@Suite("SyntaxHighlighter")
struct SyntaxHighlighterTests {
    /// The colored pieces of `text`, as (text, token).
    private func pieces(_ text: String, _ language: SourceLanguage) -> [(String, SyntaxToken)] {
        let string = text as NSString
        return SyntaxHighlighter.spans(in: text, language: language).map { (string.substring(with: $0.range), $0.token) }
    }

    private func token(of piece: String, in text: String, _ language: SourceLanguage) -> SyntaxToken? {
        pieces(text, language).first { $0.0 == piece }?.1
    }

    @Test func swift() {
        let code = """
        @MainActor final class Pane: NSObject { // the pane
            let count = 0x1F + 3.5e-2
            func run() async throws -> String? { return "hi \\(name)" ?? nil }
            #if DEBUG
            let MAX_SIZE = view.frame.width
        }
        /* block */
        """
        #expect(token(of: "@MainActor", in: code, .swift) == .attribute)
        #expect(token(of: "final", in: code, .swift) == .keyword)
        #expect(token(of: "Pane", in: code, .swift) == .type)
        #expect(token(of: "// the pane", in: code, .swift) == .comment)
        #expect(token(of: "0x1F", in: code, .swift) == .number)
        #expect(token(of: "3.5e-2", in: code, .swift) == .number)
        #expect(token(of: "run", in: code, .swift) == .function)
        #expect(token(of: "\"hi \\(name)\"", in: code, .swift) == .string)
        #expect(token(of: "nil", in: code, .swift) == .constant)
        #expect(token(of: "#if", in: code, .swift) == .preprocessor)
        #expect(token(of: "MAX_SIZE", in: code, .swift) == .constant)
        #expect(token(of: "frame", in: code, .swift) == .property)
        #expect(token(of: "/* block */", in: code, .swift) == .comment)
    }

    @Test func multilineStringsAndUnterminatedOnes() {
        let code = "let a = \"\"\"\nline \"one\"\n\"\"\"\nlet b = \"open\nlet c = 1"
        #expect(token(of: "\"\"\"\nline \"one\"\n\"\"\"", in: code, .swift) == .string)
        // An unterminated string stops at the end of its line.
        #expect(token(of: "\"open", in: code, .swift) == .string)
        #expect(token(of: "1", in: code, .swift) == .number)
    }

    @Test func pythonAndShell() {
        let python = "def greet(name: str) -> None:\n    '''doc'''\n    return f\"hi\"  # done\n@decorator\nx = True"
        #expect(token(of: "def", in: python, .python) == .keyword)
        #expect(token(of: "greet", in: python, .python) == .function)
        #expect(token(of: "str", in: python, .python) == .type)
        #expect(token(of: "'''doc'''", in: python, .python) == .string)
        #expect(token(of: "# done", in: python, .python) == .comment)
        #expect(token(of: "@decorator", in: python, .python) == .attribute)
        #expect(token(of: "True", in: python, .python) == .constant)

        let shell = "if [ -n \"$HOME\" ]; then echo ${PATH} $# # note\nfi"
        #expect(token(of: "if", in: shell, .shell) == .keyword)
        #expect(token(of: "\"$HOME\"", in: shell, .shell) == .string)
        #expect(token(of: "${PATH}", in: shell, .shell) == .variable)
        #expect(token(of: "$#", in: shell, .shell) == .variable)
        #expect(token(of: "# note", in: shell, .shell) == .comment)
    }

    @Test func sqlIgnoresCase() {
        #expect(token(of: "SELECT", in: "SELECT id FROM users -- all", .sql) == .keyword)
        #expect(token(of: "-- all", in: "SELECT id FROM users -- all", .sql) == .comment)
    }

    @Test func json() {
        let json = "{\"name\": \"codec\", \"count\": -12.5, \"ok\": true, \"none\": null}"
        #expect(token(of: "\"name\"", in: json, .json) == .property)
        #expect(token(of: "\"codec\"", in: json, .json) == .string)
        #expect(token(of: "-12.5", in: json, .json) == .number)
        #expect(token(of: "true", in: json, .json) == .constant)
        #expect(token(of: "null", in: json, .json) == .constant)
    }

    @Test func yamlAndToml() {
        let yaml = "# config\nname: codec\nversion: 1.2\nitems:\n  - enabled: true # yes\n  - 'quoted'\n"
        #expect(token(of: "# config", in: yaml, .yaml) == .comment)
        #expect(token(of: "name", in: yaml, .yaml) == .property)
        #expect(token(of: "codec", in: yaml, .yaml) == .string)
        #expect(token(of: "1.2", in: yaml, .yaml) == .number)
        #expect(token(of: "enabled", in: yaml, .yaml) == .property)
        #expect(token(of: "true", in: yaml, .yaml) == .constant)
        #expect(token(of: "# yes", in: yaml, .yaml) == .comment)
        #expect(token(of: "'quoted'", in: yaml, .yaml) == .string)

        let toml = "[package]\nname = \"codec\" # app\nversion = 2\n"
        #expect(token(of: "[package]", in: toml, .toml) == .heading)
        #expect(token(of: "name ", in: toml, .toml) == .property)
        #expect(token(of: "\"codec\"", in: toml, .toml) == .string)
        #expect(token(of: "# app", in: toml, .toml) == .comment)
        #expect(token(of: "2", in: toml, .toml) == .number)
    }

    @Test func markupAndCSS() {
        let html = "<!-- hi --><a href=\"/x\" class='y'>Tom &amp; Jerry</a>"
        #expect(token(of: "<!-- hi -->", in: html, .markup) == .comment)
        #expect(token(of: "a", in: html, .markup) == .tag)
        #expect(token(of: "href", in: html, .markup) == .attribute)
        #expect(token(of: "\"/x\"", in: html, .markup) == .string)
        #expect(token(of: "&amp;", in: html, .markup) == .constant)

        let css = "@media screen { .card > h1 { color: #fff; margin: 4px; transform: scale(2); } }"
        #expect(token(of: "@media", in: css, .css) == .keyword)
        #expect(token(of: ".card", in: css, .css) == .attribute)
        #expect(token(of: "color", in: css, .css) == .property)
        #expect(token(of: "#fff", in: css, .css) == .number)
        #expect(token(of: "4px", in: css, .css) == .number)
        #expect(token(of: "scale", in: css, .css) == .function)
    }

    @Test func markdown() {
        let markdown = """
        # Title
        > quoted
        - item with `code` and **bold** and *em*
        1. [link](https://x.y)
        - [ ] task
        ```swift
        let x = 1
        ```
        """
        #expect(token(of: "# Title", in: markdown, .markdown) == .heading)
        #expect(token(of: "> quoted", in: markdown, .markdown) == .quote)
        #expect(token(of: "-", in: markdown, .markdown) == .listMarker)
        #expect(token(of: "`code`", in: markdown, .markdown) == .code)
        #expect(token(of: "**bold**", in: markdown, .markdown) == .strong)
        #expect(token(of: "*em*", in: markdown, .markdown) == .emphasis)
        #expect(token(of: "[link](https://x.y)", in: markdown, .markdown) == .link)
        #expect(token(of: "[ ]", in: markdown, .markdown) == .listMarker)
        // Code blocks are colored in their own language.
        #expect(token(of: "let", in: markdown, .markdown) == .keyword)
        #expect(token(of: "```swift", in: markdown, .markdown) == .code)
    }

    @Test func spansAreInUTF16AndOrdered() {
        let text = "let 🎉 = \"é\" // ok"
        let spans = SyntaxHighlighter.spans(in: text, language: .swift)
        #expect(spans.map(\.location) == spans.map(\.location).sorted())
        #expect(token(of: "\"é\"", in: text, .swift) == .string)
        #expect(token(of: "// ok", in: text, .swift) == .comment)
        #expect(SyntaxHighlighter.spans(in: "anything", language: .plain).isEmpty)
    }

    @Test(arguments: [
        ("main.swift", SourceLanguage.swift), ("Package.swift", .swift), ("app.tsx", .typescript), ("run.sh", .shell),
        (".env", .shell), ("Dockerfile", .shell), ("config.yml", .yaml), ("Cargo.toml", .toml), ("index.html", .markup),
        ("README.md", .markdown), ("package.json", .json), ("notes.txt", .plain), ("Gemfile", .ruby),
    ])
    func languagesFromNames(name: String, expected: SourceLanguage) {
        #expect(SourceLanguage.of(fileNamed: name) == expected)
    }

    @Test func handlesLargeInputQuickly() {
        let code = String(repeating: "func f(x: Int) -> Int { return x * 2 } // c\n", count: 20_000)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = SyntaxHighlighter.spans(in: code, language: .swift) }
        #expect(elapsed < .seconds(2))
    }
}
