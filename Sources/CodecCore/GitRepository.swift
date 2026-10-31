import Foundation

/// A branch of a repository, local or on a remote.
public struct GitBranch: Equatable, Hashable, Sendable, Identifiable {
    /// The short name: `main`, or `origin/feature` for a remote branch.
    public var name: String
    public var isRemote: Bool
    public var isCurrent: Bool
    /// When its last commit was made, as git says it: "2 days ago".
    public var lastCommit: String

    public var id: String { (isRemote ? "remote:" : "local:") + name }

    /// What to switch to: a remote branch's name without its remote, which git turns into a tracking branch.
    public var localName: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }

    public init(name: String, isRemote: Bool, isCurrent: Bool, lastCommit: String) {
        self.name = name
        self.isRemote = isRemote
        self.isCurrent = isCurrent
        self.lastCommit = lastCommit
    }
}

public struct GitError: Error, Equatable, LocalizedError, Sendable {
    /// What git printed, trimmed: what the user needs to read.
    public var message: String
    public var errorDescription: String? { message }

    public init(_ message: String) {
        self.message = message
    }
}

/// Runs git; injectable so tests and previews can stand in for it.
public protocol GitRunning: Sendable {
    func run(_ arguments: [String], in directory: URL) async throws -> (status: Int32, output: String, errors: String)
}

/// Runs `/usr/bin/git` as a subprocess, without a terminal and without prompting.
public struct ProcessGitRunner: GitRunning {
    public init() {}

    public func run(_ arguments: [String], in directory: URL) async throws -> (status: Int32, output: String, errors: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            // Never wait for a password or an editor that nobody can see.
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_EDITOR"] = "true"
            process.environment = environment
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: (finished.terminationStatus, out, err))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: GitError("Couldn't run git: \(error.localizedDescription)"))
            }
        }
    }
}

/// The repository containing a directory: its branches, and switching between them.
public struct GitRepository: Sendable {
    public let directory: URL
    private let git: any GitRunning

    public init(directory: URL, runner: any GitRunning = ProcessGitRunner()) {
        self.directory = directory
        self.git = runner
    }

    /// Local branches, most recently committed first, then remote branches that have no local
    /// counterpart yet.
    public func branches() async throws -> [GitBranch] {
        let format = "%(refname)%00%(HEAD)%00%(committerdate:relative)"
        let output = try await run(["for-each-ref", "--sort=-committerdate", "--format=\(format)", "refs/heads", "refs/remotes"])
        var local: [GitBranch] = [], remote: [GitBranch] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { continue }
            let reference = fields[0]
            if reference.hasPrefix("refs/heads/") {
                local.append(GitBranch(name: String(reference.dropFirst("refs/heads/".count)), isRemote: false,
                                       isCurrent: fields[1] == "*", lastCommit: fields[2]))
            } else if reference.hasPrefix("refs/remotes/"), !reference.hasSuffix("/HEAD") {
                remote.append(GitBranch(name: String(reference.dropFirst("refs/remotes/".count)), isRemote: true,
                                        isCurrent: false, lastCommit: fields[2]))
            }
        }
        let localNames = Set(local.map(\.name))
        return local + remote.filter { !localNames.contains($0.localName) }
    }

    /// Switches to `branch`. A remote branch becomes a local branch that tracks it.
    public func switchTo(_ branch: GitBranch) async throws {
        // Branch names can't start with "-" (git rejects them), so they can't be read as options.
        _ = try await run(branch.isRemote ? ["switch", "--track", branch.name] : ["switch", branch.name])
    }

    /// Creates `name` from the current commit and switches to it.
    public func createBranch(_ name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard try await isValidBranchName(trimmed) else {
            throw GitError("“\(trimmed)” isn’t a valid branch name.")
        }
        _ = try await run(["switch", "-c", trimmed])
    }

    /// Whether git accepts `name` as a new branch name.
    public func isValidBranchName(_ name: String) async throws -> Bool {
        guard !name.isEmpty else { return false }
        return try await git.run(["check-ref-format", "--branch", name], in: directory).status == 0
    }

    private func run(_ arguments: [String]) async throws -> String {
        let result = try await git.run(arguments, in: directory)
        guard result.status == 0 else {
            let message = (result.errors.isEmpty ? result.output : result.errors).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message.isEmpty ? "git \(arguments.first ?? "") failed." : message)
        }
        return result.output
    }
}
