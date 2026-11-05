import Foundation

/// Tool versions from the version managers people use besides mise, read from their version files and
/// the variables they set, without running them: running each would cost tens of milliseconds at a
/// prompt. mise reads these files itself, so this is only for shells where mise isn't active.
///
/// pyenv, rbenv, nodenv and asdf switch through shims, so what a project pins is what runs. nvm, fnm
/// and chruby switch the PATH instead, only when asked (or on `cd`, when set up to): what runs comes
/// from their variables, and may not be what the project asks for.
public enum VersionManagers {
    /// The managers the shell reports, by the names it uses.
    public static let names: Set<String> = ["pyenv", "rbenv", "nodenv", "asdf", "nvm", "fnm", "chruby"]

    /// The tools the active managers pick for `directory`, given the shell's variables. A tool two
    /// managers know comes from the first: the dedicated one before asdf.
    public static func tools(directory: String, environment: [String: String], managers: Set<String>,
                             home: String = NSHomeDirectory(), fileManager: FileManager = .default) -> [Toolchain.Tool] {
        let files = VersionFiles(directory: directory, fileManager: fileManager)
        var tools: [Toolchain.Tool] = []
        func add(_ tool: Toolchain.Tool?) {
            guard let tool, !tools.contains(where: { $0.name == tool.name }) else { return }
            tools.append(tool)
        }
        let shims: [(manager: String, tool: String, file: String, variable: String, root: String)] = [
            ("pyenv", "python", ".python-version", "PYENV_VERSION", environment["PYENV_ROOT"] ?? home + "/.pyenv"),
            ("rbenv", "ruby", ".ruby-version", "RBENV_VERSION", environment["RBENV_ROOT"] ?? home + "/.rbenv"),
            ("nodenv", "node", ".node-version", "NODENV_VERSION", environment["NODENV_ROOT"] ?? home + "/.nodenv"),
        ]
        for shim in shims where managers.contains(shim.manager) {
            add(shimmed(shim.tool, manager: shim.manager, file: shim.file, variable: shim.variable, root: shim.root,
                        environment: environment, files: files, fileManager: fileManager))
        }
        if managers.contains("nvm") {
            add(nvm(environment: environment, home: home, files: files, fileManager: fileManager))
        }
        if managers.contains("fnm") {
            add(fnm(environment: environment, files: files, fileManager: fileManager))
        }
        if managers.contains("chruby") {
            add(chruby(environment: environment, home: home, files: files, fileManager: fileManager))
        }
        if managers.contains("asdf") {
            asdf(environment: environment, home: home, files: files, fileManager: fileManager).forEach(add)
        }
        return tools.sorted { $0.name < $1.name }
    }

    // MARK: Managers

    /// pyenv, rbenv and nodenv: the shell's override, else the nearest version file, else the global one.
    private static func shimmed(_ name: String, manager: String, file: String, variable: String, root: String,
                                environment: [String: String], files: VersionFiles,
                                fileManager: FileManager) -> Toolchain.Tool? {
        let pin: (version: String, source: String)?
        if let version = environment[variable].flatMap(firstVersion) {
            pin = (version, variable)
        } else if let found = files.nearest(file).flatMap({ found in firstVersion(in: found.text).map { ($0, found.path) } }) {
            pin = found
        } else {
            let global = root + "/version"
            pin = files.read(global).flatMap(firstVersion).map { ($0, global) }
        }
        guard let pin else { return nil }
        if pin.version == "system" {
            return Toolchain.Tool(name: name, version: "system", source: pin.source, manager: manager)
        }
        let installed = installedVersion(pin.version, in: root + "/versions", fileManager: fileManager)
        return Toolchain.Tool(name: name, version: installed ?? pin.version, requested: pin.version, source: pin.source,
                              installed: installed != nil, installPath: installed.map { root + "/versions/" + $0 },
                              manager: manager)
    }

