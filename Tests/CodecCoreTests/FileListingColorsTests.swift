import Testing
@testable import CodecCore

@Suite("File listing colors")
struct FileListingColorsTests {
    private func entries(accent: String? = "38;2;1;2;3") -> [String: String] {
        Dictionary(FileListingColors.gnu(accent: accent).split(separator: ":").map { entry in
            let parts = entry.split(separator: "=", maxSplits: 1)
            return (String(parts[0]), String(parts[1]))
        }, uniquingKeysWith: { _, new in new })
    }

    /// The terminal's colors, so a listing follows the theme: 0–7 are 30–37, the bright ones 90–97.
    @Test func namesTerminalColors() {
        #expect(FileListingColors.sgr(for: .ansi(1), accent: nil) == "31")
        #expect(FileListingColors.sgr(for: .ansi(9), accent: nil) == "91")
        #expect(FileListingColors.sgr(for: .ansi(15), accent: nil) == "97")
        #expect(FileListingColors.sgr(for: .accent, accent: "38;2;1;2;3") == "38;2;1;2;3")
        #expect(FileListingColors.sgr(for: .accent, accent: nil) == nil)
        #expect(FileListingColors.sgr(for: .neutral(0.45), accent: nil) == "90")
        #expect(FileListingColors.sgr(for: .neutral(0.62), accent: nil) == nil)
    }

    /// Files take their icon's color from the file tree.
    @Test func colorsFilesAsTheFileTreeDoes() {
        let colors = entries()
        #expect(colors["*.swift"] == "91")
        #expect(colors["*.md"] == "94")
        #expect(colors["*.json"] == "33")
        #expect(colors["*.zip"] == "33")
        #expect(colors["*.sh"] == "38;2;1;2;3")
        #expect(colors["*.log"] == "90")
        #expect(colors["*.lock"] == "90")
        // Plain text stays plain.
        #expect(colors["*.txt"] == nil)
        #expect(entries(accent: nil)["*.sh"] == nil)
    }

    @Test func colorsKindsOfFile() {
        let colors = entries()
        #expect(colors["di"] == "01;94")
        #expect(colors["ln"] == "36")
        #expect(colors["ex"] == "32")
        #expect(FileListingColors.bsd.count == 22)
        #expect(FileListingColors.bsd.hasPrefix("Exgx"))
    }

    @Test func fillsInOnlyWhatIsntSet() {
        let fresh = FileListingColors.environment(["PATH": "/bin"], accent: nil)
        #expect(fresh["CLICOLOR"] == "1")
        #expect(fresh["LSCOLORS"] == FileListingColors.bsd)
        #expect(fresh["LS_COLORS"] == FileListingColors.gnu(accent: nil))
        #expect(fresh["PATH"] == "/bin")

        let own = FileListingColors.environment(["CLICOLOR": "", "LSCOLORS": "exfxcxdxbxegedabagacad", "LS_COLORS": "di=31"], accent: nil)
        #expect(own["CLICOLOR"] == "")
        #expect(own["LSCOLORS"] == "exfxcxdxbxegedabagacad")
        #expect(own["LS_COLORS"] == "di=31")
    }
}

@Suite("eza")
struct EzaTests {
    @Test func looksWhereHomebrewAndCargoPutIt() {
        #expect(Eza.isInstalled(home: "/Users/me") { $0 == "/opt/homebrew/bin/eza" })
        #expect(Eza.isInstalled(home: "/Users/me") { $0 == "/usr/local/bin/eza" })
        #expect(Eza.isInstalled(home: "/Users/me") { $0 == "/Users/me/.cargo/bin/eza" })
        #expect(!Eza.isInstalled(home: "/Users/me") { _ in false })
    }

    /// Homebrew by its full path, which works even where the shell's PATH lacks it; nil without it.
    @Test func installsWithHomebrewWhereThereIsOne() {
        #expect(Eza.installCommand { $0 == "/opt/homebrew/bin/brew" } == "/opt/homebrew/bin/brew install eza")
        #expect(Eza.installCommand { $0 == "/usr/local/bin/brew" } == "/usr/local/bin/brew install eza")
        #expect(Eza.installCommand { _ in false } == nil)
    }
}
