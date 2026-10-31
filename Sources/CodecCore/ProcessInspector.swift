import Darwin

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

    public static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}
