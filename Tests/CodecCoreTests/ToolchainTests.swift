import Testing
import Foundation
@testable import CodecCore

@Suite("Toolchain")
struct ToolchainTests {
    static let miseJSON = """
        {
          "node": [{
            "version": "22.23.4", "requested_version": "22",
            "install_path": "/Users/me/.local/share/mise/installs/node/22.23.4",
            "source": {"type": "mise.toml", "path": "/Users/me/code/app/mise.toml"},
            "installed": false, "active": false
          }],
          "ruby": [
            {"version": "4.0.2", "requested_version": "4.0.2",
             "source": {"type": "mise.toml", "path": "/Users/me/.config/mise/config.toml"}, "installed": true},
            {"version": "3.3.6", "installed": true}
          ]
        }
        """

    @Test func readsUvAndVenvConfigurations() {
        let uv = Toolchain.PythonEnvironment(path: "/code/demo/.venv", configuration: """
            home = /opt/homebrew/opt/python@3.14/bin
            implementation = CPython
            uv = 0.13.6
            version_info = 3.14.6
            include-system-site-packages = false
            prompt = demo-app
            """)
        #expect(uv.version == "3.14.6")
        #expect(uv.name == "demo-app")
        #expect(uv.label == "demo-app")
        #expect(uv.project == "/code/demo")

        let venv = Toolchain.PythonEnvironment(path: "/code/other/.venv", configuration: "home = /usr/bin\nversion = 3.12.1\n")
        #expect(venv.version == "3.12.1")
        // Without a name of its own, it's called after its project.
        #expect(venv.label == "other")
        #expect(Toolchain.PythonEnvironment(path: "/envs/science", configuration: "").label == "science")
    }

