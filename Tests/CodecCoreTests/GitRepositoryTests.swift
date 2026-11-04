import Testing
import Foundation
@testable import CodecCore

private let hasGit = FileManager.default.isExecutableFile(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
    || FileManager.default.fileExists(atPath: "/Applications/Xcode.app")

/// Runs git for test setup, with an identity so commits work anywhere.
@discardableResult
private func git(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "init.defaultBranch=main"] + arguments
    process.currentDirectoryURL = directory
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw GitError("setup failed: git \(arguments)") }
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

private func commit(_ file: String, _ contents: String, message: String, in directory: URL) throws {
    try contents.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
    try git(["add", "."], in: directory)
    try git(["commit", "-qm", message], in: directory)
}

/// An "origin" with `main` and `remote-only`, and a clone of it with an extra local branch.
private func makeClone(in temp: TemporaryDirectory) throws -> URL {
    let origin = try temp.directory("origin")
    try git(["init", "-q"], in: origin)
    try commit("file.txt", "one\n", message: "first", in: origin)
    try git(["branch", "remote-only"], in: origin)
    let clone = temp.url.appendingPathComponent("clone")
    try git(["clone", "-q", origin.path, clone.path], in: temp.url)
    try git(["branch", "local-only"], in: clone)
    return clone
}

@Suite("GitRepository", .serialized, .enabled(if: hasGit))
struct GitRepositoryTests {
    @Test func listsLocalBranchesThenRemoteOnes() async throws {
        let temp = try TemporaryDirectory()
        let repository = GitRepository(directory: try makeClone(in: temp))
        let branches = try await repository.branches()
        #expect(Set(branches.filter { !$0.isRemote }.map(\.name)) == ["main", "local-only"])
        #expect(branches.filter(\.isCurrent).map(\.name) == ["main"])
        // origin/main has a local branch already, and origin/HEAD is a pointer, not a branch.
        #expect(branches.filter(\.isRemote).map(\.name) == ["origin/remote-only"])
        #expect(branches.first { $0.isRemote }?.localName == "remote-only")
        #expect(branches.allSatisfy { !$0.lastCommit.isEmpty })
        #expect(branches.firstIndex { $0.isRemote }! > branches.lastIndex { !$0.isRemote }!)
    }

