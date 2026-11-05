import Foundation

/// eza, the `ls` Codec can run with icons: whether it's installed, and how to install it.
public enum Eza {
    /// Where Homebrew (on Apple silicon and on Intel) and Cargo put eza. The shell may find it
    /// elsewhere on its PATH, so this only decides whether Settings offers to install it.
    static func locations(home: String) -> [String] {
        ["/opt/homebrew/bin/eza", "/usr/local/bin/eza", home + "/.cargo/bin/eza"]
    }

    static let homebrews = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    /// eza's own instructions, for a Mac without Homebrew.
    public static let instructions = URL(string: "https://github.com/eza-community/eza/blob/main/INSTALL.md")!

    public static func isInstalled(home: String = NSHomeDirectory(),
                                   isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Bool {
        locations(home: home).contains(where: isExecutable)
    }

    /// The command that installs eza with Homebrew, or nil without Homebrew. It names Homebrew by its
    /// full path, so it runs even from a shell whose PATH doesn't include it.
    public static func installCommand(isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        homebrews.first(where: isExecutable).map { "\($0) install eza" }
    }
}
