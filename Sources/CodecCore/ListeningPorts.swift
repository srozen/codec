import Foundation

/// A TCP port a program started from a pane is listening on: a dev server, a debugger, a database.
public struct ListeningPort: Equatable, Sendable, Identifiable {
    public var port: Int
    /// The program holding it, as `ProcessInspector.name` has it.
    public var program: String
    public var pid: pid_t
    /// It belongs to the command in the foreground, not to a job left in the background.
    public var foreground: Bool
    /// The address the program printed for it (`http://localhost:3000/app`), when it printed one.
    public var address: String?
    /// What the user called the process ("Storefront"), for as long as it runs.
    public var name: String?

    public init(port: Int, program: String, pid: pid_t = 0, foreground: Bool = false, address: String? = nil,
                name: String? = nil) {
        self.port = port
        self.program = program
        self.pid = pid
        self.foreground = foreground
        self.address = address
        self.name = name
    }

    public var id: Int { port }

    /// What to call it: the name it was given, or else its program's.
    public var displayName: String { name ?? program }

    /// ":3000".
    public var label: String { ":\(port)" }

    /// What to open in the browser: the address the program printed, or else plain HTTP on this Mac.
    public var url: URL {
        address.flatMap(URL.init(string:)) ?? URL(string: "http://localhost:\(port)")!
    }
}

public enum ListeningPorts {
    /// The ports the programs under `shell` listen on, lowest first, each once: a server that forks
    /// workers shares its socket with them, and the one nearest the shell is named.
    public static func scan(shell: pid_t, foregroundGroup: pid_t?,
                            descendants: (pid_t) -> [pid_t] = { ProcessInspector.descendants(of: $0) },
                            ports: (pid_t) -> [Int] = ProcessInspector.listeningPorts(of:),
                            group: (pid_t) -> pid_t? = ProcessInspector.processGroup(of:),
                            name: (pid_t) -> String? = ProcessInspector.name(of:)) -> [ListeningPort] {
        var found: [ListeningPort] = []
        for pid in descendants(shell) {
            let listening = ports(pid).filter { port in !found.contains { $0.port == port } }
            guard !listening.isEmpty else { continue }
            let program = name(pid) ?? "pid \(pid)"
            let foreground = foregroundGroup != nil && group(pid) == foregroundGroup
            found += listening.map { ListeningPort(port: $0, program: program, pid: pid, foreground: foreground) }
        }
        return found.sorted { $0.port < $1.port }
    }

    /// `scanned`, with what's already known of the processes still there: the address found for a
    /// port the same process still holds, and the name its process was given, on every port it has.
    public static func merging(_ scanned: [ListeningPort], keepingAddressesOf known: [ListeningPort]) -> [ListeningPort] {
        scanned.map { port in
            var port = port
            port.address = known.first { $0.port == port.port && $0.pid == port.pid }?.address
            port.name = known.first { $0.pid == port.pid && $0.name != nil }?.name
            return port
        }
    }

    /// `ports`, with the process holding `port` called `name` on every port it has; a blank name, or
    /// none, takes its name away.
    public static func naming(_ port: ListeningPort, _ name: String?, in ports: [ListeningPort]) -> [ListeningPort] {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ports.map { other in
            guard other.pid == port.pid else { return other }
            var other = other
            other.name = trimmed.isEmpty ? nil : trimmed
            return other
        }
    }

    /// ":3000 :9229", and "+2" for those past `limit`, so many ports don't take over the status bar.
    public static func label(_ ports: [ListeningPort], limit: Int = 3) -> String {
        var parts = ports.prefix(limit).map(\.label)
        if ports.count > limit { parts.append("+\(ports.count - limit)") }
        return parts.joined(separator: " ")
    }

    /// "listening on :3000", "listening on :3000 and :9229", "listening on :3000, :3001 and :9229";
    /// saying who when asked, "listening on :3000 (node)"; with a capital to stand on a line of its own.
    public static func phrase(_ ports: [ListeningPort], namingPrograms: Bool = false, capitalized: Bool = false) -> String {
        let labels = ports.map { namingPrograms ? "\($0.label) (\($0.displayName))" : $0.label }
        let list = labels.count > 1 ? labels.dropLast().joined(separator: ", ") + " and " + labels.last! : labels.first ?? ""
        return (capitalized ? "Listening on " : "listening on ") + list
    }