    /// nvm: the node on the PATH (`NVM_BIN` is `…/versions/node/v20.11.0/bin`), and what `.nvmrc` asks for.
    private static func nvm(environment: [String: String], home: String, files: VersionFiles,
                            fileManager: FileManager) -> Toolchain.Tool? {
        let inUse = environment["NVM_BIN"].flatMap { version(in: $0, after: "/versions/node/") }
        let pin = files.nearest(".nvmrc").flatMap { found in firstVersion(in: found.text).map { (strip($0), found.path) } }
        let versions = (environment["NVM_DIR"] ?? home + "/.nvm") + "/versions/node"
        return switched("node", manager: "nvm", inUse: inUse, pin: pin, versions: versions, prefix: "v", fileManager: fileManager)
    }

    /// fnm: the node its per-shell link points at, and what `.node-version` or `.nvmrc` asks for.
    private static func fnm(environment: [String: String], files: VersionFiles, fileManager: FileManager) -> Toolchain.Tool? {
        let inUse = environment["FNM_MULTISHELL_PATH"]
            .flatMap { try? fileManager.destinationOfSymbolicLink(atPath: $0) }
            .flatMap { version(in: $0, after: "/node-versions/") }
        let pin = (files.nearest(".node-version") ?? files.nearest(".nvmrc"))
            .flatMap { found in firstVersion(in: found.text).map { (strip($0), found.path) } }
        let versions = environment["FNM_DIR"].map { $0 + "/node-versions" }
        return switched("node", manager: "fnm", inUse: inUse, pin: pin, versions: versions, prefix: "v", fileManager: fileManager)
    }

    /// chruby: the Ruby in `RUBY_ROOT` (`~/.rubies/ruby-3.3.0`), and what `.ruby-version` asks for.
    private static func chruby(environment: [String: String], home: String, files: VersionFiles,
                               fileManager: FileManager) -> Toolchain.Tool? {
        let inUse = environment["RUBY_ROOT"].map { ($0 as NSString).lastPathComponent }
            .map { $0.hasPrefix("ruby-") ? String($0.dropFirst(5)) : $0 }
        let pin = files.nearest(".ruby-version")
            .flatMap { found in firstVersion(in: found.text).map { (strip($0, "ruby-"), found.path) } }
        return switched("ruby", manager: "chruby", inUse: inUse, pin: pin, versions: home + "/.rubies", prefix: "ruby-",
                        fileManager: fileManager)
    }

    /// A tool whose manager switches the PATH: in use is what's on it, which may not be what's asked for.
    private static func switched(_ name: String, manager: String, inUse: String?, pin: (version: String, source: String)?,
                                 versions: String?, prefix: String, fileManager: FileManager) -> Toolchain.Tool? {
        guard inUse != nil || pin != nil else { return nil }
        // Only a version can be looked for: an alias (`lts/*`, `node`) is taken as there.
        let installed = pin.map { pin in
            !looksLikeVersion(pin.version) || versions.map { installedVersion(pin.version, in: $0, prefix: prefix, fileManager: fileManager) != nil } ?? true
        } ?? true
        return Toolchain.Tool(name: name, version: inUse ?? pin?.version ?? "", requested: pin?.version, source: pin?.source,
                              installed: installed, manager: manager)
    }

    /// asdf: for each tool, the nearest `.tool-versions` that names it, from here up to the home folder's.
    private static func asdf(environment: [String: String], home: String, files: VersionFiles,
                             fileManager: FileManager) -> [Toolchain.Tool] {
        var found: [String: (version: String, source: String)] = [:]
        var sources = files.all(".tool-versions")
        let global = home + "/.tool-versions"
        if !sources.contains(where: { $0.path == global }), let text = files.read(global) { sources.append((global, text)) }
        for (path, text) in sources {
            for line in text.split(whereSeparator: \.isNewline) {
                let words = line.split(separator: "#", maxSplits: 1).first?.split(whereSeparator: \.isWhitespace) ?? []
                guard words.count >= 2, found[String(words[0])] == nil else { continue }
                found[String(words[0])] = (String(words[1]), path)
            }
        }
        let installs = (environment["ASDF_DATA_DIR"] ?? home + "/.asdf") + "/installs"
        return found.map { plugin, pin in
            let name = ["nodejs": "node", "golang": "go"][plugin] ?? plugin
            let folder = installs + "/" + plugin + "/" + pin.version
            let installed = pin.version == "system" || fileManager.fileExists(atPath: folder)
            return Toolchain.Tool(name: name, version: pin.version, requested: pin.version, source: pin.source,
                                  installed: installed, installPath: installed ? folder : nil, manager: "asdf")
        }
    }

