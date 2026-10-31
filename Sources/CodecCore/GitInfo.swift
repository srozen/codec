import Foundation

public enum GitInfo {
    /// The checked-out branch, or the short commit when HEAD is detached, of the repository
    /// containing `directory`. Reads `.git` directly; never runs `git`.
    public static func branch(at directory: URL, fileManager: FileManager = .default) -> String? {
        // Walk up by path components: URL("/").deletingLastPathComponent() is "/..", not "/",
        // so comparing URLs never reaches a fixed point.
        var components = directory.standardizedFileURL.pathComponents
        while !components.isEmpty {
            let url = URL(fileURLWithPath: NSString.path(withComponents: components), isDirectory: true)
            if let gitDirectory = gitDirectory(in: url, fileManager: fileManager) {
                return head(in: gitDirectory)
            }
            components.removeLast()
        }
        return nil
    }

    /// The git directory for a working tree root, following the `gitdir:` file used by worktrees and submodules.
    private static func gitDirectory(in directory: URL, fileManager: FileManager) -> URL? {
        let dotGit = directory.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8),
              contents.hasPrefix("gitdir:") else { return nil }
        let path = contents.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
    }

    private static func head(in gitDirectory: URL) -> String? {
        guard let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else { return nil }
        let prefix = "ref: refs/heads/"
        if head.hasPrefix(prefix) { return String(head.dropFirst(prefix.count)) }
        if head.hasPrefix("ref: ") { return String(head.dropFirst("ref: ".count)) }
        return String(head.prefix(7))
    }
}
