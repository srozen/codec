import Foundation

/// The Python environment and tool versions in effect in a shell: a virtual environment (one Codec
/// activated, or one activated some other way) or conda environment, and the tools mise or another
/// version manager picked.
public struct Toolchain: Codable, Equatable, Sendable {
    /// The active Python environment, if any.
    public var python: PythonEnvironment?
    /// The tools version managers pick here, by name.
    public var tools: [Tool]

    public init(python: PythonEnvironment? = nil, tools: [Tool] = []) {
        self.python = python
        self.tools = tools
    }

    public var isEmpty: Bool { python == nil && tools.isEmpty }

    /// Tools a config file asks for that aren't installed: the manager falls back to another version, or to none.
    public var missing: [Tool] { tools.filter { !$0.installed } }

    /// Tools that aren't what the project asks for: not installed, or another version on the PATH.
    public var needingAttention: [Tool] { tools.filter(\.needsAttention) }

    /// One line for labels and the model: `python 3.14.6 (.venv demo) · ruby 4.0.2 · node 22 (not installed)`.
    public var summary: String {
        var parts: [String] = []
        if let python {
            parts.append(["python", python.version, "(\(python.label))"].compactMap { $0 }.joined(separator: " "))
        }
        for tool in tools where !(python != nil && tool.name == "python") {
            var part = "\(tool.name) \(tool.version)"
            if !tool.installed {
                part += " (not installed)"
            } else if !tool.matchesRequest, let requested = tool.requested {
                part += " (\((tool.source.map { ($0 as NSString).lastPathComponent }) ?? "the project") asks for \(requested))"
            }
            parts.append(part)
        }
        return parts.joined(separator: " · ")
    }

    /// Versions only, for narrow labels: `py 3.14.6 · ruby 4.0.2 · node 22!`, a missing tool marked.
    public var shortSummary: String {
        var parts: [String] = []
        if let python { parts.append("py " + (python.version ?? python.label)) }
        for tool in tools where !(python != nil && tool.name == "python") {
            parts.append(tool.installed ? "\(tool.name) \(tool.version)" + (tool.matchesRequest ? "" : "!")
                                        : "\(tool.name) \(tool.requested ?? tool.version)!")
        }
        return parts.joined(separator: " · ")
    }

