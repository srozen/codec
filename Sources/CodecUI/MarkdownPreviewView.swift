import AppKit
import WebKit
import UniformTypeIdentifiers
import CodecCore

/// Shows a Markdown document rendered, styled from the theme. Page scripts are off; local images are
/// served from disk, web links open in the browser and links to other files open in the editor.
final class MarkdownPreviewView: NSView, WKNavigationDelegate {
    static let scheme = "codec-file"

    let document: EditorDocument
    /// Opens a local file the preview links to.
    var openFile: ((URL) -> Void)?
    private(set) var webView: WKWebView!
    private var theme: CodecTheme
    private var codeFont: NSFont
    private var loaded = false
    private var pendingBody: String?
    private var renderScheduled = false
    /// The last HTML rendered, for tests.
    private(set) var renderedBody = ""

    init(document: EditorDocument, theme: CodecTheme, codeFont: NSFont) {
        self.document = document
        self.theme = theme
        self.codeFont = codeFont
        super.init(frame: .zero)
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: Self.scheme)
        configuration.suppressesIncrementalRendering = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setAccessibilityLabel("Preview of \(document.name)")
        addSubview(webView)
        NSLayoutConstraint.activate(webView.constraintsFilling(self))
        loadPage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: CodecTheme, codeFont: NSFont) {
        guard theme != self.theme || codeFont != self.codeFont else { return }
        self.theme = theme
        self.codeFont = codeFont
        loaded = false
        loadPage()
    }

    /// The text changed: render again shortly, in place.
    func documentChanged() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.renderScheduled = false
                self.updateBody()
            }
        }
    }

    private var body: String {
        MarkdownRenderer().html(from: document.text)
    }

    private func loadPage() {
        renderedBody = body
        let base = Self.url(for: document.url.deletingLastPathComponent(), directory: true)
        webView.loadHTMLString(Self.page(body: renderedBody, theme: theme, codeFont: codeFont), baseURL: base)
    }

    private func updateBody() {
        let html = body
        guard html != renderedBody else { return }
        renderedBody = html
        guard loaded else {
            pendingBody = html
            return
        }
        replaceBody(html)
    }

    private func replaceBody(_ html: String) {
        guard let data = try? JSONEncoder().encode(html), let literal = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("document.getElementById('content').innerHTML = \(literal);", completionHandler: nil)
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let pendingBody {
            self.pendingBody = nil
            replaceBody(pendingBody)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url else { return decisionHandler(.allow) }
        // Jumps within the page.
        if url.scheme == Self.scheme, url.fragment != nil, Self.fileURL(for: url)?.standardizedFileURL == document.url {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        if url.scheme == Self.scheme, let file = Self.fileURL(for: url) {
            openFile?(file)
        } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: URLs

    static func url(for file: URL, directory: Bool = false) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "local"
        components.path = file.standardizedFileURL.path + (directory && !file.path.hasSuffix("/") ? "/" : "")
        return components.url
    }

    static func fileURL(for url: URL) -> URL? {
        guard url.scheme == scheme else { return nil }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    // MARK: Page

    static func page(body: String, theme: CodecTheme, codeFont: NSFont) -> String {
        func css(_ color: NSColor) -> String {
            let rgb = color.usingColorSpace(.sRGB) ?? color
            return String(format: "rgba(%d,%d,%d,%.3f)", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                          Int(rgb.blueComponent * 255), rgb.alphaComponent)
        }
        let foreground = theme.foreground
        let muted = theme.background.blended(withFraction: 0.62, of: foreground) ?? foreground
        let faint = foreground.withAlphaComponent(theme.isDark ? 0.07 : 0.06)
        let rule = foreground.withAlphaComponent(theme.isDark ? 0.13 : 0.15)
        let tokens = SyntaxToken.allCases.map { ".hl-\($0.rawValue) { color: \(css(theme.color(for: $0))); }" }.joined(separator: "\n")
        let fontFamily = codeFont.familyName.map { "\"\($0)\", " } ?? ""
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="color-scheme" content="\(theme.isDark ? "dark" : "light")">
        <style>
        :root { color-scheme: \(theme.isDark ? "dark" : "light"); }
        html, body { background: transparent; margin: 0; }
        body { color: \(css(foreground)); font: 14px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
               -webkit-font-smoothing: antialiased; }
        #content { max-width: 760px; margin: 0 auto; padding: 20px 28px 64px; overflow-wrap: break-word; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.6em 0 0.6em; font-weight: 650; letter-spacing: -0.01em; }
        h1 { font-size: 1.9em; padding-bottom: 0.3em; border-bottom: 1px solid \(css(rule)); }
        h2 { font-size: 1.45em; padding-bottom: 0.25em; border-bottom: 1px solid \(css(rule)); }
        h3 { font-size: 1.2em; } h4 { font-size: 1em; } h5, h6 { font-size: 0.9em; color: \(css(muted)); }
        #content > :first-child { margin-top: 0.2em; }
        p, ul, ol, blockquote, table, pre { margin: 0 0 1em; }
        a { color: \(css(theme.ansi[4])); text-decoration: none; }
        a:hover { text-decoration: underline; }
        strong { font-weight: 650; }
        hr { border: 0; height: 1px; background: \(css(rule)); margin: 2em 0; }
        code, pre { font-family: \(fontFamily)ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.88em; }
        :not(pre) > code { background: \(css(faint)); padding: 0.15em 0.4em; border-radius: 5px; }
        pre { background: \(css(faint)); padding: 12px 14px; border-radius: 9px; overflow-x: auto; line-height: 1.5;
              border: 1px solid \(css(rule)); position: relative; }
        pre[data-language] { padding-top: 26px; }
        pre[data-language]::after { content: attr(data-language); position: absolute; top: 6px; right: 10px; font-size: 10px;
              color: \(css(muted)); font-family: -apple-system, sans-serif; text-transform: lowercase; }
        blockquote { margin-left: 0; padding: 0.1em 1em; color: \(css(muted)); border-left: 3px solid \(css(theme.accent.withAlphaComponent(0.6))); }
        ul, ol { padding-left: 1.6em; } li + li { margin-top: 0.2em; } li > ul, li > ol { margin: 0.2em 0 0; }
        ul.tasks { list-style: none; padding-left: 0.4em; } ul.tasks input { margin: 0 0.45em 0 0; accent-color: \(css(theme.accent)); }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid \(css(rule)); padding: 6px 12px; }
        th { font-weight: 600; background: \(css(faint)); }
        tr:nth-child(2n) td { background: \(css(foreground.withAlphaComponent(0.025))); }
        img { max-width: 100%; border-radius: 4px; }
        ::selection { background: \(css(theme.selection)); }
        \(tokens)
        .hl-comment { font-style: italic; }
        </style></head>
        <body><div id="content">\(body)</div></body></html>
        """
    }
}

/// Serves local files to the preview: images next to the Markdown file and the like.
final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = MarkdownPreviewView.fileURL(for: url),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
