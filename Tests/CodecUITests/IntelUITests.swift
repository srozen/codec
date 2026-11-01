import Testing
import Foundation
import AppKit
import CodecCore
@testable import CodecUI

@Suite("Intel library and sidebar", .serialized)
@MainActor
struct IntelUITests {
    /// A repository with one project script, and a personal folder with a document in a subfolder.
    private func makeFolders(_ env: TestEnvironment) throws -> (repo: URL, personal: URL) {
        let repo = env.directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        let project = repo.appendingPathComponent(".codec/intel")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try IntelItem.script(title: "Run the tests", description: "All of them", command: "make test JOBS={{jobs}}")
            .fileText.write(to: project.appendingPathComponent("tests.md"), atomically: true, encoding: .utf8)
        let personal = env.environment.intelFolder
        try FileManager.default.createDirectory(at: personal.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try "# Setting up a Mac\n\n```sh\nbrew bundle\n```\n".write(to: personal.appendingPathComponent("notes/mac-setup.md"),
                                                                atomically: true, encoding: .utf8)
        return (repo, personal)
    }

    @Test func readsTheProjectsAndTheUsersIntel() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let (repo, _) = try makeFolders(env)
        let library = IntelLibrary(personalFolder: env.environment.intelFolder)
        library.follow(repo.appendingPathComponent("src").path)
        library.reload()
        #expect(library.projectName == "repo")
        #expect(library.project.map(\.item.title) == ["Run the tests"])
        #expect(library.personal.map(\.item.title) == ["mac setup"])
        #expect(library.personal.first?.folder == "notes")
        #expect(library.personal.first?.item.kind == .doc)
        #expect(library.entries(matching: "brew").map(\.item.title) == ["mac setup"])
        #expect(library.entries(matching: "JOBS").map(\.item.title) == ["Run the tests"])

        // Outside a repository there's no project Intel.
        library.follow(env.directory.path)
        library.reload()
        #expect(library.projectRoot == nil)
        #expect(library.project.isEmpty)
    }

    @Test func savesEditsMovesAndTrashes() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let (repo, personal) = try makeFolders(env)
        let library = IntelLibrary(personalFolder: personal)
        library.follow(repo.path)

        let url = try library.save(.script(title: "Deploy", command: "./deploy {{env}}"), to: .personal)
        #expect(url.lastPathComponent == "deploy.md")
        // A second one with the same title doesn't replace the first.
        let second = try library.save(.script(title: "Deploy", command: "./deploy2"), to: .personal)
        #expect(second.lastPathComponent == "deploy-2.md")

        var entry = try #require(library.entry(at: url))
        entry.item.description = "Ships it"
        try library.save(entry.item, to: .personal, replacing: entry)
        #expect(library.entry(at: url)?.item.description == "Ships it")

        let moved = try library.save(entry.item, to: .project, replacing: library.entry(at: url))
        #expect(moved.path.hasPrefix(repo.appendingPathComponent(".codec/intel").standardizedFileURL.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(library.project.map(\.item.title).sorted() == ["Deploy", "Run the tests"])

