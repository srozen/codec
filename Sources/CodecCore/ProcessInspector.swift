import Darwin

/// What closing a shell would end: the program in the foreground and any jobs in the background,
/// but not the shell itself or the helpers shells and prompts keep running.
public enum RunningPrograms {
    /// Prompt helpers that live as long as the shell (powerlevel10k's gitstatusd and the like).
    static let helperPrefixes = ["gitstatusd"]

    /// The names of the programs a shell is running, foreground first, each once.
    public static func names(shell: pid_t, foreground: pid_t?, children: [pid_t], name: (pid_t) -> String?) -> [String] {
        var pids = children
        if let foreground, foreground != shell, !pids.contains(foreground) { pids.insert(foreground, at: 0) }
        if let foreground, let index = pids.firstIndex(of: foreground), index > 0 { pids.insert(pids.remove(at: index), at: 0) }
        var names: [String] = []
        for pid in pids where pid != shell {
            guard let program = name(pid), !program.isEmpty, !CommandNames.isShell(program),
                  !helperPrefixes.contains(where: program.hasPrefix), !names.contains(program) else { continue }
            names.append(program)
        }
        return names
    }

    /// `names`, then the programs holding `ports` that aren't among them: a server is often started
    /// by something else (`npm` runs `node`), and it's the one worth naming.
    public static func programs(_ names: [String], listening ports: [ListeningPort]) -> [String] {
        ports.reduce(into: names) { names, port in
            if !names.contains(port.program) { names.append(port.program) }
        }
    }

    /// "“make”", "“make” and “npm”", "“make”, “npm” and “ssh”". A program that's listening says on
    /// what: "“npm” and “node” (listening on :3000)".
    public static func list(_ names: [String], listening ports: [ListeningPort] = []) -> String {
        let quoted = programs(names, listening: ports).map { name in
            let held = ports.filter { $0.program == name }
            return held.isEmpty ? "“\(name)”" : "“\(name)” (\(ListeningPorts.phrase(held)))"
        }
        guard quoted.count > 1 else { return quoted.first ?? "" }
        return quoted.dropLast().joined(separator: ", ") + " and " + quoted.last!
    }
}

/// Reads the foreground program and working directory behind a pty, the way Terminal.app titles its tabs.
public enum ProcessInspector {
    /// The foreground process group of the terminal on `ptyFD`.
    public static func foregroundProcess(ptyFD: Int32) -> pid_t? {
        guard ptyFD >= 0 else { return nil }
        let group = tcgetpgrp(ptyFD)
        return group > 0 ? group : nil
    }

    public static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The processes `pid` started that are still running.
    public static func children(of pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: 512)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return buffer.prefix(min(Int(count), buffer.count)).filter { $0 > 0 }
    }

    /// Every process `pid` started that's still running, and those they started in turn, nearest
    /// first: a dev server is rarely the shell's own child (`npm` runs `sh`, which runs `node`).
    public static func descendants(of pid: pid_t, limit: Int = 512) -> [pid_t] {
        var found: [pid_t] = []
        var seen: Set<pid_t> = [pid]
        var parents = [pid]
        while !parents.isEmpty, found.count < limit {
            var next: [pid_t] = []
            for parent in parents {
                for child in children(of: parent) where seen.insert(child).inserted { next.append(child) }
            }
            found += next
            parents = next
        }
        return Array(found.prefix(limit))
    }

    /// The process group `pid` is in: the shell puts each command, with what it starts, in its own.
    public static func processGroup(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_pgid)
    }

    /// The TCP ports `pid` is listening on, each once, as the kernel reports its sockets. Works for
    /// the user's own processes; empty for anyone else's.
    public static func listeningPorts(of pid: pid_t) -> [Int] {
        guard pid > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        // Room for a few more, opened between the two calls.
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard used > 0 else { return [] }
        var ports: [Int] = []
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        for descriptor in descriptors.prefix(Int(used) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            // In network byte order, in the low 16 bits.
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if port > 0, !ports.contains(port) { ports.append(port) }
        }
        return ports
    }

    public static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}
