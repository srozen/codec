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

    /// "“make”", "“make” and “npm”", "“make”, “npm” and “ssh”".
    public static func list(_ names: [String]) -> String {
        let quoted = names.map { "“\($0)”" }
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

    public static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}
