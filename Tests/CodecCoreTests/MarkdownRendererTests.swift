import Testing
@testable import CodecCore

@Suite("MarkdownRenderer")
struct MarkdownRendererTests {
    private let renderer = MarkdownRenderer()
    private func html(_ markdown: String) -> String { renderer.html(from: markdown) }

    @Test func headingsAndParagraphs() {
        #expect(html("# Hello *world*\n\nSome text\nwrapped.") ==
                "<h1 id=\"hello-world\">Hello <em>world</em></h1>\n<p>Some text\nwrapped.</p>\n")
        #expect(html("Title\n=====\nSub\n---") == "<h1 id=\"title\">Title</h1>\n<h2 id=\"sub\">Sub</h2>\n")
        #expect(html("## Closed ##") == "<h2 id=\"closed\">Closed</h2>\n")
        #expect(html("#NotAHeading") == "<p>#NotAHeading</p>\n")
        // Repeated headings get distinct anchors.
        #expect(html("# A\n# A").contains("id=\"a-1\""))
    }

    @Test func inlineFormatting() {
        #expect(renderer.inline("**bold** and __also__, *em* and _em_, ~~gone~~") ==
                "<strong>bold</strong> and <strong>also</strong>, <em>em</em> and <em>em</em>, <del>gone</del>")
        #expect(renderer.inline("snake_case_name stays") == "snake_case_name stays")
        #expect(renderer.inline("2 * 3 * 4") == "2 * 3 * 4")
        #expect(renderer.inline("`a *b* <c>` and ``x ` y``") == "<code>a *b* &lt;c&gt;</code> and <code>x ` y</code>")
        #expect(renderer.inline("\\*not em\\*") == "*not em*")
    }

    @Test func linksAndImages() {
        #expect(renderer.inline("[Codec](https://x.dev/a_b_c) and ![logo](img/logo.png \"Logo\")") ==
                "<a href=\"https://x.dev/a_b_c\">Codec</a> and <img src=\"img/logo.png\" alt=\"logo\">")
        #expect(renderer.inline("see https://example.com/path_x. and <https://a.b>") ==
                "see <a href=\"https://example.com/path_x\">https://example.com/path_x</a>. and <a href=\"https://a.b\">https://a.b</a>")
        let resolving = MarkdownRenderer(resolveImage: { "asset://" + $0 })
        #expect(resolving.inline("![x](a.png)") == "<img src=\"asset://a.png\" alt=\"x\">")
    }

    @Test func escapesHTMLInText() {
        #expect(renderer.inline("<script>alert(1)</script> & \"q\"") == "&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;q&quot;")
    }

    @Test func passesHTMLBlocksThrough() {
        #expect(html("<p align=\"center\">\n  <img src=\"x.png\">\n</p>\n\nafter") ==
                "<p align=\"center\">\n  <img src=\"x.png\">\n</p>\n<p>after</p>\n")
    }

    @Test func codeBlocks() {
        let rendered = html("```swift\nlet x = \"<a>\"\n```\n\n    indented <code>")
        #expect(rendered.contains("<pre data-language=\"swift\"><code><span class=\"hl-keyword\">let</span> x = <span class=\"hl-string\">&quot;&lt;a&gt;&quot;</span></code></pre>"))
        #expect(rendered.contains("<pre><code>indented &lt;code&gt;</code></pre>"))
        // An unclosed fence runs to the end.
        #expect(html("```\nopen").contains("<pre><code>open</code></pre>"))
    }

    @Test func lists() {
        #expect(html("- one\n- two\n  - nested\n- three") ==
                "<ul>\n<li>one</li>\n<li>two\n<ul>\n<li>nested</li>\n</ul></li>\n<li>three</li>\n</ul>\n")
        #expect(html("3. c\n4. d") == "<ol start=\"3\">\n<li>c</li>\n<li>d</li>\n</ol>\n")
        #expect(html("- a\n\n- b") == "<ul>\n<li><p>a</p></li>\n<li><p>b</p></li>\n</ul>\n")
        #expect(html("- [ ] todo\n- [x] done") ==
                "<ul class=\"tasks\">\n<li><input type=\"checkbox\" disabled> todo</li>\n<li><input type=\"checkbox\" disabled checked> done</li>\n</ul>\n")
        #expect(html("Text\n- item").contains("<ul>"))
        #expect(html("* * *") == "<hr>\n")
    }

    @Test func quotes() {
        #expect(html("> quoted\nlazy\n> > nested") ==
                "<blockquote>\n<p>quoted\nlazy</p>\n<blockquote>\n<p>nested</p>\n</blockquote>\n</blockquote>\n")
    }

    @Test func tables() {
        let rendered = html("| Name | Size |\n|:-----|-----:|\n| a `x|y` | 1 |\n| b | 2 |\n\nafter")
        #expect(rendered == """
        <table>
        <thead>
        <tr><th style="text-align:left">Name</th><th style="text-align:right">Size</th></tr>
        </thead>
        <tbody>
        <tr><td style="text-align:left">a <code>x|y</code></td><td style="text-align:right">1</td></tr>
        <tr><td style="text-align:left">b</td><td style="text-align:right">2</td></tr>
        </tbody>
        </table>
        <p>after</p>

        """)
        // Without a separator row it's just text.
        #expect(html("a | b\nc | d") == "<p>a | b\nc | d</p>\n")
    }

    @Test func hardBreaks() {
        #expect(html("one  \ntwo\\\nthree") == "<p>one<br>two<br>three</p>\n")
    }

    @Test func slugs() {
        #expect(MarkdownRenderer.slug("Build, run & test!") == "build-run--test")
        #expect(MarkdownRenderer.slug("`Code` *here*") == "code-here")
    }
}