        try library.trash(try #require(library.entry(at: second)))
        #expect(library.entry(at: second) == nil)
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test func keepsItemsInFolders() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let (repo, personal) = try makeFolders(env)
        let library = IntelLibrary(personalFolder: personal)
        library.follow(repo.path)
        library.reload()
        #expect(library.folders(in: .personal).map(\.path) == ["notes"])
        #expect(library.folders(in: .project).isEmpty)

        // New folders get a name of their own, at the top or inside another; empty ones are listed too.
        let first = try library.createFolder(in: .personal)
        let second = try library.createFolder(in: .personal)
        #expect((first.path, second.path) == ("New Folder", "New Folder 2"))
        let inner = try library.createFolder(named: "macOS", in: .personal, parent: "notes")
        #expect(inner.path == "notes/macOS" && inner.depth == 2 && inner.parent == "notes")
        #expect(library.folders(in: .personal).map(\.path) == ["New Folder", "New Folder 2", "notes", "notes/macOS"])
        #expect(throws: IntelLibrary.Failure.self) { try library.createFolder(named: "a/b", in: .personal) }
        #expect(throws: IntelLibrary.Failure.self) { try library.createFolder(named: ".hidden", in: .personal) }

        let renamed = try library.rename(first, to: "Deploys")
        #expect(renamed.path == "Deploys")
        #expect(throws: IntelLibrary.Failure.self) { try library.rename(second, to: "notes") }
        // A change of case is fine.
        #expect(try library.rename(renamed, to: "deploys").path == "deploys")

        // Saving into a folder, then moving the item out of it and into another.
        let url = try library.save(.script(title: "Ship", command: "./ship"), to: .personal, folder: "deploys")
        #expect(library.entry(at: url)?.folder == "deploys")
        let entry = try #require(library.entry(at: url))
        let moved = try library.move(entry, to: .personal, folder: "notes/macOS")
        #expect(library.entry(at: moved)?.folder == "notes/macOS")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // Editing keeps it where it is.
        var edited = try #require(library.entry(at: moved))
        edited.item.description = "Off it goes"
        #expect(try library.save(edited.item, to: .personal, replacing: edited) == moved)

        // Folders move with what's in them, but not into themselves.
        let notes = IntelLibrary.Folder(source: .personal, path: "notes")
        #expect(throws: IntelLibrary.Failure.self) { try library.move(notes, to: .personal, parent: "notes/macOS") }
        let movedNotes = try library.move(notes, to: .personal, parent: "deploys")
        #expect(movedNotes.path == "deploys/notes")
        #expect(library.personal.first { $0.item.title == "Ship" }?.folder == "deploys/notes/macOS")
        // And to the project, folder and all.
        let shared = try library.move(movedNotes, to: .project, parent: "")
        #expect(shared.path == "notes")
        #expect(library.project.first { $0.item.title == "Ship" }?.folder == "notes/macOS")

        try library.trash(shared)
        #expect(library.folders(in: .project).isEmpty)
        #expect(library.project.map(\.item.title) == ["Run the tests"])
    }

