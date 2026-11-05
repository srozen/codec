import Testing
import AppKit
import SwiftUI
import CodecCore
import SwiftTerm
@testable import CodecUI

/// Takes the screenshots in `docs/images`: real windows, a real zsh and a clone of this repository,
/// in a throwaway home folder so nothing of yours shows. Run it with `make screenshots`, which gives
/// the process that home folder (`HOME` and `CFFIXED_USER_HOME`, for `NSHomeDirectory()`).
@Suite("Screenshot tour", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["CODEC_SCREENSHOTS"] != nil
                && ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
@MainActor
struct ScreenshotTour {
    private let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEC_SCREENSHOTS"] ?? "", isDirectory: true)
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func takeScreenshots() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true, sampler: HostSampler())
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let project = home.appendingPathComponent("Developer/codec", isDirectory: true)
        let cwd = FileManager.default.currentDirectoryPath
        defer {
            unsetenv("ZDOTDIR")
            FileManager.default.changeCurrentDirectoryPath(cwd)
            env.tearDown()
        }
        try makeHome(home, project: project)
        setenv("ZDOTDIR", home.path, 1)
        var prompt = PromptConfiguration.default
        prompt.style = .codec
        env.preferences.prompt = prompt
        FileManager.default.changeCurrentDirectoryPath(project.path)
        try fillHistory(env.environment.history, project: project, home: home)
        try fillIntel(personal: env.environment.intelFolder, project: project)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // The test process's windows never hear they're on screen, and the terminal only draws while
        // its window is visible: for the tour, every window says it is.
        Self.windowsSayTheyreVisible(true)
        defer { Self.windowsSayTheyreVisible(false) }
        NSApplication.shared.setActivationPolicy(.regular)

        try await hero(env, project: project)
        try await intel(env, project: project)
        try await history(env, project: project)
        try await editor(env, project: project)
        try await openFile(env, project: project)
        try await branches(env, project: project)
        try await themes(env, project: project)
        try await usualDuration(env, project: project)
        try await environments(env, project: project)
    }

    /// Swaps `NSWindow.occlusionState` for one that's always visible, or back.
    private static func windowsSayTheyreVisible(_ visible: Bool) {
        guard visible != swapped,
              let real = class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.occlusionState)),
              let always = class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.tourOcclusionState)) else { return }
        method_exchangeImplementations(real, always)
        swapped = visible
    }

    nonisolated(unsafe) private static var swapped = false

    // MARK: Shots

    /// Files, a few commands and the Commands sidebar, then a command's output.
    private func hero(_ env: TestEnvironment, project: URL) async throws {
        let (controller, pane) = try await window(env, project: project, size: NSSize(width: 1360, height: 820))
        defer { close(controller) }
        controller.toggleFileTree(nil)
        controller.sidebar.reveal(project.appendingPathComponent("Sources/CodecUI"))
        controller.toggleCommandTimeline(nil)
        for command in ["git status --short", "git log --oneline -6", "make lint", "ls Sources/CodecCore | head -8",
                        "swift --version 2>&1 | head -1"] {
            try await run(command, in: pane)
        }
        try await settle()
        try await capture(controller.window!, as: "hero")

        let sidebar = controller.timelineSidebar!
        let row = try #require(sidebar.rows.firstIndex { $0.entry?.command.hasPrefix("git log") == true })
        sidebar.table.selectRowIndexes([row], byExtendingSelection: false)
        sidebar.showOutput(of: try #require(sidebar.rows[row].entry), row: row)
        try await settle()
        try await capture(controller.window!, as: "commands")
    }

    /// The Intel tab, in folders, with a script's form open.
    private func intel(_ env: TestEnvironment, project: URL) async throws {
        let (controller, _) = try await window(env, project: project, size: NSSize(width: 1180, height: 720))
        defer { close(controller) }
        controller.toggleIntel(nil)
        try await settle()
        let entry = try #require(controller.intel.entries.first { $0.item.title == "Deploy a branch" })
        if let row = controller.intelSidebar.rows.firstIndex(where: { $0.entry?.id == entry.id }) {
            controller.intelSidebar.table.selectRowIndexes([row], byExtendingSelection: false)
        }
        controller.showIntelRun(entry)
        try await settle()
        try await capture(controller.window!, as: "intel")

        controller.hideCommandPalette()
        let doc = try #require(controller.intel.entries.first { $0.item.title == "Release checklist" })
        controller.intelSidebar.activate(doc)
        controller.editor.selected?.mode = .split
        try await settle(seconds: 2)
        try await capture(controller.window!, as: "intel-document")
    }

    /// The history search.
    private func history(_ env: TestEnvironment, project: URL) async throws {
        let (controller, pane) = try await window(env, project: project, size: NSSize(width: 1180, height: 720))
        defer { close(controller) }
        try await run("git fetch --prune", in: pane)
        controller.showHistory(for: pane, request: .search, typed: "")
        try await settle()
        try await capture(controller.window!, as: "history")
    }

    /// A Swift file beside the terminal.
    private func editor(_ env: TestEnvironment, project: URL) async throws {
        let (controller, pane) = try await window(env, project: project, size: NSSize(width: 1360, height: 820))
        defer { close(controller) }
        controller.toggleFileTree(nil)
        let file = project.appendingPathComponent("Sources/CodecCore/FuzzyMatch.swift")
        // Edits not committed yet, for the gutter's marks: a line added, one changed, one deleted.
        let source = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "            score += 1\n",
                                  with: "            // Every match counts; runs and word starts count for more.\n            score += 1\n")
            .replacingOccurrences(of: "{ score += 3 }", with: "{ score += 4 }")
            .replacingOccurrences(of: "        // Shorter candidates win ties.\n", with: "")
        try source.write(to: file, atomically: true, encoding: .utf8)
        controller.sidebar.reveal(file)
        try await run("grep -n 'func rank' Sources/CodecCore/*.swift", in: pane)
        controller.openFile(file, pin: true, focus: false)
        try await settle(seconds: 2)
        try await capture(controller.window!, as: "editor")
    }

    /// ⌘ held down: every name a click would open marked, and the one under the pointer tagged with
    /// the file that opens.
    private func openFile(_ env: TestEnvironment, project: URL) async throws {
        let (controller, pane) = try await window(env, project: project, size: NSSize(width: 900, height: 480))
        defer { close(controller) }
        try await run("ls", in: pane)
        try await run("ls Sources/CodecCore | head -8", in: pane)
        try point(pane, at: "FileTree.swift")
        pane.refreshFileLink(modifiers: .command)
        try await settle(seconds: 0.5)
        try await capture(controller.window!, as: "open-file")
    }

    /// Puts the pointer on the last `name` on screen, as the terminal lays out its cells.
    private func point(_ pane: Pane, at name: String) throws {
        let grid = try #require(TerminalGrid(terminal: pane.terminal))
        for row in grid.rows.indices.reversed() {
            let cells = grid.cells(ofRow: row)
            let characters = cells.map(\.character)
            let target = Array(name)
            guard characters.count >= target.count else { continue }
            for start in (0...(characters.count - target.count)).reversed()
            where Array(characters[start..<(start + target.count)]) == target
                && (start == 0 || characters[start - 1] == " ") {
                let point = grid.center(row: row, column: cells[start + 1].column)
                pane.pointerLocation = { point }
                return
            }
        }
        Issue.record("\(name) isn't on screen")
    }

    /// Two panes, and the branch switcher open on the status bar's branch.
    private func branches(_ env: TestEnvironment, project: URL) async throws {
        let (controller, pane) = try await window(env, project: project, size: NSSize(width: 1180, height: 720))
        defer { close(controller) }
        try await run("git log --oneline --graph -8", in: pane)
        controller.splitRight(nil)
        let right = try #require(controller.model.selected?.focused)
        try await waitFor { right.isAtCommandLine }
        try await run("git diff --stat", in: right)
        right.showBranchPicker()
        try await settle()
        try await capture(controller.window!, as: "branches")
    }

    /// A command that ran before, part way through: its progress toward how long it usually takes.
    private func usualDuration(_ env: TestEnvironment, project: URL) async throws {
        let (controller, pane) = try await window(env, project: project, size: NSSize(width: 1180, height: 640))
        defer { close(controller) }
        controller.toggleCommandTimeline(nil)
        try await run("git status --short", in: pane)
        try await settle(seconds: 0.4)
        pane.terminal.send(txt: "make test\r")
        try await waitFor { pane.session.running?.usual != nil }
        try await settle(seconds: 8)
        try await capture(controller.window!, as: "usual-duration")
        try await waitFor { pane.session.running == nil }
    }

    /// Going into a project with a Python environment and mise tools: the question whether to
    /// activate it, and the versions in the status bar, one of them not installed.
    private func environments(_ env: TestEnvironment, project: URL) async throws {
        let (controller, pane) = try await window(env, project: project, size: NSSize(width: 1180, height: 560))
        defer { close(controller) }
        try await run("cd ~/Developer/storefront", in: pane)
        try await waitFor { pane.session.pendingVenv != nil && !pane.session.toolchain.tools.isEmpty }
        try await run("ls", in: pane)
        try await settle()
        try await capture(controller.window!, as: "environments")
    }

    /// The same split window in each theme, in a grid.
    private func themes(_ env: TestEnvironment, project: URL) async throws {
        var images: [NSImage] = []
        for theme in CodecTheme.all {
            env.preferences.themeID = theme.id
            let (controller, pane) = try await window(env, project: project, size: NSSize(width: 820, height: 500))
            controller.splitDown(nil)
            let below = try #require(controller.model.selected?.focused)
            try await waitFor { below.isAtCommandLine }
            try await run("ls", in: below)
            try await run("git log --oneline -3", in: pane)
            try await settle()
            try await redraw(controller.window!)
            images.append(image(of: controller.window!))
            close(controller)
        }
        env.preferences.themeID = CodecTheme.codec.id
        let size = images[0].size
        let gap: CGFloat = 24
        let grid = NSImage(size: NSSize(width: size.width * 2 + gap * 3, height: size.height * 2 + gap * 3), flipped: true) { _ in
            for (index, image) in images.enumerated() {
                let origin = NSPoint(x: gap + CGFloat(index % 2) * (size.width + gap), y: gap + CGFloat(index / 2) * (size.height + gap))
                image.draw(in: NSRect(origin: origin, size: size))
            }
            return true
        }
        write(grid, as: "themes")
    }

    // MARK: Windows and commands

    private func window(_ env: TestEnvironment, project: URL, size: NSSize) async throws -> (TerminalWindowController, Pane) {
        let controller = TerminalWindowController(directory: project.path, environment: env.environment)
        let window = try #require(controller.window)
        // Sidebars stay as the last window left them; each shot opens the ones it wants.
        controller.setFileTreeVisible(false)
        controller.setTimelineVisible(false)
        window.setContentSize(size)
        window.center()
        // Over other apps' windows, so they don't hide it.
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        let pane = try #require(controller.model.selected?.focused)
        try await waitFor { pane.isAtCommandLine }
        return (controller, pane)
    }

    private func close(_ controller: TerminalWindowController) {
        controller.model.tabs.flatMap(\.panes).forEach { $0.shutDown() }
        controller.window?.close()
    }

    private func run(_ command: String, in pane: Pane) async throws {
        // As someone typing would: once zsh is reading the line, not while it's still drawing the prompt.
        try await settle(seconds: 0.3)
        let count = pane.timeline.entries.count
        pane.terminal.send(txt: command + "\r")
        try await waitFor { pane.timeline.entries.count == count + 1 && pane.timeline.running == nil && pane.isAtCommandLine }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            try #require(Date() < deadline, "Timed out")
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Lets animations, file watchers and the meters catch up.
    private func settle(seconds: Double = 1.2) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    // MARK: Capturing

    /// Draws everything now. The terminal draws from a display link, which doesn't run here (the test
    /// process's windows never count as visible); unhiding it makes it draw a frame straight away.
    private func redraw(_ window: NSWindow) async throws {
        func mark(_ view: NSView) {
            if view is TerminalView, !view.isHidden {
                view.isHidden = true
                view.isHidden = false
            }
            view.needsDisplay = true
            view.subviews.forEach(mark)
        }
        for window in NSApplication.shared.windows where window.isVisible {
            window.contentView.map(mark)
            window.displayIfNeeded()
        }
        CATransaction.flush()
        try await settle(seconds: 0.4)
    }

    /// The window and the app's windows over it (popovers), at the screen's resolution, with a shadow.
    private func image(of window: NSWindow) -> NSImage {
        let numbers = NSWindow.windowNumbers(options: []) ?? []
        // Back to front.
        let windows = numbers.reversed().compactMap { NSApplication.shared.window(withWindowNumber: $0.intValue) }
            .filter { $0 === window || ($0.isVisible && $0.frame.intersects(window.frame.insetBy(dx: -200, dy: -200)) && $0.level.rawValue >= window.level.rawValue) }
        let start = windows.firstIndex { $0 === window } ?? 0
        let layers = windows[start...].compactMap { other -> (NSRect, CGImage)? in
            Self.capture(other.windowNumber).map { (other.frame, $0) }
        }
        let bounds = layers.reduce(window.frame) { $0.union($1.0) }
        let margin: CGFloat = 48
        let canvas = bounds.insetBy(dx: -margin, dy: -margin)
        return NSImage(size: canvas.size, flipped: false) { _ in
            for (index, (frame, image)) in layers.enumerated() {
                let rect = frame.offsetBy(dx: -canvas.minX, dy: -canvas.minY)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = .black.withAlphaComponent(index == 0 ? 0.45 : 0.25)
                shadow.shadowBlurRadius = index == 0 ? 28 : 14
                shadow.shadowOffset = NSSize(width: 0, height: index == 0 ? -12 : -4)
                shadow.set()
                NSImage(cgImage: image, size: frame.size).draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
    }

    private func capture(_ window: NSWindow, as name: String) async throws {
        try await redraw(window)
        write(image(of: window), as: name)
    }

    private func write(_ image: NSImage, as name: String) {
        // At twice the points, for Retina screens.
        let size = NSSize(width: image.size.width * 2, height: image.size.height * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("\(name).png"))
    }

    /// One of this app's own windows, as the window server draws it. `CGWindowListCreateImage` is
    /// deprecated in favor of ScreenCaptureKit, which needs the Screen Recording permission even for
    /// your own windows; this doesn't.
    private static func capture(_ windowNumber: Int) -> CGImage? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
        return create(.null, 1 << 3, UInt32(windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue()
    }

    // MARK: Demo content

    private func shell(_ command: String, in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-fc", command]
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(command) failed")
    }

    /// A project with a uv environment and tools from mise, and a `mise` that reports them there.
    private func makeStorefront(_ home: URL) throws {
        let store = home.appendingPathComponent("Developer/storefront")
        let files = [
            ".venv/pyvenv.cfg": "home = /opt/homebrew/opt/python@3.13/bin\nimplementation = CPython\nversion_info = 3.13.5\nprompt = storefront\n",
            "mise.toml": "[tools]\nruby = \"3.4.7\"\nnode = \"22\"\n",
            "pyproject.toml": "[project]\nname = \"storefront\"\n", "uv.lock": "", "Gemfile": "source \"https://rubygems.org\"\n",
            "package.json": "{}\n", "README.md": "# Storefront\n", "app/.keep": "", "scripts/.keep": "",
        ]
        for (path, contents) in files {
            let file = store.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        // Its own repository, not the one around the tour's home folder.
        try shell("git init --quiet -b main", in: store)
        let source = store.appendingPathComponent("mise.toml").path
        let installs = home.appendingPathComponent(".local/share/mise/installs").path
        let tools = #"{"ruby":[{"version":"3.4.7","requested_version":"3.4.7","install_path":"\#(installs)/ruby/3.4.7","source":{"type":"mise.toml","path":"\#(source)"},"installed":true}],"node":[{"version":"22.21.1","requested_version":"22","install_path":"\#(installs)/node/22.21.1","source":{"type":"mise.toml","path":"\#(source)"},"installed":false}]}"#
        let mise = home.appendingPathComponent("bin/mise")
        try FileManager.default.createDirectory(at: mise.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\ncase \"$PWD\" in \(store.path)*) echo '\(tools)' ;; *) echo '{}' ;; esac\n"
            .write(to: mise, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mise.path)
    }

    /// A home folder with a quiet `.zshrc` and a clone of this repository with a few changes and branches.
    private func makeHome(_ home: URL, project: URL) throws {
        try FileManager.default.createDirectory(at: project.deletingLastPathComponent(), withIntermediateDirectories: true)
        // `make test` stands in for the test suite: test output for twelve seconds, rather than a real build.
        let zshrc = #"""
            export EDITOR=vim
            HISTFILE=~/.zsh_history
            PS1='%~ %# '
            # A stand-in for mise, active as `mise activate` makes it, with tools only in the storefront.
            path=(~/bin $path)
            _mise_hook() { :; }
            make() {
              if [[ $1 == test ]]; then
                local i
                for i in {1..48}; do print "Test Case 'Suite.test$i' passed (0.$((RANDOM % 9)) seconds)"; sleep 0.25; done
                print "Executed 48 tests, with 0 failures"
              else
                command make "$@"
              fi
            }
            """#
        try (zshrc + "\n").write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try makeStorefront(home)
        try shell("git clone --quiet '\(Self.repository.path)' '\(project.path)'", in: home)
        try shell("""
            git config user.name 'Solid Snake' && git config user.email snake@example.com && \
            git branch feature/intel-folders && git branch fix/history-ranking && git branch release/1.2 && \
            git switch --quiet -c feature/onboarding && \
            printf '\\n// Shown on first launch.\\n' >> Sources/CodecUI/AppDelegate.swift && \
            printf 'import AppKit\\n\\n/// The first-launch tour.\\nstruct Onboarding {}\\n' > Sources/CodecUI/Onboarding.swift && \
            printf '\\n- Onboarding: a short tour on first launch.\\n' >> README.md
            """, in: project)
    }

    private func fillHistory(_ history: HistoryStore, project: URL, home: URL) throws {
        let now = Date()
        let api = home.appendingPathComponent("Developer/api").path
        let site = home.appendingPathComponent("Developer/site").path
        let entries: [(String, String, Double, Int32, TimeInterval)] = [
            ("swift build -c release", project.path, 0.02, 0, 48.2),
            ("make test", project.path, 0.03, 0, 12.6),
            ("make test", project.path, 0.2, 0, 13.4),
            ("make test", project.path, 0.7, 0, 12.9),
            ("swift test --filter IntelTests", project.path, 0.05, 0, 12.4),
            ("git push -u origin feature/onboarding", project.path, 0.1, 0, 2.1),
            ("git rebase -i main", project.path, 0.3, 1, 0.4),
            ("make test JOBS=8", project.path, 0.6, 0, 96.3),
            ("gh pr create --fill", project.path, 0.9, 0, 3.2),
            ("docker compose up -d", api, 2.0, 0, 18.7),
            ("kubectl get pods -n staging", api, 3.4, 0, 1.3),
            ("ssh deploy@staging.example.com", api, 5.0, 255, 30.0),
            ("npm run dev", site, 26.0, 130, 1800),
            ("npm install", site, 26.5, 0, 22.4),
            ("brew upgrade", home.path, 30.0, 0, 64.0),
            ("git log --oneline --graph -20", project.path, 50, 0, 0.1),
            ("rg 'TODO' Sources", project.path, 52, 0, 0.2),
            ("xcrun simctl list devices", home.path, 75, 0, 1.4),
        ]
        for (command, directory, hoursAgo, status, duration) in entries.reversed() {
            history.record(HistoryEntry(command: command, date: now.addingTimeInterval(-hoursAgo * 3600), directory: directory,
                                        exitCode: status, duration: duration))
        }
    }

    private func fillIntel(personal: URL, project: URL) throws {
        let library = IntelLibrary(personalFolder: personal)
        library.follow(project.path)
        var deploy = IntelItem.script(title: "Deploy a branch", description: "Pushes it, then deploys it",
                                      command: "git push origin {{branch}} && ./deploy --env {{env}} --replicas {{replicas}}")
        deploy.variables = [
            IntelVariable(name: "branch", description: "What to deploy", defaultValue: "main"),
            IntelVariable(name: "env", description: "Where to", choices: ["staging", "production"]),
            IntelVariable(name: "replicas", defaultValue: "3"),
        ]
        try library.createFolder(named: "Deploys", in: .personal)
        try library.save(deploy, to: .personal, folder: "Deploys")
        try library.createFolder(named: "Rollbacks", in: .personal, parent: "Deploys")
        try library.save(.script(title: "Roll back production", command: "./deploy --env production --rollback"),
                         to: .personal, folder: "Deploys/Rollbacks")
        try library.createFolder(named: "Git", in: .personal)
        try library.save(.script(title: "Clean merged branches", description: "Deletes branches merged into main",
                                 command: "git branch --merged main | grep -v main | xargs git branch -d"), to: .personal, folder: "Git")
        try library.save(.script(title: "Undo the last commit", description: "Keeps the changes",
                                 command: "git reset --soft HEAD~1"), to: .personal, folder: "Git")
        try library.createFolder(named: "Docker", in: .personal)
        try library.save(.script(title: "Prune everything", command: "docker system prune -af --volumes"), to: .personal, folder: "Docker")
        var checklist = IntelItem(kind: .doc, title: "Release checklist", description: "Before tagging a release")
        checklist.body = """
            # Release checklist

            Before tagging a release, from a clean `main`.

            1. Make sure CI is green on `main`.
            2. Run the whole suite locally, in release:

            ```sh
            make test JOBS=8
            ```

            3. Build the app and try it for a few minutes:

            ```sh
            make run
            ```

            4. Tag it and push the tag:

            ```sh
            git tag -s v1.2.0 -m "Codec 1.2" && git push origin v1.2.0
            ```

            | Check | Who |
            |---|---|
            | Release notes | whoever tags |
            | Screenshots still match | `make screenshots` |
            """
        try library.save(checklist, to: .personal)
        try library.save(.script(title: "Find large files", command: "find {{path}} -size +{{size}} -print"), to: .personal)
        try library.save(.script(title: "Build and open the app", description: "In release", command: "make run JOBS={{jobs}}"), to: .project)
        try library.save(.script(title: "Run one test suite", command: "swift test --filter {{suite}}"), to: .project)
        try shell("git add .codec && git commit --quiet -m 'Share our Intel'", in: project)
    }
}

extension NSWindow {
    /// Stands in for `occlusionState` during the screenshot tour.
    @objc var tourOcclusionState: NSWindow.OcclusionState { .visible }
}
