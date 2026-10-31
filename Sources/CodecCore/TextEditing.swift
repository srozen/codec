import Foundation

/// Reading files for the editor.
public enum TextFile {
    public enum Content: Equatable, Sendable {
        case text(String)
        /// Has NUL bytes: not something to edit as text.
        case binary
        /// Text, but not UTF-8; shown read-only so saving can't mangle it.
        case otherEncoding(String)
        case tooLarge(Int)
    }

    /// Larger files open in their app instead.
    public static let sizeLimit = 8 * 1024 * 1024

    public static func read(_ url: URL) throws -> Content {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > sizeLimit { return .tooLarge(size) }
        return read(try Data(contentsOf: url))
    }

    public static func read(_ data: Data) -> Content {
        if data.count > sizeLimit { return .tooLarge(data.count) }
        if data.prefix(8_192).contains(0) { return .binary }
        if let text = String(data: data, encoding: .utf8) {
            // A byte order mark isn't part of the text.
            return .text(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        }
        if let text = String(data: data, encoding: .isoLatin1) { return .otherEncoding(text) }
        return .binary
    }
}

/// How a file indents: what Tab inserts.
public enum Indentation: Equatable, Sendable {
    case tabs
    case spaces(Int)

    public var unit: String {
        switch self {
        case .tabs: "\t"
        case .spaces(let count): String(repeating: " ", count: count)
        }
    }

    /// The file's own style: tabs if most indented lines start with one, otherwise the most common
    /// step between indentation levels. Four spaces when there's nothing to go by.
    public static func detect(in text: String) -> Indentation {
        var tabs = 0, spaceLines = 0
        var steps: [Int: Int] = [:]
        var previous = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(2_000) {
            guard let first = line.first, first == " " || first == "\t" else {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { previous = 0 }
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if first == "\t" { tabs += 1; continue }
            let width = line.prefix(while: { $0 == " " }).count
            spaceLines += 1
            let step = abs(width - previous)
            if step > 1 && step <= 8 { steps[step, default: 0] += 1 }
            previous = width
        }
        if tabs > spaceLines { return .tabs }
        guard let common = steps.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key else { return .spaces(4) }
        return .spaces(common)
    }
}

/// Small editing rules the editor applies.
public enum TextEditing {
    /// What Return inserts at the end of `line`: a newline, the line's indentation, and one more level
    /// after an opening bracket (or a colon, in Python and YAML).
    public static func newline(after line: String, indentation: Indentation, language: SourceLanguage) -> String {
        let leading = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var opens = ["{", "[", "("].contains(where: { trimmed.hasSuffix($0) })
        if [.python, .yaml].contains(language), trimmed.hasSuffix(":") { opens = true }
        return "\n" + leading + (opens ? indentation.unit : "")
    }

    /// Comments out lines with `prefix`, or uncomments them when every non-blank line already is.
    /// The marker goes at the shallowest indentation, as editors do.
    public static func toggleComment(_ lines: [String], prefix: String) -> [String] {
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !content.isEmpty else { return lines }
        let commented = content.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }
        if commented {
            return lines.map { line in
                guard let range = line.range(of: prefix) else { return line }
                var result = line
                let after = line[range.upperBound...]
                result.replaceSubrange(range.lowerBound..<(after.first == " " ? line.index(after: range.upperBound) : range.upperBound), with: "")
                return result
            }
        }
        let depth = content.map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }.min() ?? 0
        return lines.map { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            let index = line.index(line.startIndex, offsetBy: depth)
            return String(line[..<index]) + prefix + " " + String(line[index...])
        }
    }

    /// Removes one level of indentation from the start of a line.
    public static func outdent(_ line: String, indentation: Indentation) -> String {
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        let width: Int
        if case .spaces(let count) = indentation { width = count } else { width = 4 }
        let spaces = line.prefix(while: { $0 == " " }).count
        return String(line.dropFirst(min(spaces, width)))
    }
}
