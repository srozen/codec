import Testing
import Foundation
@testable import CodecCore

@Suite("FileListing")
struct FileListingTests {
    private func touch(_ path: String, in temp: TemporaryDirectory) throws {
        let url = temp.url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    @Test func listsFoldersFirstInFindersOrder() throws {
        let temp = try TemporaryDirectory()
        for file in ["file10.txt", "file2.txt", "Zeta.md", ".env", ".DS_Store", "src/main.swift", ".git/HEAD", "App.app/Contents/Info.plist"] {
            try touch(file, in: temp)
        }
        let names = FileListing.entries(in: temp.url, showHidden: false).map(\.name)
        #expect(names == ["src", "App.app", "file2.txt", "file10.txt", "Zeta.md"])
        let entries = FileListing.entries(in: temp.url, showHidden: true)
        #expect(entries.map(\.name) == ["src", ".env", "App.app", "file2.txt", "file10.txt", "Zeta.md"])
        // An app is a file, as in Finder; git's folder never shows.
        #expect(entries.first { $0.name == "App.app" }?.isDirectory == false)
        #expect(entries.first { $0.name == "src" }?.isDirectory == true)
    }

    @Test func followsLinksToFolders() throws {
        let temp = try TemporaryDirectory()
        try touch("real/file", in: temp)
        try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("link"),
                                                   withDestinationURL: temp.url.appendingPathComponent("real"))
        let link = FileListing.entries(in: temp.url, showHidden: false).first { $0.name == "link" }
        #expect(link?.isDirectory == true)
    }

    @Test func searchCandidatesSkipHiddenAndDependencyFolders() throws {
        let temp = try TemporaryDirectory()
        for file in ["a.txt", "src/b.swift", ".hidden/c", "node_modules/pkg/index.js", "src/.secret"] {
            try touch(file, in: temp)
        }
        #expect(Set(FileListing.searchCandidates(under: temp.url)) == ["a.txt", "src/b.swift"])
        #expect(FileListing.searchCandidates(under: temp.url, limit: 1).count == 1)
    }

    @Test func searchPrefersMatchesInTheName() {
        let paths = ["Sources/Pane/View.swift", "Sources/CodecUI/PaneView.swift", "README.md", "Tests/PaneTests.swift"]
        #expect(FileListing.search(paths, for: "paneview") == ["Sources/CodecUI/PaneView.swift", "Sources/Pane/View.swift"])
        #expect(FileListing.search(paths, for: "readme") == ["README.md"])
        #expect(FileListing.search(paths, for: "  ").isEmpty)
        #expect(FileListing.search(paths, for: "s", limit: 2).count == 2)
    }
}

@Suite("GitStatus")
struct GitStatusTests {
    private let status = GitStatus(porcelain: [
        " M Sources/App/Main.swift", "A  Sources/New.swift", " D gone.txt", "R  renamed.txt", "old.txt",
        "?? notes/", "?? scratch.txt", "!! .build/", "!! debug.log", "UU conflict.swift",
    ].joined(separator: "\0") + "\0")

    @Test func readsEachFilesState() {
        #expect(status.kind(of: "Sources/App/Main.swift") == .modified)
        #expect(status.kind(of: "Sources/New.swift") == .added)
        #expect(status.kind(of: "gone.txt") == .deleted)
        #expect(status.kind(of: "renamed.txt") == .renamed)
        // The old path of a rename isn't an entry of its own.
        #expect(status.kind(of: "old.txt") == nil)
        #expect(status.kind(of: "scratch.txt") == .untracked)
        #expect(status.kind(of: "debug.log") == .ignored)
        #expect(status.kind(of: "conflict.swift") == .conflicted)
        #expect(status.kind(of: "README.md") == nil)
    }

    @Test func foldersPassTheirStateDown() {
        #expect(status.kind(of: "notes") == .untracked)
        #expect(status.kind(of: "notes/today/todo.md") == .untracked)
        #expect(status.kind(of: ".build/debug/app") == .ignored)
        #expect(status.kind(of: "Sources") == nil)
    }

    @Test func foldersKnowTheyHoldChanges() {
        #expect(status.containsChanges("Sources"))
        #expect(status.containsChanges("Sources/App"))
        #expect(!status.containsChanges("Tests"))
        // Ignored files don't count as changes.
        #expect(!status.containsChanges(".build"))
        #expect(GitStatus(porcelain: "").isEmpty)
    }

    @Test func readsARealRepository() async throws {
        guard FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
            || FileManager.default.fileExists(atPath: "/Applications/Xcode.app") else { return }
        let temp = try TemporaryDirectory()
        let run = { (arguments: [String]) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "user.name=Test", "-c", "user.email=t@example.com"] + arguments
            process.currentDirectoryURL = temp.url
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        try run(["init", "-q"])
        try "a\n".write(to: temp.url.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "ignored.log\n".write(to: temp.url.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try run(["add", "."])
        try run(["commit", "-qm", "first"])
        try "b\n".write(to: temp.url.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "x\n".write(to: temp.url.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try "x\n".write(to: temp.url.appendingPathComponent("ignored.log"), atomically: true, encoding: .utf8)

        let repository = GitRepository(directory: temp.url)
        let status = try await repository.status()
        #expect(status.kind(of: "tracked.txt") == .modified)
        #expect(status.kind(of: "new.txt") == .untracked)
        #expect(status.kind(of: "ignored.log") == .ignored)
        #expect(Set(try await repository.files()) == [".gitignore", "tracked.txt", "new.txt"])
    }
}

@Suite("ShellQuoting")
struct ShellQuotingTests {
    @Test(arguments: [
        ("Sources/main.swift", "Sources/main.swift"),
        ("My File.txt", "'My File.txt'"),
        ("it's", "'it'\\''s'"),
        ("$HOME", "'$HOME'"),
        ("~user", "'~user'"),
        ("", "''"),
        ("a;rm -rf", "'a;rm -rf'"),
    ])
    func quotesWhenNeeded(text: String, expected: String) {
        #expect(ShellQuoting.quote(text) == expected)
    }
}

@Suite("GitInfo work tree")
struct WorkTreeRootTests {
    @Test func findsTheRootAbove() throws {
        let temp = try TemporaryDirectory()
        let repo = try temp.directory("repo")
        try temp.directory("repo/.git")
        let deep = try temp.directory("repo/a/b")
        #expect(GitInfo.workTreeRoot(containing: deep)?.standardizedFileURL.path == repo.standardizedFileURL.path)
        #expect(GitInfo.workTreeRoot(containing: try temp.directory("elsewhere")) == nil)
    }
}