    /// A virtual environment (a folder with a `pyvenv.cfg`, as `uv venv`, `uv sync` or `python -m venv`
    /// make) or a conda environment.
    public struct PythonEnvironment: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case virtualEnv, conda
        }

        /// The environment's folder, usually `…/project/.venv`.
        public var path: String
        /// Its Python's version, from `pyvenv.cfg` or conda's package records.
        public var version: String?
        /// The project's name, as uv records it (`prompt =`), or the conda environment's; nil when the venv has none.
        public var name: String?
        /// Codec activated it; otherwise it was activated by hand or by another tool.
        public var activatedByCodec: Bool
        public var kind: Kind

        public init(path: String, version: String? = nil, name: String? = nil, activatedByCodec: Bool = false,
                    kind: Kind = .virtualEnv) {
            self.path = path
            self.version = version
            self.name = name
            self.activatedByCodec = activatedByCodec
            self.kind = kind
        }

        /// The folder holding the environment: the project.
        public var project: String { (path as NSString).deletingLastPathComponent }

        /// What to call it: the project's name, or the folder's when the venv doesn't say.
        public var label: String {
            let folder = (path as NSString).lastPathComponent
            let projectName = (project as NSString).lastPathComponent
            guard kind == .virtualEnv, folder == ".venv" || folder == "venv" else { return name ?? folder }
            return name.flatMap { $0.isEmpty ? nil : $0 } ?? projectName
        }

        /// Reads `pyvenv.cfg` in `path`; nil when it isn't a virtual environment.
        public static func read(at path: String, activatedByCodec: Bool = false) -> PythonEnvironment? {
            let config = (path as NSString).appendingPathComponent("pyvenv.cfg")
            guard let text = try? String(contentsOfFile: config, encoding: .utf8) else { return nil }
            return PythonEnvironment(path: path, configuration: text, activatedByCodec: activatedByCodec)
        }

        /// An environment from the text of its `pyvenv.cfg`: uv writes `version_info`, venv `version`.
        public init(path: String, configuration: String, activatedByCodec: Bool = false) {
            var values: [String: String] = [:]
            for line in configuration.split(whereSeparator: \.isNewline) {
                guard let equals = line.firstIndex(of: "=") else { continue }
                let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                values[key] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
            self.init(path: path, version: values["version_info"] ?? values["version"],
                      name: values["prompt"], activatedByCodec: activatedByCodec)
        }
    }

    /// A tool a version manager picked for this folder.
    public struct Tool: Codable, Equatable, Sendable, Identifiable {
        public var name: String
        /// The version in use, or the one that would be once installed.
        public var version: String
        /// What the config file asked for (`3`, `lts`, `22.1.0`).
        public var requested: String?
        /// The file that set it (`mise.toml`, `.tool-versions`, `.ruby-version`…), or the variable.
        public var source: String?
        /// Whether what's asked for is installed.
        public var installed: Bool
        public var installPath: String?
        /// What picked it: `mise`, `pyenv`, `nvm`… (see `VersionManagers`).
        public var manager: String

        public var id: String { name }

        public init(name: String, version: String, requested: String? = nil, source: String? = nil,
                    installed: Bool = true, installPath: String? = nil, manager: String = "mise") {
            self.name = name
            self.version = version
            self.requested = requested
            self.source = source
            self.installed = installed
            self.installPath = installPath
            self.manager = manager
        }

        /// Whether the version in use is the one asked for: `22` asks for any 22.x. An alias (`lts`,
        /// `latest`, `system`) can't be checked, so it matches.
        public var matchesRequest: Bool {
            guard let requested, VersionManagers.looksLikeVersion(requested) else { return true }
            let asked = requested.hasPrefix("v") ? String(requested.dropFirst()) : requested
            return version == asked || version.hasPrefix(asked + ".") || version.hasPrefix(asked + "-")
        }

        public var needsAttention: Bool { !installed || !matchesRequest }

        /// The command that installs what's asked for, when the manager has one.
        public var installCommand: String? {
            switch manager {
            case "mise": return "mise install"
            case "asdf": return "asdf install"
            case "nvm": return "nvm install"
            case "fnm": return "fnm install"
            case "pyenv", "rbenv", "nodenv":
                return requested.map { "\(manager) install \(ShellQuoting.quote($0))" }
            default: return nil
            }
        }

        /// The command that puts what's asked for on the PATH, for managers that only switch when told.
        public var switchCommand: String? {
            switch manager {
            case "nvm": return "nvm use"
            case "fnm": return "fnm use"
            case "chruby": return requested.map { "chruby \(ShellQuoting.quote($0))" }
            default: return nil
            }
        }

        /// Set by the user's own configuration rather than a project's: a file in their home folder or in
        /// a hidden folder there (`~/.config/mise`, `~/.pyenv`). A variable is this shell's, not global.
        public func isGlobal(home: String = NSHomeDirectory()) -> Bool {
            guard let source else { return true }
            guard source.hasPrefix("/") else { return false }
            let folder = (source as NSString).deletingLastPathComponent
            return folder == home || folder.hasPrefix(home + "/.")
        }
    }

    /// The tools in `mise ls --current --json`, by name. A tool listed with several versions uses the
    /// first. Nil when it isn't that output.
    public static func miseTools(fromJSON json: String) -> [Tool]? {
        struct Entry: Decodable {
            struct Source: Decodable { var path: String? }
            var version: String
            var requested_version: String?
            var install_path: String?
            var source: Source?
            var installed: Bool?
        }
        guard let data = json.data(using: .utf8),
              let listing = try? JSONDecoder().decode([String: [Entry]].self, from: data) else { return nil }
        return listing.compactMap { name, entries in
            entries.first.map { entry in
                Tool(name: name, version: entry.version, requested: entry.requested_version, source: entry.source?.path,
                     installed: entry.installed ?? true, installPath: entry.install_path)
            }
        }
        .sorted { $0.name < $1.name }
    }
}

/// What the shell reports about its environment at a prompt, when it changed (see `IntegrationEvent.toolchain`).
public struct ToolchainReport: Equatable, Sendable {
    /// `$VIRTUAL_ENV`, if set.
    public var virtualEnv: String?
    /// Codec activated it.
    public var activatedByCodec: Bool
    /// A virtual environment found here that the user hasn't said whether to activate.
    public var pending: String?
    /// The output of `mise ls --current --json`; empty without mise.
    public var mise: String
    /// The shell's folder (`PWD`), the other version managers it has (`managers`, space-separated) and
    /// the variables they and conda set.
    public var environment: [String: String]

    public init(virtualEnv: String? = nil, activatedByCodec: Bool = false, pending: String? = nil, mise: String = "",
                environment: [String: String] = [:]) {
        self.virtualEnv = virtualEnv
        self.activatedByCodec = activatedByCodec
        self.pending = pending
        self.mise = mise
        self.environment = environment
    }

    /// `KEY=value` lines, as the shell sends `environment`.
    public static func environment(fromLines text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "="), equals != line.startIndex else { continue }
            result[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return result
    }

    /// The version managers besides mise the shell has.
    public var managers: Set<String> {
        Set((environment["managers"] ?? "").split(separator: " ").map(String.init)).intersection(VersionManagers.names)
    }

