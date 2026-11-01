import Foundation
import SwiftTerm
import CodecCore

/// Where panes' contents are kept between launches: one file per pane, readable only by the user,
/// since a scrollback can hold anything.
@MainActor
final class PaneArchive {
    /// `~/Library/Application Support/Codec/Saved Panes`.
    static var standardFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Codec/Saved Panes", isDirectory: true)
    }

    let folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    private func url(_ name: String) -> URL {
        folder.appendingPathComponent(name).appendingPathExtension("json")
    }

    func save(_ contents: SavedPaneContents, as name: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = url(name)
        try JSONEncoder().encode(contents).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func load(_ name: String) -> SavedPaneContents? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(SavedPaneContents.self, from: data)
    }

    /// Deletes every kept pane but these.
    func keepOnly(_ names: Set<String>) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" && !names.contains(file.deletingPathExtension().lastPathComponent) {
            try? manager.removeItem(at: file)
        }
    }
}

/// Tabs closed lately, newest last, to open again with ⇧⌘T: their splits, folders and, for a while,
/// what their panes showed.
@MainActor
final class ClosedTabs {
    struct Entry {
        var tab: SavedTab
        /// Each pane's contents, by the name `tab` gives them.
        var contents: [String: SavedPaneContents]
    }

    private(set) var entries: [Entry] = []
    let limit: Int

    init(limit: Int = 10) {
        self.limit = limit
    }

    var isEmpty: Bool { entries.isEmpty }

    func push(_ entry: Entry) {
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    func pop() -> Entry? {
        entries.popLast()
    }
}

/// Writes rows of a terminal back out as text with escape sequences, so printing it into another
/// terminal shows the same thing, in the same colors.
enum TerminalTranscript {
    static func text(of rows: [TerminalContentRowSnapshot]) -> String {
        var result = ""
        var current = Attribute.empty
        for (index, row) in rows.enumerated() {
            let continues = rows.indices.contains(index + 1) && rows[index + 1].isWrapped
            var cells = row.cells.filter { $0.width > 0 }
            // Blank cells at the end, unless the line goes on to the next row and needs them to wrap there.
            if !continues {
                while let last = cells.last, isBlank(last.text), !paintsBackground(last.attribute) {
                    cells.removeLast()
                }
            }
            for cell in cells {
                if cell.attribute != current {
                    result += sgr(cell.attribute)
                    current = cell.attribute
                }
                result += isBlank(cell.text) ? " " : cell.text
            }
            if !continues {
                if current != .empty {
                    result += "\u{1B}[0m"
                    current = .empty
                }
                result += "\r\n"
            }
        }
        if current != .empty { result += "\u{1B}[0m" }
        return result
    }

    /// A cell nothing was written to holds a NUL; one that was erased, a space.
    private static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0 == "\0" || $0 == " " }
    }

    /// Whether a blank cell with `attribute` shows anything: a background color, or the inverse.
    private static func paintsBackground(_ attribute: Attribute) -> Bool {
        if attribute.style.contains(.inverse) { return true }
        switch attribute.bg {
        case .defaultColor, .defaultInvertedColor: return false
        case .ansi256, .trueColor: return true
        }
    }

    /// The sequence that switches to `attribute` from anything.
    static func sgr(_ attribute: Attribute) -> String {
        var codes = ["0"]
        let style = attribute.style
        if style.contains(.bold) { codes.append("1") }
        if style.contains(.dim) { codes.append("2") }
        if style.contains(.italic) { codes.append("3") }
        if style.contains(.underline) { codes.append("4") }
        if style.contains(.blink) { codes.append("5") }
        if style.contains(.inverse) { codes.append("7") }
        if style.contains(.invisible) { codes.append("8") }
        if style.contains(.crossedOut) { codes.append("9") }
        codes += color(attribute.fg, foreground: true)
        codes += color(attribute.bg, foreground: false)
        return "\u{1B}[" + codes.joined(separator: ";") + "m"
    }

    private static func color(_ color: Attribute.Color, foreground: Bool) -> [String] {
        switch color {
        case .ansi256(let code):
            if code < 8 { return [String((foreground ? 30 : 40) + Int(code))] }
            if code < 16 { return [String((foreground ? 90 : 100) + Int(code) - 8)] }
            return [foreground ? "38" : "48", "5", String(code)]
        case .trueColor(let red, let green, let blue):
            return [foreground ? "38" : "48", "2", String(red), String(green), String(blue)]
        case .defaultColor, .defaultInvertedColor:
            return []
        }
    }
}
