import Testing
import Foundation
@testable import CodecCore

@Suite("Listening ports")
struct ListeningPortsTests {
    /// A shell (10) running npm (11), which runs sh (12), which runs node (13) and a worker it forked
    /// (14); and a job in the background (20).
    private let children: [pid_t: [pid_t]] = [10: [11, 20], 11: [12], 12: [13], 13: [14]]
    private let names: [pid_t: String] = [11: "npm", 12: "sh", 13: "node", 14: "node", 20: "python3.13"]
    private let ports: [pid_t: [Int]] = [13: [9229, 3000], 14: [3000], 20: [8000]]
    private let groups: [pid_t: pid_t] = [11: 11, 12: 11, 13: 11, 14: 11, 20: 20]

    private func scan(foreground: pid_t?) -> [ListeningPort] {
        ListeningPorts.scan(shell: 10, foregroundGroup: foreground,
                            descendants: { shell in
                                var found: [pid_t] = [], next = children[shell] ?? []
                                while !next.isEmpty {
                                    found += next
                                    next = next.flatMap { children[$0] ?? [] }
                                }
                                return found
                            },
                            ports: { ports[$0] ?? [] }, group: { groups[$0] }, name: { names[$0] })
    }

    @Test func findsWhatTheShellsProgramsListenOn() {
        // Lowest first, each once, held by the process nearest the shell, and whether it's the command in front.
        #expect(scan(foreground: 11) == [
            ListeningPort(port: 3000, program: "node", pid: 13, foreground: true),
            ListeningPort(port: 8000, program: "python3.13", pid: 20, foreground: false),
            ListeningPort(port: 9229, program: "node", pid: 13, foreground: true),
        ])
        // At the prompt, the shell is in front: everything listening is a job in the background.
        #expect(scan(foreground: 10).allSatisfy { !$0.foreground })
        #expect(scan(foreground: nil).map(\.port) == [3000, 8000, 9229])
    }

    @Test func keepsAnAddressWhileTheSameProcessHoldsThePort() {
        let known = [ListeningPort(port: 3000, program: "node", pid: 13, address: "http://localhost:3000/app"),
                     ListeningPort(port: 8000, program: "python", pid: 20, address: "http://localhost:8000")]
        let scanned = [ListeningPort(port: 3000, program: "node", pid: 13), ListeningPort(port: 8000, program: "ruby", pid: 31)]
        let merged = ListeningPorts.merging(scanned, keepingAddressesOf: known)
        #expect(merged.map(\.address) == ["http://localhost:3000/app", nil])
    }

    @Test func aProcessGoesByTheNameItWasGiven() {
        let ports = [ListeningPort(port: 3000, program: "node", pid: 13), ListeningPort(port: 9229, program: "node", pid: 13),
                     ListeningPort(port: 8000, program: "python", pid: 20)]
        #expect(ports[0].displayName == "node")
        // The process is named, so every port it has is.
        let named = ListeningPorts.naming(ports[0], "  Storefront ", in: ports)
        #expect(named.map(\.name) == ["Storefront", "Storefront", nil])
        #expect(named.map(\.displayName) == ["Storefront", "Storefront", "python"])
        #expect(ListeningPorts.phrase(named, namingPrograms: true) == "listening on :3000 (Storefront), :9229 (Storefront) and :8000 (python)")
        // It keeps its name while it runs, on ports it opens later too; another process in its place doesn't get it.
        let later = [ListeningPort(port: 3000, program: "node", pid: 13), ListeningPort(port: 3001, program: "node", pid: 13),
                     ListeningPort(port: 8000, program: "python", pid: 21)]
        #expect(ListeningPorts.merging(later, keepingAddressesOf: named).map(\.name) == ["Storefront", "Storefront", nil])
        let restarted = [ListeningPort(port: 3000, program: "node", pid: 14)]
        #expect(ListeningPorts.merging(restarted, keepingAddressesOf: named).map(\.name) == [nil])
        // A blank name, or none, takes it away.
        #expect(ListeningPorts.naming(named[1], " ", in: named).map(\.name) == [nil, nil, nil])
        #expect(ListeningPorts.naming(named[0], nil, in: named).map(\.name) == [nil, nil, nil])
    }

    @Test func opensTheAddressPrintedOrPlainHTTP() {
        #expect(ListeningPort(port: 3000, program: "node").url.absoluteString == "http://localhost:3000")
        #expect(ListeningPort(port: 3000, program: "node", address: "https://localhost:3000/app").url.absoluteString
                == "https://localhost:3000/app")
        #expect(ListeningPort(port: 3000, program: "node").label == ":3000")
    }

    @Test func saysWhatIsListening() {
        let ports = [3000, 3001, 5173, 9229].map { ListeningPort(port: $0, program: $0 == 5173 ? "vite" : "node") }
        #expect(ListeningPorts.label(Array(ports.prefix(1))) == ":3000")
        #expect(ListeningPorts.label(Array(ports.prefix(3))) == ":3000 :3001 :5173")
        #expect(ListeningPorts.label(ports) == ":3000 :3001 :5173 +1")
        #expect(ListeningPorts.phrase(Array(ports.prefix(1))) == "listening on :3000")
        #expect(ListeningPorts.phrase(Array(ports.prefix(2)), capitalized: true) == "Listening on :3000 and :3001")
        #expect(ListeningPorts.phrase(Array(ports.prefix(3))) == "listening on :3000, :3001 and :5173")
        #expect(ListeningPorts.phrase(Array(ports.suffix(2)), namingPrograms: true) == "listening on :5173 (vite) and :9229 (node)")
    }

    @Test func findsTheAddressAProgramAnnounced() {
        let vite = """
              VITE v7.1.0  ready in 212 ms

              ➜  Local:   http://localhost:5173/app/
              ➜  Network: http://192.168.1.20:5173/app/
            """
        #expect(ListeningPorts.address(for: 5173, in: vite) == "http://localhost:5173/app/")
        #expect(ListeningPorts.address(for: 3000, in: vite) == nil)
        // The first one printed, without the sentence's punctuation.
        #expect(ListeningPorts.address(for: 3000, in: "Ready on https://127.0.0.1:3000. GET http://localhost:3000/api/users 200")
                == "https://127.0.0.1:3000")
        #expect(ListeningPorts.address(for: 8080, in: "(see http://[::1]:8080/docs?tab=1#top)") == "http://[::1]:8080/docs?tab=1#top")
        #expect(ListeningPorts.address(for: 4000, in: "Serving at http://api.myapp.localhost:4000") == "http://api.myapp.localhost:4000")
        // Every interface: a browser opens it as localhost.
        #expect(ListeningPorts.address(for: 8000, in: "Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)")
                == "http://localhost:8000")
        #expect(ListeningPorts.address(for: 8000, in: "listening on http://[::]:8000/") == "http://localhost:8000/")
        // Another port, another machine, or no address at all.
        #expect(ListeningPorts.address(for: 300, in: "http://localhost:3000") == nil)
        #expect(ListeningPorts.address(for: 3000, in: "proxying to http://api.example.com:3000") == nil)
        #expect(ListeningPorts.address(for: 3000, in: "Listening on port 3000") == nil)
    }

    @Test func readsTheSocketsOfAProcess() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(descriptor, pointer, length) == 0 && getsockname(descriptor, pointer, &length) == 0
            }
        }
        try #require(bound)
        let port = Int(UInt16(bigEndian: address.sin_port))
        // Bound isn't listening yet.
        #expect(!ProcessInspector.listeningPorts(of: getpid()).contains(port))
        try #require(listen(descriptor, 1) == 0)
        #expect(ProcessInspector.listeningPorts(of: getpid()).contains(port))
        #expect(ProcessInspector.listeningPorts(of: -1).isEmpty)
        #expect(ProcessInspector.processGroup(of: getpid()) == getpgrp())
        #expect(ProcessInspector.processGroup(of: -1) == nil)
    }

    @Test func findsTheProcessesAProcessStartedAndTheirs() throws {
        // A shell that starts a sleep and waits for it: a child, and a child of that child.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 20 & wait"]
        try shell.run()
        var grandchildren: [pid_t] = []
        for _ in 0..<100 where grandchildren.isEmpty {
            grandchildren = ProcessInspector.children(of: shell.processIdentifier)
            if grandchildren.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
        }
        defer {
            shell.terminate()
            grandchildren.forEach { kill($0, SIGTERM) }
        }
        try #require(!grandchildren.isEmpty)
        let found = ProcessInspector.descendants(of: getpid())
        // Nearest first.
        let child = try #require(found.firstIndex(of: shell.processIdentifier))
        let grandchild = try #require(found.firstIndex(of: grandchildren[0]))
        #expect(child < grandchild)
        #expect(!ProcessInspector.children(of: getpid()).contains(grandchildren[0]))
        #expect(ProcessInspector.descendants(of: getpid(), limit: 1).count == 1)
        #expect(ProcessInspector.descendants(of: -1).isEmpty)
    }
}