    @Test func showsFoldersAsATree() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let (repo, personal) = try makeFolders(env)
        let library = IntelLibrary(personalFolder: personal)
        library.follow(repo.path)
        try library.createFolder(named: "macOS", in: .personal, parent: "notes")
        try library.save(.script(title: "Defaults", command: "defaults read"), to: .personal, folder: "notes/macOS")
        try library.save(.script(title: "Brew", command: "brew update"), to: .personal)
        try library.createFolder(named: "empty", in: .personal)
        let defaults = try #require(UserDefaults(suiteName: "intel-tree-\(UUID())"))
        let sidebar = IntelSidebar(library: library, theme: .daylight, defaults: defaults)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 500)
        func outline() -> [String] {
            sidebar.rows.map { row in
                switch row {
                case .section(_, let title): "# \(title)"
                case .folder(let folder, let count): String(repeating: "  ", count: folder.depth - 1) + "\(folder.name)/ \(count)"
                case .entry(let entry): String(repeating: "  ", count: entry.folder.split(separator: "/").count) + entry.item.title
                }
            }
        }
        // Folders first, each followed by what's in it.
        #expect(outline() == [
            "# Project · repo", "Run the tests",
            "# Personal", "empty/ 0", "notes/ 2", "  macOS/ 1", "    Defaults", "  mac setup", "Brew",
        ])

        // Closing a folder hides what's in it, and is remembered.
        let notes = try #require(sidebar.rows.compactMap(\.folder).first { $0.path == "notes" })
        sidebar.toggle(notes)
        #expect(outline().suffix(3) == ["empty/ 0", "notes/ 2", "Brew"])
        #expect(defaults.stringArray(forKey: IntelSidebar.collapsedKey) == [notes.id])
        let again = IntelSidebar(library: library, theme: .daylight, defaults: defaults)
        #expect(!again.isExpanded(notes))

        // Filtering opens the folders that lead to a match, and leaves the others out.
        sidebar.searchField.stringValue = "defaults"
        sidebar.reload()
        #expect(outline() == ["# Personal", "notes/ 1", "  macOS/ 1", "    Defaults"])
        sidebar.searchField.stringValue = ""
        sidebar.toggle(notes)

        // Dropping on an item goes into the folder it's in; above a folder, into the one holding it.
        let row = { (title: String) in try #require(sidebar.rows.firstIndex { $0.entry?.item.title == title || $0.folder?.name == title }) }
        let target = { (row: Int?) in row.map { sidebar.rows[$0].id } }
        #expect(target(sidebar.dropTarget(row: try row("Defaults"), operation: .on)) == "folder:personal:notes/macOS")
        #expect(target(sidebar.dropTarget(row: try row("macOS"), operation: .above)) == "folder:personal:notes")
        #expect(target(sidebar.dropTarget(row: try row("Brew"), operation: .on)) == "section:personal")
        #expect(target(sidebar.dropTarget(row: try row("empty"), operation: .on)) == "folder:personal:empty")
        // Below the last item.
        #expect(target(sidebar.dropTarget(row: sidebar.rows.count, operation: .above)) == "section:personal")

        let brew = try #require(sidebar.rows[try row("Brew")].entry)
        try sidebar.move(.entry(brew), to: .personal, folder: "empty")
        #expect(outline().prefix(5).suffix(3) == ["# Personal", "empty/ 1", "  Brew"])

        // Folders' and sections' menus.
        func titles(_ items: [NSMenuItem]) -> [String] { items.map { $0.isSeparatorItem ? "-" : $0.title } }
        let macOS = try #require(sidebar.rows.compactMap(\.folder).first { $0.name == "macOS" })
        #expect(titles(sidebar.contextMenuItems(for: macOS)) == [
            "New Script Here…", "New Document Here…", "New Folder", "-", "Rename", "Move to Project (repo)",
            "Move Out of “notes”", "-", "Reveal in Finder", "Move to Trash",
        ])
        #expect(titles(sidebar.contextMenuItems(forTopOf: .project)) == ["New Script…", "New Document…", "New Folder", "-", "Reveal in Finder"])
    }

    @Test func namesANewFolderInPlace() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let (repo, _) = try makeFolders(env)
        let controller = makeWindow(env, directory: repo)
        defer {
            controller.model.tabs.flatMap(\.panes).forEach { $0.shutDown() }
            controller.window?.close()
        }
        controller.toggleIntel(nil)
        let sidebar = controller.intelSidebar!
        sidebar.newFolder(in: .project, parent: "")
        let folder = try #require(sidebar.renaming)
        #expect(folder.path == "New Folder" && sidebar.selectedFolder == folder)
        let row = try #require(sidebar.rows.firstIndex { $0.folder == folder })
        let cell = try #require(sidebar.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? IntelFolderCell)
        #expect(cell.isEditing)
        // The library changing meanwhile doesn't end the editing.
        sidebar.reload()
        #expect(cell.isEditing)

        cell.name.stringValue = "Release"
        cell.finishEditing(cell.name.stringValue)
        #expect(sidebar.renaming == nil)
        #expect(controller.intel.folders(in: .project).map(\.path) == ["Release"])
        #expect(sidebar.selectedFolder?.path == "Release")

        // New Script Here starts the form.
        let menu = NSMenu()
        sidebar.contextMenuItems(for: try #require(sidebar.selectedFolder)).forEach(menu.addItem)
        menu.perform("New Script Here…")
        #expect(controller.isShowingOverlayForm)
    }

    private func makeWindow(_ env: TestEnvironment, directory: URL) -> TerminalWindowController {
        let controller = TerminalWindowController(directory: directory.path, environment: env.environment)
        controller.window?.setContentSize(NSSize(width: 1100, height: 600))
        controller.window?.layoutIfNeeded()
        return controller
    }

    @Test func switchesBetweenFilesAndIntel() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let (repo, _) = try makeFolders(env)
        let controller = makeWindow(env, directory: repo)
        defer {
            controller.model.tabs.flatMap(\.panes).forEach { $0.shutDown() }
            controller.window?.close()
        }
        let window = try #require(controller.window)
        let pane = try #require(controller.model.selected?.focused)

        controller.toggleIntel(nil)
        window.layoutIfNeeded()
        #expect(controller.model.fileTreeVisible && controller.model.navigatorTab == .intel)
        #expect(!controller.intelSidebar.isHidden && controller.sidebar.isHidden)
        #expect(controller.intelSidebar.frame.width == FileTreeSidebar.defaultWidth)
        #expect(controller.intel.isActive && !controller.fileTree.isActive)
        let titles = controller.intelSidebar.rows.compactMap(\.entry).map(\.item.title)
        #expect(titles == ["Run the tests", "mac setup"])
        #expect(window.firstResponder === controller.intelSidebar.table)

        // ⇧⌘E switches to the files; again, it hides the sidebar and gives the terminal the keyboard.
        controller.toggleFileTree(nil)
        #expect(controller.model.navigatorTab == .files && !controller.sidebar.isHidden && controller.intelSidebar.isHidden)
        #expect(window.firstResponder === controller.sidebar.outline)
        controller.toggleFileTree(nil)
        window.layoutIfNeeded()
        #expect(!controller.model.fileTreeVisible && controller.sidebar.frame.width == 0)
        #expect(window.firstResponder === pane.terminal)

        // ⇧⌘I from the Intel tab hides it.
        controller.toggleIntel(nil)
        controller.toggleIntel(nil)
        #expect(!controller.model.fileTreeVisible)
        #expect(window.firstResponder === pane.terminal)
        #expect(controller.paletteCommands().contains { $0.title == "Intel: Run the tests" })
        #expect(controller.paletteCommands().contains { $0.id == "intel" && $0.title == "Show Intel" })
    }

    @Test func offersActionsForScriptsAndDocuments() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let (repo, _) = try makeFolders(env)
        let controller = makeWindow(env, directory: repo)
        defer {
            controller.model.tabs.flatMap(\.panes).forEach { $0.shutDown() }
            controller.window?.close()
        }
        controller.toggleIntel(nil)
        let sidebar = controller.intelSidebar!
        let entries = sidebar.rows.compactMap(\.entry)
        func titles(_ items: [NSMenuItem]) -> [String] { items.map { $0.isSeparatorItem ? "-" : $0.title } }
        #expect(titles(sidebar.contextMenuItems(for: entries[0])) == [
            "Run…", "Copy Command", "-", "Edit…", "Open File", "Move to Personal", "-", "Reveal in Finder", "Move to Trash",
        ])
        #expect(titles(sidebar.contextMenuItems(for: entries[1])) == [
            "Open", "-", "Edit…", "Open File", "Move to Project (repo)", "Move Out of “notes”", "-", "Reveal in Finder", "Move to Trash",
        ])

        // A script opens its form over the window; Esc closes it.
        sidebar.activate(entries[0])
        #expect(controller.model.paletteOpen && controller.isShowingOverlayForm)
        controller.hideCommandPalette()
        #expect(!controller.isShowingOverlayForm)

        // A document opens in the editor, rendered, with Run on its shell blocks.
        sidebar.activate(entries[1])
        #expect(controller.editor.selected?.url == entries[1].url)
        #expect(controller.editor.selected?.mode == .preview)
    }

    @Test func savesACommandFromTheTimeline() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let (repo, _) = try makeFolders(env)
        let controller = makeWindow(env, directory: repo)
        defer {
            controller.model.tabs.flatMap(\.panes).forEach { $0.shutDown() }
            controller.window?.close()
        }
        let entry = TimelineEntry(id: 1, command: "git push origin main", directory: repo.path, started: Date(), block: nil)
        controller.saveToIntel(entry, from: controller.model.selected?.focused)
        #expect(controller.isShowingOverlayForm)
        #expect(controller.intel.projectName == "repo")
    }
}
