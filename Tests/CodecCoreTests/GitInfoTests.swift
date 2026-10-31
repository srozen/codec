import Testing
import Foundation
@testable import CodecCore

/// A scratch directory removed when the test ends.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codec-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func directory(_ path: String) throws -> URL {
        let directory = url.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    func file(_ path: String, _ contents: String) throws -> URL {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

@Suite("GitInfo")
struct GitInfoTests {
    @Test func readsTheBranchAtTheRepositoryRoot() throws {
        let temp = try TemporaryDirectory()
        try temp.file("repo/.git/HEAD", "ref: refs/heads/main\n")
        #expect(GitInfo.branch(at: temp.url.appendingPathComponent("repo")) == "main")
    }

    @Test func walksUpFromSubdirectories() throws {
        let temp = try TemporaryDirectory()
        try temp.file("repo/.git/HEAD", "ref: refs/heads/feature/blocks\n")
        let nested = try temp.directory("repo/Sources/App/Deep")
        #expect(GitInfo.branch(at: nested) == "feature/blocks")
    }

    @Test func shortensDetachedHeads() throws {
        let temp = try TemporaryDirectory()
        try temp.file("repo/.git/HEAD", "3f9a2c41d0e7b6a5c4d3e2f1a0b9c8d7e6f5a4b3\n")
        #expect(GitInfo.branch(at: temp.url.appendingPathComponent("repo")) == "3f9a2c4")
    }

    @Test func followsGitdirFilesForWorktrees() throws {
        let temp = try TemporaryDirectory()
        try temp.file("main/.git/worktrees/wt/HEAD", "ref: refs/heads/hotfix\n")
        try temp.file("wt/.git", "gitdir: ../main/.git/worktrees/wt\n")
        #expect(GitInfo.branch(at: temp.url.appendingPathComponent("wt")) == "hotfix")
    }

    @Test func returnsNilOutsideARepository() throws {
        let temp = try TemporaryDirectory()
        let plain = try temp.directory("plain/folder")
        #expect(GitInfo.branch(at: plain) == nil)
    }

    /// Regression: walking up from a directory outside any repository must stop at the root.
    @Test(.timeLimit(.minutes(1)))
    func stopsAtTheFilesystemRoot() {
        #expect(GitInfo.branch(at: URL(fileURLWithPath: "/")) == nil)
        #expect(GitInfo.branch(at: URL(fileURLWithPath: "/usr/bin")) == nil)
    }

    @Test func returnsNilForABrokenRepository() throws {
        let temp = try TemporaryDirectory()
        try temp.directory("repo/.git")
        try temp.file("other/.git", "not a pointer")
        #expect(GitInfo.branch(at: temp.url.appendingPathComponent("repo")) == nil)
        #expect(GitInfo.branch(at: temp.url.appendingPathComponent("other")) == nil)
    }

    @Test func usesTheInnermostRepository() throws {
        let temp = try TemporaryDirectory()
        try temp.file("outer/.git/HEAD", "ref: refs/heads/main\n")
        try temp.file("outer/vendor/inner/.git/HEAD", "ref: refs/heads/v2\n")
        #expect(GitInfo.branch(at: temp.url.appendingPathComponent("outer/vendor/inner")) == "v2")
        #expect(GitInfo.branch(at: try temp.directory("outer/vendor")) == "main")
    }
}