    @Test func readsMisesToolsInOrder() throws {
        let tools = try #require(Toolchain.miseTools(fromJSON: Self.miseJSON))
        #expect(tools.map(\.name) == ["node", "ruby"])
        #expect(tools[0] == Toolchain.Tool(name: "node", version: "22.23.4", requested: "22", source: "/Users/me/code/app/mise.toml",
                                           installed: false, installPath: "/Users/me/.local/share/mise/installs/node/22.23.4"))
        // Several versions: the first is the one in use.
        #expect(tools[1].version == "4.0.2")
        #expect(Toolchain.miseTools(fromJSON: "{}") == [])
        #expect(Toolchain.miseTools(fromJSON: "") == nil)
        #expect(Toolchain.miseTools(fromJSON: "mise ERROR oops") == nil)
    }

    @Test func tellsGlobalToolsFromAProjectsOwn() throws {
        let tools = try #require(Toolchain.miseTools(fromJSON: Self.miseJSON))
        #expect(!tools[0].isGlobal(home: "/Users/me"))
        #expect(tools[1].isGlobal(home: "/Users/me"))
        #expect(Toolchain.Tool(name: "go", version: "1", source: "/Users/me/.tool-versions").isGlobal(home: "/Users/me"))
    }

    @Test func summarizesForLabelsAndTheModel() throws {
        var toolchain = Toolchain(tools: try #require(Toolchain.miseTools(fromJSON: Self.miseJSON)))
        #expect(toolchain.summary == "node 22.23.4 (not installed) · ruby 4.0.2")
        #expect(toolchain.missing.map(\.name) == ["node"])
        toolchain.python = .init(path: "/code/demo/.venv", version: "3.14.6", name: "demo")
        toolchain.tools.append(.init(name: "python", version: "3.13.1"))
        // The environment's Python comes first on the PATH, so mise's isn't mentioned.
        #expect(toolchain.summary == "python 3.14.6 (demo) · node 22.23.4 (not installed) · ruby 4.0.2")
        #expect(Toolchain().isEmpty)
        #expect(Toolchain().summary == "")
    }

    @Test func parsesTheShellsReport() throws {
        func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
        let event = IntegrationEvent(payload: "toolchain;\(b64("/code/demo/.venv"));1;;\(b64(Self.miseJSON))")
        guard case .toolchain(let report) = event else {
            Issue.record("Not a toolchain report: \(String(describing: event))")
            return
        }
        #expect(report.virtualEnv == "/code/demo/.venv")
        #expect(report.activatedByCodec)
        #expect(report.pending == nil)
        let toolchain = report.toolchain { path, codec in .init(path: path, version: "3.14.6", activatedByCodec: codec) }
        #expect(toolchain.python == .init(path: "/code/demo/.venv", version: "3.14.6", activatedByCodec: true))
        #expect(toolchain.tools.count == 2)

        let pending = IntegrationEvent(payload: "toolchain;;0;\(b64("/code/x/.venv"));")
        #expect(pending == .toolchain(ToolchainReport(pending: "/code/x/.venv")))
        #expect(IntegrationEvent(payload: "toolchain;;0;;") == .toolchain(ToolchainReport()))
        #expect(IntegrationEvent(payload: "toolchain;;2;;") == nil)
        #expect(IntegrationEvent(payload: "toolchain;;0;") == nil)
        #expect(IntegrationEvent(payload: "toolchain;!!;0;;") == nil)
    }

    @Test func readsAVenvFromDisk() throws {
        let temp = try TemporaryDirectory()
        try temp.file("app/.venv/pyvenv.cfg", "version_info = 3.13.2\nprompt = app\n")
        let path = temp.url.appendingPathComponent("app/.venv").path
        #expect(Toolchain.PythonEnvironment.read(at: path, activatedByCodec: true)
                == .init(path: path, version: "3.13.2", name: "app", activatedByCodec: true))
        #expect(Toolchain.PythonEnvironment.read(at: temp.url.path) == nil)
        // A venv whose configuration is gone is still reported, with what's known.
        #expect(ToolchainReport(virtualEnv: "/gone/.venv").toolchain().python == .init(path: "/gone/.venv"))
    }

    @Test func remembersAnswersAboutVirtualEnvironments() throws {
        let temp = try TemporaryDirectory()
        let decisions = VenvDecisions(file: temp.url.appendingPathComponent("state/venv-decisions"))
        #expect(decisions.isEmpty)
        #expect(decisions.decision(for: "/a/.venv") == nil)
        try decisions.set(.allow, for: "/a/.venv")
        try decisions.set(.deny, for: "/b b/.venv")
        try decisions.set(.deny, for: "/a/.venv")
        #expect(decisions.decision(for: "/a/.venv") == .deny)
        #expect(decisions.decision(for: "/b b/.venv") == .deny)
        // One line per environment, as the shell reads it.
        #expect(try String(contentsOf: decisions.file, encoding: .utf8) == "deny\t/b b/.venv\ndeny\t/a/.venv\n")
        try decisions.clear()
        #expect(decisions.isEmpty)
        try decisions.clear()
    }

    @Test func listsChangesAndForgetsAnswersOneByOne() throws {
        let temp = try TemporaryDirectory()
        try temp.file("here/.venv/pyvenv.cfg", "version_info = 3.13.2\n")
        try temp.directory("emptied")
        let here = temp.url.path + "/here/.venv", emptied = temp.url.path + "/emptied/.venv", gone = temp.url.path + "/gone/.venv"
        let decisions = VenvDecisions(file: temp.url.appendingPathComponent("venv-decisions"))
        try decisions.set(.allow, for: here)
        try decisions.set(.deny, for: emptied)
        try decisions.set(.allow, for: gone)
        try decisions.set(.deny, for: here)
        #expect(decisions.entries == [.init(path: emptied, decision: .deny), .init(path: gone, decision: .allow),
                                      .init(path: here, decision: .deny)])
        #expect(decisions.entries.map { $0.status() } == [.environmentMissing, .projectMissing, .present])
        #expect(decisions.entries[2].project == temp.url.path + "/here")

        try decisions.remove(emptied)
        #expect(decisions.entries.map(\.path) == [gone, here])
        #expect(try decisions.removeMissing() == 1)
        #expect(decisions.entries.map(\.path) == [here])
        #expect(try decisions.removeMissing() == 0)
        try decisions.remove(here)
        #expect(decisions.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: decisions.file.path))
    }

    @Test func remembersWhatEachCommandRanWith() {
        var timeline = CommandTimeline()
        let toolchain = Toolchain(tools: [.init(name: "ruby", version: "4.0.2")])
        timeline.begin(command: "rake", directory: "/code", started: Date(), block: nil, toolchain: toolchain)
        timeline.begin(command: "ls", directory: "/", started: Date(), block: nil, toolchain: Toolchain())
        #expect(timeline.entries[0].toolchain == toolchain)
        #expect(timeline.entries[1].toolchain == nil)

        var entry = timeline.entries[0]
        entry.exitCode = 1
        let report = FailureReport(entry: entry, output: "boom")
        #expect(report?.prompt.contains("Folder: /code\nTools: ruby 4.0.2\nExit status: 1") == true)
    }
}