    /// Hosts that mean this Mac. The last two are what a server bound to every address prints.
    private static let localHosts = #"localhost|[a-z0-9-]+(?:\.[a-z0-9-]+)*\.localhost|127\.0\.0\.1|\[::1\]|0\.0\.0\.0|\[::\]"#
    private static let addressPattern = try! NSRegularExpression(
        pattern: #"\bhttps?://(?:"# + localHosts + #"):([0-9]{1,5})(?![0-9])[^\s"'<>`\\]*"#, options: [.caseInsensitive])

    /// The first address in `text` for `port` on this Mac, as a program announces where it's serving
    /// (`Local: http://localhost:3000/app`), scheme and path included. An address every interface
    /// answers on (`0.0.0.0`) is given as `localhost`, which a browser can open.
    public static func address(for port: Int, in text: String) -> String? {
        let string = text as NSString
        for match in addressPattern.matches(in: text, range: NSRange(location: 0, length: string.length))
        where Int(string.substring(with: match.range(at: 1))) == port {
            var address = string.substring(with: match.range)
            // Punctuation of the sentence it's in, not of the address.
            while let last = address.last, ".,;:!?)]}".contains(last) { address.removeLast() }
            for any in ["0.0.0.0", "[::]"] {
                if let host = address.range(of: "://\(any):") {
                    address.replaceSubrange(host, with: "://localhost:")
                }
            }
            if URL(string: address) != nil { return address }
        }
        return nil
    }
}

/// A command failed because a port it wanted was taken, and Codec knows by whom: a program running
/// in one of its panes.
public struct PortConflict: Codable, Equatable, Sendable {
    public var port: Int
    /// The program that held it.
    public var program: String
    /// The pane it ran in, by its session's id. Means nothing once Codec has quit.
    public var pane: String

    public init(port: Int, program: String, pane: String) {
        self.port = port
        self.program = program
        self.pane = pane
    }

    /// "Port 3000 is in use by “node”", and where when that's known; "was", once it has let go of it.
    public func sentence(stillHeld: Bool = true, place: String? = nil) -> String {
        let subject = "Port \(port) \(stillHeld ? "is" : "was") in use by “\(program)”"
        guard stillHeld, let place, !place.isEmpty else { return subject }
        return "\(subject) in \(place)"
    }

    /// What failing to bind looks like, whatever printed it: `EADDRINUSE` (Node), "Address already in
    /// use" (C, Python, Go, Ruby, Java), `AddrInUse` (Rust), "Port 5000 is in use" (Flask), "That
    /// port is already in use" (Django).
    private static let marker = try! NSRegularExpression(
        pattern: #"EADDRINUSE|ADDRINUSE|address (?:is )?(?:already )?in use|\bport\b.*\bin use\b"#, options: [.caseInsensitive])

    /// How a port is written on such a line, most telling first: "port 3000"; after an address
    /// (`127.0.0.1:3000`, `:::3000`, ` :8080`), which a time of day (`12:30:45`) isn't; Python's
    /// `('127.0.0.1', 8000)`.
    private static let portsInOutput = [
        #"\bport[ =:#]*([0-9]{1,5})(?![0-9])"#,
        #"(?:(?:[0-9]{1,3}\.){3}[0-9]{1,3}|localhost|\]|::|\*|[\s("'=]|^):([0-9]{1,5})(?![0-9.])"#,
        #"['"], ?([0-9]{1,5})\)"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// The same in a command: `--port 3000`, `-p 3000`, `PORT=3000`, `localhost:3000`.
    private static let portsInCommand = [
        #"(?:^|\s)(?:--?[a-z-]*port|-p)[ =]([0-9]{1,5})(?![0-9])"#,
        #"\b[A-Z_]*PORT=([0-9]{1,5})(?![0-9])"#,
        #"(?:(?:[0-9]{1,3}\.){3}[0-9]{1,3}|localhost|\]|::|\*|[\s("'=]|^):([0-9]{1,5})(?![0-9.])"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// The port a failed command found taken, from what it printed, or from the command itself when
    /// the error names none (`python -m http.server 8000`). Nil when the output doesn't say a port
    /// was taken, or which one can't be told.
    public static func port(inOutput output: String, command: String) -> Int? {
        var refused = false
        for line in output.split(separator: "\n") {
            let line = String(line)
            guard marker.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil else { continue }
            refused = true
            if let port = firstPort(in: line, among: portsInOutput) { return port }
        }
        guard refused else { return nil }
        if let port = firstPort(in: command, among: portsInCommand) { return port }
        // A number on its own, when there's only one it could be: `nc -l 8080`, `http.server 8000`.
        let numbers = command.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }.filter(isPort)
        return numbers.count == 1 ? numbers[0] : nil
    }

    private static func isPort(_ number: Int) -> Bool { (1...65_535).contains(number) }

    private static func firstPort(in text: String, among patterns: [NSRegularExpression]) -> Int? {
        let string = text as NSString
        for pattern in patterns {
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
                if let port = Int(string.substring(with: match.range(at: 1))), isPort(port) { return port }
            }
        }
        return nil
    }
}