@Suite("Port conflicts")
struct PortConflictTests {
    @Test(arguments: [
        ("Error: listen EADDRINUSE: address already in use :::3000", "npm run dev", 3000),
        ("[12:30:45] Error: listen EADDRINUSE: address already in use 127.0.0.1:8080", "node server.js", 8080),
        ("2026/11/12 10:02:11 listen tcp :8081: bind: address already in use", "go run .", 8081),
        (#"Address already in use - bind(2) for "127.0.0.1" port 3000 (Errno::EADDRINUSE)"#, "bin/rails server", 3000),
        ("ERROR:    [Errno 48] error while attempting to bind on address ('127.0.0.1', 8000): address already in use",
         "uvicorn main:app", 8000),
        ("nginx: [emerg] bind() to 0.0.0.0:8443 failed (48: Address already in use)", "nginx", 8443),
        ("Address already in use\nPort 5000 is in use by another program. Either identify and stop that program, or start the server with a different port.",
         "flask run", 5000),
        ("Error: That port is already in use.", "python manage.py runserver 8001", 8001),
        // The error names no port: the command does.
        ("OSError: [Errno 48] Address already in use", "python3 -m http.server 8000", 8000),
        ("nc: Address already in use", "nc -l 127.0.0.1 47631", 47631),
        ("java.net.BindException: Address already in use", "java -jar app.jar --server.port=9090", 9090),
        (#"Error: Os { code: 48, kind: AddrInUse, message: "Address already in use" }"#, "PORT=4000 cargo run", 4000),
        ("Error: bind: address already in use", "caddy file-server --listen localhost:2015", 2015),
        ("bind: Address already in use", "docker-proxy -p 8088:80", 8088),
    ])
    func findsThePortACommandFoundTaken(output: String, command: String, port: Int) {
        #expect(PortConflict.port(inOutput: "Starting…\n" + output + "\n    at Server.setupListenHandle (node:net:1908:16)",
                                  command: command) == port)
    }

