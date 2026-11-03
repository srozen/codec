import Foundation

/// A file named in a command's output, as ⌘-click finds it: a name `ls` listed, a path `git status`
/// or `grep` printed, a compiler's `file.swift:42:7`. Names are relative to where the command ran, or
/// to a folder it was given, as in `ls Sources`.
public enum FileReference {
    /// The existing file or folder `token` names, looking in each of `directories` in turn, or nil.
    public static func resolve(_ token: String, in directories: [String],
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        for candidate in candidates(token) {
            let paths = candidate.hasPrefix("/")
                ? [candidate]
                : directories.filter { !$0.isEmpty }.map { ($0 as NSString).appendingPathComponent(candidate) }
            if let path = paths.map({ ($0 as NSString).standardizingPath }).first(where: exists) { return path }
        }
        return nil
    }

    /// The folders a command's output names files from: the one it ran in, then the folders among its
    /// arguments.
    public static func directories(command: String, in directory: String,
                                   isDirectory: (String) -> Bool = { FileReference.isDirectory($0) }) -> [String] {
        guard !directory.isEmpty else { return [] }
        let line = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var directories = [directory]
        // Words, split at the operators that end them too, as in `ls Sources; ls Tests`.
        let words = line.split { $0.isWhitespace || ";&|()<>".contains($0) }
        for word in words.dropFirst() where !word.hasPrefix("-") {
            let path = (unquoted(String(word)) as NSString).expandingTildeInPath
            guard !path.isEmpty else { continue }
            let full = path.hasPrefix("/") ? path : (directory as NSString).appendingPathComponent(path)
            let standardized = (full as NSString).standardizingPath
            if isDirectory(standardized), !directories.contains(standardized) { directories.append(standardized) }
        }
        return directories
    }

    /// How to show the path a name opens: relative to the shell's directory when it's inside it, else
    /// from `~`. Nil when that's just what the name says, as for `README.md` listed where you are.
    public static func label(for path: String, named name: String, from directory: String,
                             home: String = NSHomeDirectory()) -> String? {
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        var label = path
        if !directory.isEmpty, path.hasPrefix(base) {
            label = String(path.dropFirst(base.count))
        } else if path == home || path.hasPrefix(home + "/") {
            label = "~" + path.dropFirst(home.count)
        }
        var said = name
        if said.hasPrefix("./") { said.removeFirst(2) }
        while said.count > 1, said.hasSuffix("/") { said.removeLast() }
        return label == said ? nil : label
    }

    public static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// What a token may name, most literal first: itself, then without a `:line` or `:line:column`
    /// after it, then without the mark `ls -F` puts after executables (`*`), links (`@`) and sockets (`=`).
    static func candidates(_ token: String) -> [String] {
        guard !token.isEmpty, !token.contains("://") else { return [] }
        var candidates = [token]
        if let location = token.range(of: #":[0-9]+(:[0-9]+)?$"#, options: .regularExpression) {
            candidates.append(String(token[..<location.lowerBound]))
        }
        if let last = token.last, "*@=".contains(last), token.count > 1 {
            candidates.append(String(token.dropLast()))
        }
        return candidates.filter { !$0.isEmpty }.map { ($0 as NSString).expandingTildeInPath }
    }

    private static func unquoted(_ word: String) -> String {
        guard word.count >= 2, let first = word.first, first == word.last, first == "'" || first == "\"" else { return word }
        return String(word.dropFirst().dropLast())
    }
}
