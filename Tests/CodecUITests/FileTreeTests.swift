import Testing
import AppKit
import CodecCore
@testable import CodecUI

private let hasGit = FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
    || FileManager.default.fileExists(atPath: "/Applications/Xcode.app")

private func git(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "init.defaultBranch=main"] + arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
}

/// A repository with a committed file that's since changed, an untracked one and an ignored one.
private func makeProject(in env: TestEnvironment) throws -> URL {
    let project = env.directory.appendingPathComponent("project", isDirectory: true)
    let files = ["README.md": "# Hi\n", "Sources/App/main.swift": "print(1)\n", "Sources/Lib.swift": "\n",
                 ".gitignore": "build.log\n", ".env": "SECRET=1\n"]
    for (path, contents) in files {
        let url = project.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    try git(["init", "-q"], in: project)
    try git(["add", "."], in: project)
    try git(["commit", "-qm", "first"], in: project)
    try "print(2)\n".write(to: project.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)
    try "new\n".write(to: project.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
    try "log\n".write(to: project.appendingPathComponent("build.log"), atomically: true, encoding: .utf8)
    return project
}

@Suite("File tree", .serialized, .timeLimit(.minutes(1)), .enabled(if: hasGit))
@MainActor
struct FileTreeModelTests {
    @Test func showsTheRepositoryAroundTheDirectory() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let project = try makeProject(in: env)
        let tree = FileTreeModel(defaults: env.preferences.stateDefaults)
        tree.follow(project.appendingPathComponent("Sources/App").path)
        let root = try #require(tree.root)
        #expect(root.url.path == project.path)
        #expect(tree.isRepository)
        #expect(tree.currentDirectory?.path == project.appendingPathComponent("Sources/App").path)
        #expect(tree.children(of: root).map(\.name) == ["Sources", "build.log", "new.txt", "README.md"])
        tree.showHidden = true
        #expect(tree.children(of: root).map(\.name) == ["Sources", ".env", ".gitignore", "build.log", "new.txt", "README.md"])

        let plain = env.directory.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        tree.follow(plain.path)
        #expect(tree.root?.url.path == plain.path)
        #expect(!tree.isRepository)
    }

    @Test func showsWhatGitSays() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let project = try makeProject(in: env)
        let tree = FileTreeModel(defaults: env.preferences.stateDefaults)
        tree.follow(project.path)
        tree.isActive = true
        defer { tree.isActive = false }
        #expect(await waitUntil { tree.status.kind(of: "Sources/App/main.swift") == .modified })
        #expect(tree.status.kind(of: "new.txt") == .untracked)
        #expect(tree.status.kind(of: "build.log") == .ignored)
        #expect(tree.status.containsChanges("Sources"))
    }

    @Test func reloadsWhenTheDiskChanges() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let project = try makeProject(in: env)
        let tree = FileTreeModel(defaults: env.preferences.stateDefaults)
        tree.follow(project.path)
        tree.isActive = true
        defer { tree.isActive = false }
        let root = try #require(tree.root)
        let sources = try #require(tree.children(of: root).first { $0.name == "Sources" })
        _ = tree.children(of: sources)
        var reloaded: [Set<FileNode>?] = []
        tree.onReload = { reloaded.append($0) }

        try "\n".write(to: project.appendingPathComponent("Sources/Added.swift"), atomically: true, encoding: .utf8)
        #expect(await waitUntil { tree.children(of: sources).contains { $0.name == "Added.swift" } })
        #expect(reloaded.contains { $0?.contains(sources) == true })
        #expect(await waitUntil { tree.status.kind(of: "Sources/Added.swift") == .untracked })
    }

    @Test func searchesTheWholeTree() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let project = try makeProject(in: env)
        let tree = FileTreeModel(defaults: env.preferences.stateDefaults)
        tree.follow(project.path)
        tree.query = "lib"
        await tree.searchSettled()
        #expect(tree.results.first?.relativePath == "Sources/Lib.swift")
        // Git's list: ignored files aren't searched.
        tree.query = "build"
        #expect(tree.results.isEmpty)
        tree.query = ""
        #expect(tree.results.isEmpty)
    }
}

@Suite("File tree in a window", .serialized, .timeLimit(.minutes(1)), .enabled(if: hasGit))
@MainActor
struct FileTreeWindowTests {
    private func makeWindow(_ env: TestEnvironment, directory: URL) -> TerminalWindowController {
        let controller = TerminalWindowController(directory: directory.path, environment: env.environment)
        controller.window?.setContentSize(NSSize(width: 1000, height: 600))
        controller.window?.layoutIfNeeded()
        return controller
    }