    @Test func saysNothingWhenItCantTell() {
        // Not about a port.
        #expect(PortConflict.port(inOutput: "ls: nope: No such file or directory", command: "ls nope --port 3000") == nil)
        #expect(PortConflict.port(inOutput: "error: the file is in use by another process", command: "cp a b") == nil)
        // About one, but which?
        #expect(PortConflict.port(inOutput: "OSError: [Errno 48] Address already in use", command: "python3 -m http.server") == nil)
        #expect(PortConflict.port(inOutput: "bind: Address already in use", command: "relay 8000 9000") == nil)
        #expect(PortConflict.port(inOutput: "Error: listen EADDRINUSE: address already in use :::99999", command: "node x.js") == nil)
    }

    @Test func saysWhoHasThePort() {
        let conflict = PortConflict(port: 3000, program: "node", pane: "A")
        #expect(conflict.sentence() == "Port 3000 is in use by “node”")
        #expect(conflict.sentence(place: "Tab 2 › left pane") == "Port 3000 is in use by “node” in Tab 2 › left pane")
        #expect(conflict.sentence(stillHeld: false, place: "Tab 2") == "Port 3000 was in use by “node”")
    }

    @Test func aTimelineRemembersIt() throws {
        var timeline = CommandTimeline()
        let id = timeline.begin(command: "npm run dev", directory: "/tmp", started: Date(timeIntervalSince1970: 0), block: nil)
        timeline.finish(exitCode: 1, duration: 1, output: CapturedOutput(lines: ["Error: listen EADDRINUSE :::3000"]))
        let conflict = PortConflict(port: 3000, program: "node", pane: "A")
        timeline.setPortConflict(conflict, of: id)
        #expect(timeline.entry(id: id)?.portConflict == conflict)
        // Kept with the pane's commands, and read back; older ones saved without it still read.
        let data = try JSONEncoder().encode(timeline)
        #expect(try JSONDecoder().decode(CommandTimeline.self, from: data).entry(id: id)?.portConflict == conflict)
        var plain = CommandTimeline()
        plain.begin(command: "ls", directory: "/tmp", started: Date(timeIntervalSince1970: 0), block: nil)
        let old = try JSONDecoder().decode(CommandTimeline.self, from: JSONEncoder().encode(plain))
        #expect(old.entries.first?.portConflict == nil)
    }

    @Test func explainingIsToldWhoHasThePort() throws {
        var entry = TimelineEntry(id: 1, command: "npm run dev", directory: "/tmp/web", started: Date(timeIntervalSince1970: 0), block: nil)
        entry.exitCode = 1
        #expect(FailureReport(entry: entry, output: "EADDRINUSE")?.prompt.contains("Known:") == false)
        entry.portConflict = PortConflict(port: 3000, program: "node", pane: "A")
        let report = try #require(FailureReport(entry: entry, output: "EADDRINUSE"))
        #expect(report.known == "Port 3000 is in use by “node”, a program running in one of this terminal’s panes.")
        #expect(report.prompt.contains("Exit status: 1\nKnown: Port 3000 is in use by “node”, a program running in one of this terminal’s panes.\nOutput:\nEADDRINUSE"))
    }
}