    // MARK: Conda

    /// The active conda environment, unless it's `base`, which conda activates everywhere by default.
    /// Its Python's version comes from the package record in `conda-meta`.
    public static func condaEnvironment(environment: [String: String], fileManager: FileManager = .default)
        -> Toolchain.PythonEnvironment? {
        guard let prefix = environment["CONDA_PREFIX"], !prefix.isEmpty else { return nil }
        let name = environment["CONDA_DEFAULT_ENV"] ?? (prefix as NSString).lastPathComponent
        guard name != "base" else { return nil }
        let records = (try? fileManager.contentsOfDirectory(atPath: prefix + "/conda-meta")) ?? []
        // python-3.12.4-h99e199e_0_cpython.json
        let version = records.lazy.compactMap { record -> String? in
            guard record.hasPrefix("python-"), record.hasSuffix(".json") else { return nil }
            let version = record.dropFirst("python-".count).prefix { $0 != "-" }
            return version.first?.isNumber == true ? String(version) : nil
        }.first
        return Toolchain.PythonEnvironment(path: prefix, version: version, name: name, kind: .conda)
    }

    // MARK: Reading versions

    /// The first version a version file names: its first word, skipping blank lines and comments.
    static func firstVersion(in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let word = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first?
                .split(whereSeparator: \.isWhitespace).first
            if let word, !word.isEmpty { return String(word) }
        }
        return nil
    }

    /// Whether a requested version is a number (`20`, `3.12.1`, `v18.2`) rather than an alias.
    static func looksLikeVersion(_ text: String) -> Bool {
        strip(text).first?.isNumber == true
    }

    private static func strip(_ text: String, _ prefix: String = "v") -> String {
        text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }

    /// The version in a path, in the component after `marker` (`…/versions/node/v20.11.0/bin` → `20.11.0`).
    private static func version(in path: String, after marker: String) -> String? {
        guard let range = path.range(of: marker, options: .backwards) else { return nil }
        let component = path[range.upperBound...].prefix { $0 != "/" }
        return component.isEmpty ? nil : strip(String(component))
    }

    /// The installed version a request resolves to: the folder named for it, or the newest whose
    /// version starts with it (`3.12` → `3.12.4`), as the managers resolve a partial version.
    static func installedVersion(_ requested: String, in folder: String, prefix: String = "",
                                 fileManager: FileManager = .default) -> String? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder) else { return nil }
        let versions = names.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        if versions.contains(requested) { return requested }
        return versions.filter { $0.hasPrefix(requested + ".") }
            .max { $0.compare($1, options: .numeric) == .orderedAscending }
    }
}

/// Version files from a folder up to the root, read once each.
private struct VersionFiles {
    let directory: String
    let fileManager: FileManager

    func read(_ path: String) -> String? {
        guard let data = fileManager.contents(atPath: path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Every file with this name from the folder up, nearest first.
    func all(_ name: String) -> [(path: String, text: String)] {
        var found: [(String, String)] = []
        var folder = directory.isEmpty ? "/" : directory
        while true {
            let path = (folder as NSString).appendingPathComponent(name)
            if let text = read(path) { found.append((path, text)) }
            guard folder != "/" else { return found }
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    func nearest(_ name: String) -> (path: String, text: String)? {
        var folder = directory.isEmpty ? "/" : directory
        while true {
            let path = (folder as NSString).appendingPathComponent(name)
            if let text = read(path) { return (path, text) }
            guard folder != "/" else { return nil }
            folder = (folder as NSString).deletingLastPathComponent
        }
    }
}