    @Test func switchesToLocalAndRemoteBranches() async throws {
        let temp = try TemporaryDirectory()
        let clone = try makeClone(in: temp)
        let repository = GitRepository(directory: clone)
        let branches = try await repository.branches()

        try await repository.switchTo(try #require(branches.first { $0.name == "local-only" }))
        #expect(GitInfo.branch(at: clone) == "local-only")

        try await repository.switchTo(try #require(branches.first { $0.name == "origin/remote-only" }))
        #expect(GitInfo.branch(at: clone) == "remote-only")
        let upstream = try git(["rev-parse", "--abbrev-ref", "remote-only@{upstream}"], in: clone)
        #expect(upstream.trimmingCharacters(in: .whitespacesAndNewlines) == "origin/remote-only")
        #expect(try await repository.branches().filter(\.isRemote).isEmpty)
    }

    @Test func reportsWhyASwitchFailed() async throws {
        let temp = try TemporaryDirectory()
        let clone = try makeClone(in: temp)
        try git(["switch", "-q", "local-only"], in: clone)
        try commit("file.txt", "changed on local-only\n", message: "change", in: clone)
        try git(["switch", "-q", "main"], in: clone)
        try "uncommitted\n".write(to: clone.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let repository = GitRepository(directory: clone)
        let target = try #require(try await repository.branches().first { $0.name == "local-only" })
        await #expect(throws: GitError.self) { try await repository.switchTo(target) }
        do {
            try await repository.switchTo(target)
        } catch let error as GitError {
            #expect(error.message.contains("would be overwritten"))
        }
        #expect(GitInfo.branch(at: clone) == "main")
    }

    @Test func createsBranchesAndRejectsBadNames() async throws {
        let temp = try TemporaryDirectory()
        let clone = try makeClone(in: temp)
        let repository = GitRepository(directory: clone)
        try await repository.createBranch("  feature/new-thing ")
        #expect(GitInfo.branch(at: clone) == "feature/new-thing")
        for bad in ["", "has space", "double..dot", "-starts-with-dash", "ends.lock"] {
            #expect(try await !repository.isValidBranchName(bad), "\(bad)")
        }
        await #expect(throws: GitError.self) { try await repository.createBranch("has space") }
    }

    /// The file tree reads the status whenever the repository changes, which is when another app is
    /// likely committing or staging: it must never hold the index's lock against that app.
    @Test func readsTheStatusWithoutRewritingTheIndex() async throws {
        let temp = try TemporaryDirectory()
        let clone = try makeClone(in: temp)
        // The same contents with another date: git would refresh the index to record it.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                              ofItemAtPath: clone.appendingPathComponent("file.txt").path)
        let index = clone.appendingPathComponent(".git/index")
        let before = try Data(contentsOf: index)
        #expect(try await GitRepository(directory: clone).status().isEmpty)
        #expect(try Data(contentsOf: index) == before)
    }

    @Test func failsCleanlyOutsideARepository() async throws {
        let temp = try TemporaryDirectory()
        let repository = GitRepository(directory: try temp.directory("plain"))
        await #expect(throws: GitError.self) { try await repository.branches() }
        #expect(await repository.committedText(of: "anything.txt") == nil)
    }

    @Test func readsAFileAsTheLastCommitHasIt() async throws {
        let temp = try TemporaryDirectory()
        let clone = try makeClone(in: temp)
        try "two\n".write(to: clone.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: clone.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try commit("Sources/deep.txt", "deep\n", message: "second", in: clone)
        try "changed\n".write(to: clone.appendingPathComponent("Sources/deep.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: clone.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        // `commit` adds everything, so file.txt's change is committed too.
        #expect(await GitRepository(directory: clone).committedText(of: "file.txt") == "two\n")
        // Relative to the directory, not the repository's root.
        #expect(await GitRepository(directory: clone.appendingPathComponent("Sources")).committedText(of: "deep.txt") == "deep\n")
        #expect(await GitRepository(directory: clone).committedText(of: "new.txt") == nil)
    }
}

/// A runner that records calls and answers from a script.
private final class ScriptedRunner: GitRunning, @unchecked Sendable {
    var calls: [[String]] = []
    let answer: (status: Int32, output: String, errors: String)
    init(_ answer: (Int32, String, String)) { self.answer = answer }
    func run(_ arguments: [String], in directory: URL) async throws -> (status: Int32, output: String, errors: String) {
        calls.append(arguments)
        return answer
    }
}

@Suite("GitRepository commands")
struct GitRepositoryCommandTests {
    @Test func remoteBranchesAreSwitchedToWithTracking() async throws {
        let runner = ScriptedRunner((0, "", ""))
        let repository = GitRepository(directory: URL(fileURLWithPath: "/tmp"), runner: runner)
        try await repository.switchTo(GitBranch(name: "upstream/fix", isRemote: true, isCurrent: false, lastCommit: ""))
        try await repository.switchTo(GitBranch(name: "main", isRemote: false, isCurrent: false, lastCommit: ""))
        #expect(runner.calls == [["switch", "--track", "upstream/fix"], ["switch", "main"]])
    }

    @Test func usesGitsMessageAsTheError() async {
        let runner = ScriptedRunner((1, "", "error: pathspec 'x' did not match\n"))
        let repository = GitRepository(directory: URL(fileURLWithPath: "/tmp"), runner: runner)
        await #expect(throws: GitError("error: pathspec 'x' did not match")) {
            try await repository.switchTo(GitBranch(name: "x", isRemote: false, isCurrent: false, lastCommit: ""))
        }
    }
}
