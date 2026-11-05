import Testing
import Foundation
@testable import CodecCore

@Suite("Version managers")
struct VersionManagersTests {
    /// A home folder and a project in it, `~/code/app/src`, where the shell is.
    private struct Home {
        let temp: TemporaryDirectory
        var path: String { temp.url.path + "/home" }
        var project: String { path + "/code/app" }
        var directory: String { project + "/src" }

        init() throws {
            temp = try TemporaryDirectory()
            try temp.directory("home/code/app/src")
        }

        func file(_ path: String, _ contents: String = "") throws {
            try temp.file("home/" + path, contents)
        }

        func folder(_ path: String) throws {
            try temp.directory("home/" + path)
        }

        func tools(_ managers: Set<String>, _ environment: [String: String] = [:]) -> [Toolchain.Tool] {
            VersionManagers.tools(directory: directory, environment: environment, managers: managers, home: path)
        }
    }

    @Test func pyenvTakesTheNearestVersionFileAndResolvesPartialVersions() throws {
        let home = try Home()
        try home.folder(".pyenv/versions/3.12.2")
        try home.folder(".pyenv/versions/3.12.10")
        try home.file("code/app/.python-version", "# pinned\n3.12\n3.11\n")
        #expect(home.tools(["pyenv"]) == [.init(name: "python", version: "3.12.10", requested: "3.12",
                                                 source: home.project + "/.python-version", installed: true,
                                                 installPath: home.path + "/.pyenv/versions/3.12.10", manager: "pyenv")])
        // `pyenv shell` wins over the files.
        let shell = try #require(home.tools(["pyenv"], ["PYENV_VERSION": "3.13.1"]).first)
        #expect(shell.source == "PYENV_VERSION")
        #expect(!shell.isGlobal(home: home.path))
        #expect(!shell.installed)
        #expect(shell.installCommand == "pyenv install 3.13.1")
        // Nothing else known: managers that aren't there are ignored.
        #expect(home.tools(["rbenv", "nodenv"]).isEmpty)
    }

    @Test func pyenvFallsBackOnTheGlobalVersion() throws {
        let home = try Home()
        #expect(home.tools(["pyenv"]).isEmpty)
        try home.file(".pyenv/version", "system\n")
        #expect(home.tools(["pyenv"]) == [.init(name: "python", version: "system", source: home.path + "/.pyenv/version",
                                                 manager: "pyenv")])
        #expect(home.tools(["pyenv"]).first?.isGlobal(home: home.path) == true)
        try home.file("rubies/version", "3.3.0\n")
        let ruby = try #require(home.tools(["rbenv"], ["RBENV_ROOT": home.path + "/rubies"]).first)
        #expect(ruby.name == "ruby")
        #expect(ruby.source == home.path + "/rubies/version")
    }

    @Test func nvmTellsWhenTheNodeInUseIsntTheOneAskedFor() throws {
        let home = try Home()
        try home.folder(".nvm/versions/node/v18.19.0")
        try home.folder(".nvm/versions/node/v20.11.0")
        try home.file("code/app/.nvmrc", "v18\n")
        let node = try #require(home.tools(["nvm"], ["NVM_BIN": home.path + "/.nvm/versions/node/v20.11.0/bin"]).first)
        #expect(node.version == "20.11.0")
        #expect(node.requested == "18")
        #expect(node.installed)
        #expect(!node.matchesRequest)
        #expect(node.needsAttention)
        #expect(node.switchCommand == "nvm use")
        #expect(Toolchain(tools: [node]).summary == "node 20.11.0 (.nvmrc asks for 18)")
        #expect(Toolchain(tools: [node]).shortSummary == "node 20.11.0!")

        try home.file("code/app/.nvmrc", "16.20.2\n")
        let missing = try #require(home.tools(["nvm"], ["NVM_BIN": home.path + "/.nvm/versions/node/v20.11.0/bin"]).first)
        #expect(!missing.installed)
        #expect(missing.installCommand == "nvm install")

        // An alias can't be checked, and with no node on the PATH, what's asked for is what's shown.
        try home.file("code/app/.nvmrc", "lts/*\n")
        #expect(home.tools(["nvm"]).first == .init(name: "node", version: "lts/*", requested: "lts/*",
                                                    source: home.project + "/.nvmrc", manager: "nvm"))
    }

    @Test func fnmFollowsItsShellsLink() throws {
        let home = try Home()
        try home.folder("fnm/node-versions/v22.1.0/installation")
        try home.file("code/app/.node-version", "22\n")
        let link = home.path + "/fnm-shell"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: home.path + "/fnm/node-versions/v22.1.0/installation")
        let node = try #require(home.tools(["fnm"], ["FNM_MULTISHELL_PATH": link, "FNM_DIR": home.path + "/fnm"]).first)
        #expect(node.version == "22.1.0")
        #expect(node.matchesRequest)
        #expect(node.installed)
    }

    @Test func chrubyComparesRubyRootWithRubyVersion() throws {
        let home = try Home()
        try home.folder(".rubies/ruby-3.2.2")
        try home.folder(".rubies/ruby-3.3.0")
        try home.file("code/app/.ruby-version", "ruby-3.2\n")
        let ruby = try #require(home.tools(["chruby"], ["RUBY_ROOT": home.path + "/.rubies/ruby-3.3.0"]).first)
        #expect(ruby.version == "3.3.0")
        #expect(ruby.requested == "3.2")
        #expect(ruby.installed)
        #expect(!ruby.matchesRequest)
        #expect(ruby.switchCommand == "chruby 3.2")
    }

    @Test func asdfTakesEachToolFromTheNearestFileThatNamesIt() throws {
        let home = try Home()
        try home.folder(".asdf/installs/nodejs/20.11.0")
        try home.file("code/app/.tool-versions", "nodejs 20.11.0 # the API's\n")
        try home.file(".tool-versions", "python 3.12.1 3.11.4\nnodejs 18.0.0\n")
        let tools = home.tools(["asdf"])
        #expect(tools.map(\.name) == ["node", "python"])
        #expect(tools[0] == .init(name: "node", version: "20.11.0", requested: "20.11.0", source: home.project + "/.tool-versions",
                                  installed: true, installPath: home.path + "/.asdf/installs/nodejs/20.11.0", manager: "asdf"))
        #expect(tools[1].source == home.path + "/.tool-versions")
        #expect(tools[1].isGlobal(home: home.path))
        #expect(!tools[1].installed)
        #expect(tools[1].installCommand == "asdf install")
    }

    @Test func aDedicatedManagerComesBeforeAsdf() throws {
        let home = try Home()
        try home.file("code/app/.tool-versions", "python 3.11.0\n")
        try home.file("code/app/.python-version", "3.12.0\n")
        #expect(home.tools(["asdf", "pyenv"]).map(\.manager) == ["pyenv"])
    }

    @Test func readsTheActiveCondaEnvironment() throws {
        let temp = try TemporaryDirectory()
        try temp.file("conda/envs/science/conda-meta/numpy-2.0.1-py312_0.json", "{}")
        try temp.file("conda/envs/science/conda-meta/python-3.12.4-h99e199e_0_cpython.json", "{}")
        let prefix = temp.url.path + "/conda/envs/science"
        let environment = VersionManagers.condaEnvironment(environment: ["CONDA_PREFIX": prefix, "CONDA_DEFAULT_ENV": "science"])
        #expect(environment == .init(path: prefix, version: "3.12.4", name: "science", kind: .conda))
        #expect(environment?.label == "science")
        // base is active everywhere, by default: not worth a chip.
        #expect(VersionManagers.condaEnvironment(environment: ["CONDA_PREFIX": temp.url.path + "/conda", "CONDA_DEFAULT_ENV": "base"]) == nil)
        #expect(VersionManagers.condaEnvironment(environment: [:]) == nil)
    }

    @Test func theReportCombinesEverySource() throws {
        let home = try Home()
        try home.file("code/app/.python-version", "3.12.0\n")
        try home.file("code/app/.ruby-version", "3.3.0\n")
        let mise = #"{"ruby":[{"version":"3.4.7","installed":true}]}"#
        var report = ToolchainReport(mise: mise, environment: [
            "PWD": home.directory, "managers": "pyenv rbenv unknown", "CONDA_PREFIX": "/opt/conda/envs/ds", "CONDA_DEFAULT_ENV": "ds",
        ])
        #expect(report.managers == ["pyenv", "rbenv"])
        var toolchain = report.toolchain(home: home.path)
        // mise's Ruby wins over rbenv's.
        #expect(toolchain.tools.map { "\($0.manager) \($0.name)" } == ["pyenv python", "mise ruby"])
        #expect(toolchain.python?.kind == .conda)
        // A virtual environment comes first on the PATH.
        report.virtualEnv = home.project + "/.venv"
        toolchain = report.toolchain(home: home.path) { path, _ in .init(path: path) }
        #expect(toolchain.python == .init(path: home.project + "/.venv"))
    }

    @Test func parsesTheVariablesTheShellSends() {
        func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
        let event = IntegrationEvent(payload: "toolchain;;0;;;\(b64("PWD=/code/app\nmanagers=pyenv nvm\nNVM_BIN=/a=b/bin\n"))")
        #expect(event == .toolchain(ToolchainReport(environment: ["PWD": "/code/app", "managers": "pyenv nvm", "NVM_BIN": "/a=b/bin"])))
        #expect(IntegrationEvent(payload: "toolchain;;0;;;!!") == nil)
        #expect(IntegrationEvent(payload: "toolchain;;0;;;;") == nil)
    }

    @Test func tellsVersionsFromAliases() {
        #expect(Toolchain.Tool(name: "node", version: "22.1.0", requested: "22").matchesRequest)
        #expect(Toolchain.Tool(name: "node", version: "22.1.0", requested: "v22.1").matchesRequest)
        #expect(!Toolchain.Tool(name: "node", version: "22.1.0", requested: "2").matchesRequest)
        #expect(Toolchain.Tool(name: "node", version: "22.1.0", requested: "lts").matchesRequest)
        #expect(Toolchain.Tool(name: "python", version: "3.12.1", requested: "3.12.1").matchesRequest)
        #expect(Toolchain.Tool(name: "python", version: "3.13.0", requested: nil).matchesRequest)
        #expect(Toolchain.Tool(name: "ruby", version: "3.3.0", requested: "3.3.0", installed: false).needsAttention)
    }
}