    private func titles(_ items: [NSMenuItem]) -> [String] {
        items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    private func perform(_ title: String, in items: [NSMenuItem]) {
        let menu = NSMenu()
        items.forEach(menu.addItem)
        menu.perform(title)
    }

    @Test func togglesAndRevealsTheCurrentDirectory() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let project = try makeProject(in: env)
        let controller = makeWindow(env, directory: project.appendingPathComponent("Sources/App"))
        defer { controller.window?.close() }
        #expect(!controller.model.fileTreeVisible)
        #expect(controller.sidebar.isHidden)

        controller.toggleFileTree(nil)
        controller.window?.layoutIfNeeded()
        #expect(controller.model.fileTreeVisible)
        #expect(controller.sidebar.frame.width == FileTreeSidebar.defaultWidth)
        #expect(controller.fileTree.isActive)
        let outline = controller.sidebar.outline
        let names = (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? FileNode)?.name }
        #expect(names == ["Sources", "App", "main.swift", "Lib.swift", "build.log", "new.txt", "README.md"])
        let theme = env.preferences.theme
        func icon(_ name: String) -> NSImage? {
            let row = (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? FileNode)?.name == name } ?? -1
            return (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.imageView?.image
        }
        #expect(icon("main.swift") === FileIcons.image(for: .swift, theme: theme))
        #expect(icon("README.md") === FileIcons.image(for: .readme, theme: theme))
        #expect(icon("Sources") === FileIcons.image(for: .source, state: .open, theme: theme))
        // The current directory takes the accent.
        #expect(icon("App") === FileIcons.image(for: .plain, state: .current, theme: theme))

        controller.toggleFileTree(nil)
        controller.window?.layoutIfNeeded()
        #expect(controller.sidebar.frame.width == 0)
        #expect(!controller.fileTree.isActive)
        #expect(controller.paletteCommands().contains { $0.id == "file-tree" && $0.title == "Show File Tree" })
    }

    @Test func offersActionsForFilesAndFolders() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let project = try makeProject(in: env)
        let controller = makeWindow(env, directory: project)
        defer { controller.window?.close() }
        controller.setFileTreeVisible(true)
        let root = try #require(controller.fileTree.root)
        let children = controller.fileTree.children(of: root)
        let folder = try #require(children.first { $0.name == "Sources" })
        let file = try #require(children.first { $0.name == "README.md" })
        #expect(titles(controller.sidebar.contextMenuItems(for: [folder])) == [
            "Change Directory Here", "Open in New Tab", "-", "Insert Path", "Copy Path", "Copy Relative Path", "-", "Reveal in Finder",
        ])
        #expect(titles(controller.sidebar.contextMenuItems(for: [file])) == [
            "Open", "Open in Default App", "Open in Terminal Editor", "-", "Insert Path", "Copy Path", "Copy Relative Path", "-", "Reveal in Finder",
        ])
        #expect(titles(controller.sidebar.contextMenuItems(for: [file, folder])).contains("Insert Paths"))

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer { pasteboard.clearContents(); if let saved { pasteboard.setString(saved, forType: .string) } }
        perform("Copy Relative Path", in: controller.sidebar.contextMenuItems(for: [file]))
        #expect(pasteboard.string(forType: .string) == "README.md")
    }

    @Test func newTabsOpenInTheFolder() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let project = try makeProject(in: env)
        let controller = makeWindow(env, directory: project)
        defer { controller.window?.close() }
        controller.setFileTreeVisible(true)
        let root = try #require(controller.fileTree.root)
        let folder = try #require(controller.fileTree.children(of: root).first { $0.name == "Sources" })
        perform("Open in New Tab", in: controller.sidebar.contextMenuItems(for: [folder]))
        #expect(controller.model.tabs.count == 2)
        #expect(controller.model.selected?.focused.session.directory == folder.url.path)
    }
}

@Suite("Paths into the terminal", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct InsertPathsTests {
    @Test func typesQuotedPathsRelativeToTheShell() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        env.preferences.shellPath = "/bin/cat"
        let pane = env.makePane(host: FakeHost())
        defer { pane.shutDown() }
        pane.insertPaths([env.directory.appendingPathComponent("My File.txt"), URL(fileURLWithPath: "/etc/hosts")])
        #expect(await waitUntil { pane.terminal.visibleRowsText(0..<3).joined().contains("'My File.txt' /etc/hosts") })
    }

    @Test func droppedFilesArePassedOn() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let pane = env.makePane(host: FakeHost())
        defer { pane.shutDown() }
        #expect(pane.terminal.registeredDraggedTypes.contains(.fileURL))
        #expect(pane.terminal.onDropFiles != nil)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
    func runsACommandInPlaceOfWhatWasTyped() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let config = env.directory.appendingPathComponent("zdotdir")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "PS1='%# '\n".write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        setenv("ZDOTDIR", config.path, 1)
        let pane = env.makePane(host: FakeHost())
        unsetenv("ZDOTDIR")
        defer { pane.shutDown() }
        let target = env.directory.appendingPathComponent("with space", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        #expect(await waitUntil { pane.isAtCommandLine })
        pane.terminal.send(txt: "half-typed words")
        #expect(await waitUntil { pane.terminal.visibleRowsText(0..<5).joined().contains("half-typed") })
        #expect(pane.runAtPrompt("cd " + ShellQuoting.quote(target.path)))
        #expect(await waitUntil { pane.session.directory == target.path })
        #expect(pane.session.lastCommand?.command == "cd " + ShellQuoting.quote(target.path))
    }
}
