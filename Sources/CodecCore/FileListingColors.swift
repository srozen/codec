import Foundation

/// Colors for file listings in the shell: macOS's `ls` (through `CLICOLOR` and `LSCOLORS`), and eza,
/// GNU `ls` and zsh's completion lists (through `LS_COLORS`).
///
/// Files take the colors their icons have in the file tree. They're named as terminal colors, so a
/// listing follows the theme, even one printed before the theme changed. Only the accent, which isn't
/// one of the 16, is given as 24-bit color.
public enum FileListingColors {
    /// For macOS's `ls`: folders bold blue, links cyan, sockets magenta, pipes yellow, executables
    /// green, then the system's defaults for devices and special permissions.
    public static let bsd = "Exgxfxdxcxegedabagacad"

    /// The same kinds for `LS_COLORS`, which can also give folders the brighter blue.
    static let kinds = "di=01;94:ln=36:so=35:pi=33:ex=32:bd=34;46:cd=34;43:su=30;41:sg=30;46:tw=30;42:ow=30;43:or=31:mi=31"

    /// `LS_COLORS`: the kinds of file, then each extension Codec knows in its type's color.
    /// `accent` is the theme's accent as SGR parameters (`38;2;r;g;b`); without it, types in the
    /// accent are left plain.
    public static func gnu(accent: String?) -> String {
        var entries = [kinds]
        for type in FileType.allCases {
            guard let sgr = sgr(for: type.color, accent: accent) else { continue }
            entries += type.extensions.map { "*.\($0)=\(sgr)" }
        }
        return entries.joined(separator: ":")
    }

    /// SGR parameters for a palette color: the terminal color itself, or for a neutral, plain text
    /// unless it's muted enough to read as gray.
    static func sgr(for color: FileColor, accent: String?) -> String? {
        switch color {
        case .ansi(let index) where (0..<8).contains(index): "3\(index)"
        case .ansi(let index) where (8..<16).contains(index): "9\(index - 8)"
        case .ansi: nil
        case .accent: accent
        case .neutral(let amount): amount < 0.6 ? "90" : nil
        }
    }

    /// `environment` with listings in color: `CLICOLOR`, `LSCOLORS` and `LS_COLORS`, each unless it's
    /// already set. The user's startup files run later, so what they set wins too.
    public static func environment(_ environment: [String: String], accent: String?) -> [String: String] {
        var result = environment
        if result["CLICOLOR"] == nil { result["CLICOLOR"] = "1" }
        if result["LSCOLORS"] == nil { result["LSCOLORS"] = bsd }
        if result["LS_COLORS"] == nil { result["LS_COLORS"] = gnu(accent: accent) }
        return result
    }
}
