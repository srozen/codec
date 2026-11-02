import Testing
import Foundation
@testable import CodecCore

@Suite("PromptConfiguration")
struct PromptConfigurationTests {
    private func codec(_ change: (inout PromptConfiguration) -> Void = { _ in }) -> PromptConfiguration {
        var configuration = PromptConfiguration.default
        configuration.style = .codec
        change(&configuration)
        return configuration
    }

    private func text(_ runs: [PromptConfiguration.Run]) -> String {
        runs.map(\.text).joined()
    }

    @Test func defaultsToTheUsersOwnPrompt() {
        #expect(PromptConfiguration.default.style == .shell)
        #expect(PromptConfiguration.default.preview().isEmpty)
    }

    @Test func holdsEveryKindExactlyOnce() {
        let configuration = PromptConfiguration(
            style: .codec, layout: .singleLine,
            segments: [.init(.time, enabled: true, color: .red), .init(.time, enabled: false, color: .blue)],
            symbol: "$", separator: " ", directoryStyle: .full, showsGitChanges: false,
            durationThreshold: 1, blankLineBetweenCommands: false)
        #expect(configuration.segments.map(\.kind).sorted { $0.rawValue < $1.rawValue }
                == PromptConfiguration.Kind.allCases.sorted { $0.rawValue < $1.rawValue })
        #expect(configuration.segments.first == .init(.time, enabled: true, color: .red))
        #expect(configuration.enabledSegments.map(\.kind) == [.time])
    }

    @Test func roundTripsThroughJSON() throws {
        let configuration = codec {
            $0.symbol = "λ"
            $0.layout = .singleLine
            $0.segments.reverse()
        }
        let data = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(PromptConfiguration.self, from: data) == configuration)
    }

    @Test func decodesLeniently() throws {
        let partial = #"{"style":"codec","symbol":"→","layout":"sideways"}"#
        let configuration = try JSONDecoder().decode(PromptConfiguration.self, from: Data(partial.utf8))
        #expect(configuration.style == .codec)
        #expect(configuration.symbol == "→")
        #expect(configuration.layout == PromptConfiguration.default.layout)
        #expect(configuration.segments == PromptConfiguration.default.segments)
    }

    // MARK: Preview

    @Test func previewsSegmentsInOrderWithSeparators() {
        let configuration = codec {
            $0.appearance = .text
            $0.layout = .singleLine
            $0.separator = " · "
            $0.segments = [.init(.directory, enabled: true, color: .blue), .init(.gitBranch, enabled: true, color: .magenta)]
        }
        var sample = PromptConfiguration.Sample()
        sample.exitStatus = 0
        #expect(text(configuration.preview(sample)) == "~/code/codec on main* ❯ ")
        #expect(configuration.preview(sample).first?.color == .blue)
        #expect(configuration.preview(sample).dropLast().last == .init(text: "❯", color: .green, bold: true))
    }

    @Test func previewPutsTheSymbolOnItsOwnLineForTwoLines() {
        let configuration = codec { $0.layout = .twoLines }
        #expect(text(configuration.preview()).contains("\n❯ "))
    }

    @Test func previewShowsFailuresAndDurations() {
        let configuration = codec { $0.durationThreshold = 3 }
        var sample = PromptConfiguration.Sample()
        sample.exitStatus = 2
        sample.duration = 3.25
        let failed = text(configuration.preview(sample))
        #expect(failed.contains("✘ 2"))
        #expect(failed.contains("took 3.2s") || failed.contains("took 3.3s"))
        sample.exitStatus = 0
        sample.duration = 2
        let passed = text(configuration.preview(sample))
        #expect(!passed.contains("✘"))
        #expect(!passed.contains("took"))
    }

    @Test(arguments: [(PromptConfiguration.DirectoryStyle.full, "/Users/you/code/codec"), (.home, "~/code/codec"), (.lastFolder, "codec")])
    func previewsDirectoryStyles(style: PromptConfiguration.DirectoryStyle, expected: String) {
        let configuration = codec {
            $0.directoryStyle = style
            $0.segments = [.init(.directory, enabled: true, color: .blue)]
        }
        #expect(configuration.preview().first?.text == expected)
    }

    // MARK: Chips

    private func kinds(_ configuration: PromptConfiguration) -> [PromptConfiguration.Kind] {
        configuration.enabledSegments.map(\.kind)
    }

    @Test func availableKindsAreTheOnesNotInThePrompt() {
        let configuration = codec { $0.segments = [.init(.directory, enabled: true, color: .blue)] }
        #expect(!configuration.availableKinds.contains(.directory))
        #expect(configuration.availableKinds.count == PromptConfiguration.Kind.allCases.count - 1)
    }

    @Test func placingAddsAtTheEndOrBeforeATarget() {
        var configuration = codec { $0.segments = [.init(.directory, enabled: true, color: .blue)] }
        configuration.place(.gitBranch)
        #expect(kinds(configuration) == [.directory, .gitBranch])
        configuration.place(.time, before: .directory)
        #expect(kinds(configuration) == [.time, .directory, .gitBranch])
        configuration.place(.date, before: .jobs) // .jobs isn't in the prompt: goes at the end
        #expect(kinds(configuration) == [.time, .directory, .gitBranch, .date])
    }

    @Test func placingAChipThatsAlreadyInThePromptMovesIt() {
        var configuration = codec {
            $0.segments = [.init(.directory, enabled: true, color: .blue), .init(.gitBranch, enabled: true, color: .magenta),
                           .init(.time, enabled: true, color: .red)]
        }
        configuration.place(.time, before: .directory)
        #expect(kinds(configuration) == [.time, .directory, .gitBranch])
        configuration.place(.time)
        #expect(kinds(configuration) == [.directory, .gitBranch, .time])
        configuration.place(.time, before: .time)
        #expect(kinds(configuration) == [.directory, .gitBranch, .time])
    }

    @Test func removingTakesAChipOutAndKeepsItsColor() {
        var configuration = codec {
            $0.segments = [.init(.directory, enabled: true, color: .blue), .init(.gitBranch, enabled: true, color: .cyan)]
        }
        configuration.remove(.gitBranch)
        #expect(kinds(configuration) == [.directory])
        #expect(configuration.availableKinds.contains(.gitBranch))
        #expect(configuration.color(of: .gitBranch) == .cyan)
        configuration.remove(.gitBranch) // Removing twice is harmless.
        #expect(kinds(configuration) == [.directory])
    }

    @Test func recolorsChips() {
        var configuration = codec()
        configuration.setColor(.red, for: .directory)
        #expect(configuration.color(of: .directory) == .red)
    }

    @Test func chipsAlwaysShowAnExample() {
        let configuration = codec()
        var sample = PromptConfiguration.Sample()
        sample.exitStatus = 0
        sample.duration = 0
        sample.jobs = 0
        #expect(configuration.chipText(.exitStatus, sample) == "exit 1")
        #expect(configuration.chipText(.duration, sample).hasPrefix("took "))
        #expect(configuration.chipText(.jobs, sample) == "1 job")
        #expect(configuration.chipText(.kubernetesContext, sample) == "dev-cluster")
        #expect(configuration.chipText(.gitDiffStats, sample) == "3 • +10 -2")
        for kind in PromptConfiguration.Kind.allCases {
            #expect(!configuration.chipText(kind, sample).isEmpty, "\(kind)")
        }
    }

    @Test func olderSavedPromptsGainNewSegmentsDisabled() throws {
        let saved = #"{"style":"codec","segments":[{"kind":"time","enabled":true,"color":"red"}]}"#
        let configuration = try JSONDecoder().decode(PromptConfiguration.self, from: Data(saved.utf8))
        #expect(kinds(configuration) == [.time])
        #expect(configuration.segments.count == PromptConfiguration.Kind.allCases.count)
        #expect(configuration.segments.contains { $0.kind == .gitDiffStats && !$0.enabled })
    }

    // MARK: zsh

    @Test func shellStyleRestoresTheUsersPrompt() {
        let script = PromptConfiguration.default.zshScript()
        #expect(script.contains("PROMPT=$_codec_user_prompt"))
        #expect(!script.contains("_codec_prompt_render"))
    }

    @Test func codecStyleRendersEnabledSegmentsInOrder() throws {
        let configuration = codec {
            $0.appearance = .text
            $0.segments = [.init(.time, enabled: true, color: .gray), .init(.directory, enabled: true, color: .blue),
                           .init(.userHost, enabled: false, color: .green)]
        }
        let script = configuration.zshScript()
        let time = try #require(script.range(of: #"_codec_prompt_add 8 'at' "%D{%H:%M}" 0 ''"#))
        let directory = try #require(script.range(of: #"_codec_prompt_add 4 '' "%~" 1 ''"#))
        #expect(time.lowerBound < directory.lowerBound)
        #expect(!script.contains("%n@%m"))
        #expect(script.contains("_codec_prompt_render"))
    }

    @Test func quotesTheSymbolAndSeparatorAsSingleWords() {
        let script = codec {
            $0.appearance = .text
            $0.symbol = "%'$"
            $0.separator = " % "
            $0.connectingWords = false
        }.zshScript()
        #expect(script.contains(#"local symbol_text='%%'\''$'"#))
        #expect(script.contains("local joiner='%F{8} %% %f'"))
    }

    /// Regression: `${line:+%F{8} %f}` ended at the `}` of `%F{8}`, and `$'\n'` inside double quotes stayed literal.
    @Test func neverPutsPromptEscapesInsideParameterExpansionsOrNewlinesInQuotes() {
        let script = codec { $0.layout = .twoLines; $0.blankLineBetweenCommands = true }.zshScript()
        #expect(!script.contains(":+%F"))
        // Every $'\n' must sit outside double quotes: an even number of " before it on its line.
        for line in script.split(separator: "\n") where line.contains("$'\\n'") {
            let before = line[..<line.range(of: "$'\\n'")!.lowerBound]
            #expect(before.filter { $0 == "\"" }.count % 2 == 0, "\(line)")
        }
    }

    @Test func connectingWordsReadAsAPhrase() {
        let configuration = codec {
            $0.appearance = .text
            $0.layout = .twoLines
            $0.segments = [.init(.directory, enabled: true, color: .blue), .init(.gitBranch, enabled: true, color: .magenta),
                           .init(.pythonEnvironment, enabled: true, color: .yellow), .init(.duration, enabled: true, color: .yellow)]
        }
        #expect(text(configuration.preview()) == "~/code/codec on main* via venv took 3.2s\n\n❯ ")
        let runs = configuration.preview()
        #expect(runs.first == .init(text: "~/code/codec", color: .blue, bold: true))
        #expect(runs.contains(.init(text: "on ", color: .gray)))
    }

    @Test func withoutConnectingWordsSegmentsUseTheSeparator() {
        let configuration = codec {
            $0.appearance = .text
            $0.layout = .singleLine
            $0.connectingWords = false
            $0.separator = " | "
            $0.segments = [.init(.directory, enabled: true, color: .blue), .init(.gitBranch, enabled: true, color: .magenta),
                           .init(.pythonEnvironment, enabled: true, color: .yellow), .init(.duration, enabled: true, color: .yellow)]
        }
        // Durations keep their word; it's what says what the number is.
        #expect(text(configuration.preview()) == "~/code/codec | main* | (venv) | took 3.2s ❯ ")
    }

    // MARK: Chips

    @Test func chipsAreTheDefaultLook() {
        #expect(PromptConfiguration.default.appearance == .chips)
    }

    @Test func chipsPreviewAsPillsWithTheirMeaningInside() {
        let configuration = codec {
            $0.segments = [.init(.directory, enabled: true, color: .blue), .init(.gitBranch, enabled: true, color: .magenta),
                           .init(.pythonEnvironment, enabled: true, color: .yellow), .init(.duration, enabled: true, color: .yellow),
                           .init(.exitStatus, enabled: true, color: .red)]
        }
        let runs = configuration.preview()
        let pills = runs.filter(\.chip)
        #expect(pills.map(\.text) == ["~/code/codec", "⎇ main*", "venv", "took 3.2s", "✘ 1"])
        #expect(pills.first?.bold == true)
        #expect(!runs.contains { $0.color == .gray }, "chips use no dim connecting words")
        #expect(text(runs) == "~/code/codec ⎇ main* venv took 3.2s ✘ 1\n\n❯ ")
    }

    @Test func leavesAnEmptyLineAboveTheCommandLineUnlessTurnedOff() {
        let spaced = codec { $0.layout = .twoLines; $0.segments = [.init(.directory, enabled: true, color: .blue)] }
        #expect(text(spaced.preview()) == "~/code/codec\n\n❯ ")
        #expect(spaced.zshScript().contains(#"PROMPT="${lead}${line}"$'\n\n'"${symbol} ""#))

        var tight = spaced
        tight.spaceAboveCommandLine = false
        #expect(text(tight.preview()) == "~/code/codec\n❯ ")
        #expect(tight.zshScript().contains(#"PROMPT="${lead}${line}"$'\n'"${symbol} ""#))

        // One line has no command line of its own to space out.
        var oneLine = spaced
        oneLine.layout = .singleLine
        #expect(text(oneLine.preview()) == "~/code/codec ❯ ")
    }

    @Test func savedPromptsWithoutTheOptionGetTheSpace() throws {
        let saved = #"{"style":"codec","layout":"twoLines"}"#
        #expect(try JSONDecoder().decode(PromptConfiguration.self, from: Data(saved.utf8)).spaceAboveCommandLine)
    }

    @Test func chipsUseTheThemeFillOrFallBack() {
        let configuration = codec { $0.segments = [.init(.directory, enabled: true, color: .blue)] }
        #expect(configuration.zshScript(chipFills: [.blue: "#1A2B3C"]).contains(#"_codec_prompt_add 4 '' "%~" 1 '#1a2b3c'"#))
        // Anything but #rrggbb never reaches the script.
        #expect(configuration.zshScript(chipFills: [.blue: "'; rm -rf ~; '"]).contains(#"_codec_prompt_add 4 '' "%~" 1 '0'"#))
        #expect(configuration.zshScript().contains(#"_codec_prompt_add 4 '' "%~" 1 '0'"#))
    }

    // MARK: Panel

    @Test func panelTagsSegmentsInsideCornersWithLCDReadouts() {
        let configuration = codec {
            $0.appearance = .panel
            $0.segments = [.init(.directory, enabled: true, color: .blue), .init(.gitBranch, enabled: true, color: .magenta),
                           .init(.duration, enabled: true, color: .yellow), .init(.exitStatus, enabled: true, color: .red),
                           .init(.jobs, enabled: true, color: .cyan)]
        }
        let runs = configuration.preview()
        #expect(text(runs) == "⌈ LOC ~/code/codec │ BR main* │ T+ 🯳.🯲s │ EXIT 🯱 │ JOBS 🯱 ⌋\n\n❯ ")
        #expect(runs.filter(\.tag).map(\.text) == ["LOC", "BR", "T+", "EXIT", "JOBS"])
        #expect(runs.filter(\.tag).map(\.color) == [.blue, .magenta, .yellow, .red, .cyan])
        #expect(runs.filter(\.frame).map(\.text) == ["⌈", " │ ", " │ ", " │ ", " │ ", "⌋"])
        #expect(runs.allSatisfy { !$0.chip })
    }

    @Test func panelKeepsDigitsInNames() {
        var sample = PromptConfiguration.Sample()
        sample.directory = "/Users/you/code/k8s-2"
        sample.kubernetesContext = "prod-3"
        let configuration = codec {
            $0.appearance = .panel
            $0.layout = .singleLine
            $0.segments = [.init(.directory, enabled: true, color: .blue), .init(.kubernetesContext, enabled: true, color: .cyan)]
        }
        #expect(text(configuration.preview(sample)) == "⌈ LOC ~/code/k8s-2 │ K8S prod-3 ⌋ ❯ ")
    }

    @Test func lcdTurnsOnlyASCIIDigitsIntoLCDDigits() {
        #expect(PromptConfiguration.lcd("09:05") == "🯰🯹:🯰🯵")
        #expect(PromptConfiguration.lcd("Nov ٣ 2") == "Nov ٣ 🯲")
    }

    @Test func panelUsesTheThemeFrameAndTagColorsOrFallsBack() {
        let configuration = codec { $0.appearance = .panel; $0.segments = [.init(.directory, enabled: true, color: .blue)] }
        let themed = configuration.zshScript(tagColors: [.blue: "#1A2B3C"], frameColor: "#2E875A")
        #expect(themed.contains(#"_codec_prompt_tag 4 '#1a2b3c' 'LOC' "%~" 1"#))
        #expect(themed.contains(#"line="%F{#2e875a}⌈%f ${line} %F{#2e875a}⌋%f""#))
        #expect(themed.contains("local joiner=' %F{#2e875a}│%f '"))
        let plain = configuration.zshScript(tagColors: [.blue: "red"], frameColor: "'; rm -rf ~; '")
        #expect(plain.contains(#"_codec_prompt_tag 4 '8' 'LOC' "%~" 1"#))
        #expect(plain.contains("%F{8}⌈%f"))
        #expect(!plain.contains("rm -rf"))
        // Only the panel carries its helpers.
        #expect(!codec().zshScript().contains("_codec_prompt_lcd"))
    }

    /// zsh doesn't know the LCD digits are one column wide, which would put the cursor in the wrong place.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")), arguments: [true, false])
    func panelRendersInZsh(utf8: Bool) throws {
        let temp = try TemporaryDirectory()
        let configuration = codec {
            $0.appearance = .panel
            $0.segments = [.init(.duration, enabled: true, color: .yellow), .init(.exitStatus, enabled: true, color: .red),
                           .init(.time, enabled: true, color: .gray)]
        }
        let file = try temp.file("prompt.zsh", configuration.zshScript(tagColors: [.yellow: "#302010"], frameColor: "#2e875a"))
        let zsh = Process()
        zsh.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        zsh.arguments = ["-i", "HOME=\(temp.url.path)"] + (utf8 ? ["LC_ALL=en_US.UTF-8"] : []) + ["/bin/zsh", "-fc",
                         "typeset -gi _codec_last_status=3; typeset -gF _codec_last_duration=12.46; source \"$1\"; print -rn -- \"$PROMPT\"",
                         "zsh", file.path]
        let output = Pipe(), errors = Pipe()
        zsh.standardOutput = output
        zsh.standardError = errors
        try zsh.run()
        zsh.waitUntilExit()
        let prompt = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let complaints = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(zsh.terminationStatus == 0)
        #expect(complaints.isEmpty, "\(complaints)")
        #expect(prompt.contains("%F{#302010}T+%f %F{3}%{🯱%1G%}%{🯲%1G%}.%{🯵%1G%}s%f"), "\(prompt)")
        #expect(prompt.contains("EXIT%f %F{1}%{🯳%1G%}%f"), "\(prompt)")
        #expect(prompt.contains("TIME%f %F{8}%{"), "\(prompt)")
        #expect(prompt.hasPrefix("%F{#2e875a}⌈%f "))
    }

    /// Regression: `$'\ue0b6'` escapes failed with "character not in range" outside a UTF-8 locale.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
    func rendersWithoutAUTF8Locale() throws {
        let temp = try TemporaryDirectory()
        let file = try temp.file("prompt.zsh", codec().zshScript(chipFills: [.blue: "#102030"]))
        let zsh = Process()
        zsh.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        zsh.arguments = ["-i", "HOME=\(temp.url.path)", "/bin/zsh", "-fc",
                         "typeset -gi _codec_last_status=1; typeset -gF _codec_last_duration=0; source \"$1\"; print -rn -- \"${(%)PROMPT}\"",
                         "zsh", file.path]
        let output = Pipe(), errors = Pipe()
        zsh.standardOutput = output
        zsh.standardError = errors
        try zsh.run()
        zsh.waitUntilExit()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let complaints = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(zsh.terminationStatus == 0)
        #expect(complaints.isEmpty, "\(complaints)")
        #expect(printed.contains("\u{E0B6}") && printed.contains("✘ 1"))
    }

    /// Every combination of options must produce valid zsh.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
    func generatesValidZsh() throws {
        let temp = try TemporaryDirectory()
        var configurations = [PromptConfiguration.default]
        for layout in PromptConfiguration.Layout.allCases {
            for directory in PromptConfiguration.DirectoryStyle.allCases {
                for appearance in PromptConfiguration.Appearance.allCases {
                configurations.append(codec {
                    $0.appearance = appearance
                    $0.layout = layout
                    $0.directoryStyle = directory
                    $0.segments = $0.segments.map { var s = $0; s.enabled = true; return s }
                    $0.showsGitChanges.toggle()
                    $0.blankLineBetweenCommands.toggle()
                    $0.symbol = "%$\"`"
                    $0.separator = " | "
                })
                }
            }
        }
        for (index, configuration) in configurations.enumerated() {
            let file = try temp.file("prompt-\(index).zsh", configuration.zshScript(chipFills: [.blue: "#102030"]))
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/bin/zsh")
            check.arguments = ["-n", file.path]
            let errors = Pipe()
            check.standardError = errors
            try check.run()
            check.waitUntilExit()
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(check.terminationStatus == 0, "configuration \(index): \(message)")
        }
    }
}