    /// The toolchain this describes, reading the virtual environment's `pyvenv.cfg` with `read`, and the
    /// other managers' version files from disk.
    public func toolchain(home: String = NSHomeDirectory(),
                          read: (String, Bool) -> Toolchain.PythonEnvironment? = { Toolchain.PythonEnvironment.read(at: $0, activatedByCodec: $1) })
        -> Toolchain {
        // A virtual environment comes before conda's on the PATH.
        let python = virtualEnv.map { path in
            read(path, activatedByCodec) ?? Toolchain.PythonEnvironment(path: path, activatedByCodec: activatedByCodec)
        } ?? VersionManagers.condaEnvironment(environment: environment)
        var tools = Toolchain.miseTools(fromJSON: mise) ?? []
        if let directory = environment["PWD"], !managers.isEmpty {
            for tool in VersionManagers.tools(directory: directory, environment: environment, managers: managers, home: home)
            where !tools.contains(where: { $0.name == tool.name }) {
                tools.append(tool)
            }
            tools.sort { $0.name < $1.name }
        }
        return Toolchain(python: python, tools: tools)
    }
}

/// Which virtual environments the user let Codec activate, and which not. One line per answer,
/// `allow` or `deny`, a tab, then the environment's path; the last answer for a path wins. The zsh
/// integration reads the same file.
public struct VenvDecisions: Sendable {
    public enum Decision: String, Sendable, CaseIterable {
        case allow, deny
    }

    /// One remembered answer.
    public struct Entry: Equatable, Sendable, Identifiable {
        /// Whether the environment it's about is still there.
        public enum Status: Equatable, Sendable {
            case present
            /// The project's folder is there, its `.venv` isn't: deleted, or not made again yet.
            case environmentMissing
            /// The project's folder isn't there: moved, deleted, or on a disk that isn't connected.
            case projectMissing
        }

        /// The environment's folder, `…/project/.venv`.
        public var path: String
        public var decision: Decision

        public init(path: String, decision: Decision) {
            self.path = path
            self.decision = decision
        }

        public var id: String { path }
        public var project: String { (path as NSString).deletingLastPathComponent }

        public func status(fileManager: FileManager = .default) -> Status {
            var isFolder: ObjCBool = false
            guard fileManager.fileExists(atPath: project, isDirectory: &isFolder), isFolder.boolValue else { return .projectMissing }
            return fileManager.fileExists(atPath: path + "/pyvenv.cfg") ? .present : .environmentMissing
        }
    }

    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func decision(for path: String) -> Decision? {
        Self.decisions(in: (try? String(contentsOf: file, encoding: .utf8)) ?? "")[path]
    }

    /// Records an answer, replacing any earlier one for the same environment.
    public func set(_ decision: Decision, for path: String) throws {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var lines = text.split(separator: "\n").map(String.init).filter { Self.parse($0)?.path != path }
        lines.append("\(decision.rawValue)\t\(path)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// Every answer, oldest first.
    public var entries: [Entry] {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var entries: [Entry] = []
        for line in text.split(separator: "\n") {
            guard let parsed = Self.parse(String(line)) else { continue }
            entries.removeAll { $0.path == parsed.path }
            entries.append(Entry(path: parsed.path, decision: parsed.decision))
        }
        return entries
    }

    /// Forgets the answer about one environment: Codec asks again next time.
    public func remove(_ path: String) throws {
        try write(entries.filter { $0.path != path })
    }

    /// Forgets the answers about environments that can't be found anymore, and says how many.
    @discardableResult
    public func removeMissing(fileManager: FileManager = .default) throws -> Int {
        let entries = self.entries
        let kept = entries.filter { $0.status(fileManager: fileManager) == .present }
        if kept.count != entries.count { try write(kept) }
        return entries.count - kept.count
    }

    private func write(_ entries: [Entry]) throws {
        guard !entries.isEmpty else { return try clear() }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (entries.map { "\($0.decision.rawValue)\t\($0.path)" }.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
    }

    /// Forgets every answer: Codec asks again.
    public func clear() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    /// Whether there are answers to forget.
    public var isEmpty: Bool {
        Self.decisions(in: (try? String(contentsOf: file, encoding: .utf8)) ?? "").isEmpty
    }

    static func decisions(in text: String) -> [String: Decision] {
        var result: [String: Decision] = [:]
        for line in text.split(separator: "\n") {
            if let entry = parse(String(line)) { result[entry.path] = entry.decision }
        }
        return result
    }

    private static func parse(_ line: String) -> (decision: Decision, path: String)? {
        guard let tab = line.firstIndex(of: "\t"), let decision = Decision(rawValue: String(line[..<tab])) else { return nil }
        let path = String(line[line.index(after: tab)...])
        return path.isEmpty ? nil : (decision, path)
    }
}
