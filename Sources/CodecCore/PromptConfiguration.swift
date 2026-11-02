import Foundation

/// A Warp-style prompt built from segments, rendered by Codec's zsh integration.
///
/// The same configuration produces the zsh code (`zshScript()`) and the Settings preview
/// (`preview(_:)`), so the two always agree on order, text and colors.
public struct PromptConfiguration: Codable, Equatable, Sendable {
    public enum Style: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Leave the prompt to the user's shell configuration.
        case shell
        /// Codec builds the prompt from `segments`.
        case codec
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .shell: "Shell prompt (from your zsh configuration)"
            case .codec: "Codec prompt"
            }
        }
    }

    public enum Layout: String, Codable, CaseIterable, Identifiable, Sendable {
        case singleLine, twoLines
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .singleLine: "Same line as the command"
            case .twoLines: "Context above the command"
            }
        }
    }

    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case directory, gitBranch, gitDiffStats, userHost, time, date, pythonEnvironment, kubernetesContext,
             duration, exitStatus, jobs
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .directory: "Working directory"
            case .gitBranch: "Git branch"
            case .gitDiffStats: "Git changes"
            case .userHost: "User and host"
            case .time: "Time"
            case .date: "Date"
            case .pythonEnvironment: "Python environment"
            case .kubernetesContext: "Kubernetes context"
            case .duration: "Command duration"
            case .exitStatus: "Exit status"
            case .jobs: "Background jobs"
            }
        }
        /// The dim word that leads into the value when connecting words are on. Durations always keep
        /// theirs, since "3.2s" alone doesn't say what it measures.
        public var connector: String? {
            switch self {
            case .gitBranch: "on"
            case .pythonEnvironment: "via"
            case .kubernetesContext: "in"
            case .duration: "took"
            case .time: "at"
            case .jobs: "with"
            default: nil
            }
        }

        /// The short tag before the segment in the panel appearance.
        public var tag: String {
            switch self {
            case .directory: "LOC"
            case .gitBranch: "BR"
            case .gitDiffStats: "DIFF"
            case .userHost: "ID"
            case .time: "TIME"
            case .date: "DATE"
            case .pythonEnvironment: "PY"
            case .kubernetesContext: "K8S"
            case .duration: "T+"
            case .exitStatus: "EXIT"
            case .jobs: "JOBS"
            }
        }

        /// A reading whose digits the panel shows as LCD digits. Names keep their own digits.
        public var isReadout: Bool {
            switch self {
            case .gitDiffStats, .time, .date, .duration, .exitStatus, .jobs: true
            case .directory, .gitBranch, .userHost, .pythonEnvironment, .kubernetesContext: false
            }
        }

        public var systemImage: String {
            switch self {
            case .directory: "folder"
            case .gitBranch: "arrow.triangle.branch"
            case .gitDiffStats: "doc.badge.plus"
            case .userHost: "person"
            case .time: "clock"
            case .date: "calendar"
            case .pythonEnvironment: "shippingbox"
            case .kubernetesContext: "helm"
            case .duration: "stopwatch"
            case .exitStatus: "exclamationmark.circle"
            case .jobs: "square.stack.3d.up"
            }
        }
    }

    /// The 16 terminal colors, so prompts follow the theme.
    public enum Color: String, Codable, CaseIterable, Identifiable, Sendable {
        case red, green, yellow, blue, magenta, cyan, white, gray
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
        public var ansiIndex: Int {
            switch self {
            case .red: 1
            case .green: 2
            case .yellow: 3
            case .blue: 4
            case .magenta: 5
            case .cyan: 6
            case .white: 7
            case .gray: 8
            }
        }
    }

    /// How segments are drawn in the terminal.
    public enum Appearance: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Tinted, rounded pills, like the chips in Codec's status bar.
        case chips
        /// Colored words that read as a phrase.
        case text
        /// One bracketed panel, like a codec screen: each segment behind a short tag (`LOC`, `BR`, `T+`),
        /// numbers in LCD digits, segments split by bars.
        case panel
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .chips: "Chips"
            case .text: "Text"
            case .panel: "Panel"
            }
        }
    }

    public enum DirectoryStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        case full, home, lastFolder
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .full: "Full path"
            case .home: "Path from ~"
            case .lastFolder: "Folder name"
            }
        }
    }

    public struct Segment: Codable, Equatable, Identifiable, Sendable {
        public var kind: Kind
        public var enabled: Bool
        public var color: Color
        public var id: Kind { kind }

        public init(_ kind: Kind, enabled: Bool, color: Color) {
            self.kind = kind
            self.enabled = enabled
            self.color = color
        }
    }

    public var style: Style
    public var layout: Layout
    /// In display order. Holds every kind exactly once, whatever is assigned; `enabled` says which are shown.
    public var segments: [Segment] {
        didSet {
            let normalized = Self.normalized(segments)
            if normalized != segments { segments = normalized }
        }
    }
    public var symbol: String
    public var separator: String
    public var directoryStyle: DirectoryStyle
    /// Adds `*` to the branch when the working tree has uncommitted changes.
    public var showsGitChanges: Bool
    /// Commands shorter than this don't show a duration.
    public var durationThreshold: Double
    /// An empty line before each prompt, to set commands apart.
    public var blankLineBetweenCommands: Bool
    /// Joins segments with short dim words ("on main", "via venv", "took 3.2s") instead of `separator`.
    public var connectingWords: Bool
    public var appearance: Appearance
    /// With two lines, an empty line between the segments and the command line, so they don't crowd it.
    public var spaceAboveCommandLine: Bool

    public init(style: Style, layout: Layout, segments: [Segment], symbol: String, separator: String,
                directoryStyle: DirectoryStyle, showsGitChanges: Bool, durationThreshold: Double,
                blankLineBetweenCommands: Bool, connectingWords: Bool = true, appearance: Appearance = .chips,
                spaceAboveCommandLine: Bool = true) {
        self.style = style
        self.layout = layout
        self.segments = Self.normalized(segments)
        self.symbol = symbol
        self.separator = separator
        self.directoryStyle = directoryStyle
        self.showsGitChanges = showsGitChanges
        self.durationThreshold = durationThreshold
        self.blankLineBetweenCommands = blankLineBetweenCommands
        self.connectingWords = connectingWords
        self.appearance = appearance
        self.spaceAboveCommandLine = spaceAboveCommandLine
    }

    public static let `default` = PromptConfiguration(
        style: .shell,
        layout: .twoLines,
        segments: [
            Segment(.directory, enabled: true, color: .blue),
            Segment(.gitBranch, enabled: true, color: .magenta),
            Segment(.pythonEnvironment, enabled: true, color: .yellow),
            Segment(.kubernetesContext, enabled: false, color: .cyan),
            Segment(.duration, enabled: true, color: .yellow),
            Segment(.jobs, enabled: true, color: .cyan),
            Segment(.exitStatus, enabled: true, color: .red),
            Segment(.gitDiffStats, enabled: false, color: .green),
            Segment(.userHost, enabled: false, color: .green),
            Segment(.time, enabled: false, color: .white),
            Segment(.date, enabled: false, color: .green),
        ],
        symbol: "❯",
        separator: " ",
        directoryStyle: .home,
        showsGitChanges: true,
        durationThreshold: 2,
        blankLineBetweenCommands: true,
        connectingWords: true,
        appearance: .chips,
        spaceAboveCommandLine: true)

    public static let symbolChoices = ["❯", "$", "%", "→", "λ", "▶", "#"]
    public static let separatorChoices = [" ", " · ", " | ", " / "]

    /// Every kind exactly once, keeping the given order and appending missing kinds, disabled.
    static func normalized(_ segments: [Segment]) -> [Segment] {
        var seen = Set<Kind>()
        var result = segments.filter { seen.insert($0.kind).inserted }
        for kind in Kind.allCases where !seen.contains(kind) {
            result.append(Segment(kind, enabled: false, color: Self.default.color(for: kind)))
        }
        return result
    }

    private func color(for kind: Kind) -> Color {
        segments.first { $0.kind == kind }?.color ?? .white
    }

    public var enabledSegments: [Segment] { segments.filter(\.enabled) }

    // MARK: Editing, as chips

    /// Kinds that can still be added to the prompt, in a stable order.
    public var availableKinds: [Kind] {
        Kind.allCases.filter { kind in !enabledSegments.contains { $0.kind == kind } }
    }

    /// Adds `kind` to the prompt, or moves it if it's already there, placing it before `target`
    /// (or at the end when `target` is nil or not in the prompt).
    public mutating func place(_ kind: Kind, before target: Kind? = nil) {
        // Work on a copy and assign once, so normalization never sees a half-edited list.
        var list = segments
        guard kind != target, let index = list.firstIndex(where: { $0.kind == kind }) else { return }
        var segment = list.remove(at: index)
        segment.enabled = true
        let destination = target.flatMap { target in
            list.firstIndex { $0.kind == target && $0.enabled }
        } ?? list.lastIndex(where: \.enabled).map { $0 + 1 } ?? 0
        list.insert(segment, at: destination)
        segments = list
    }

    /// Takes `kind` out of the prompt.
    public mutating func remove(_ kind: Kind) {
        var list = segments
        guard let index = list.firstIndex(where: { $0.kind == kind && $0.enabled }) else { return }
        var segment = list.remove(at: index)
        segment.enabled = false
        list.append(segment)
        segments = list
    }

    public mutating func setColor(_ color: Color, for kind: Kind) {
        guard let index = segments.firstIndex(where: { $0.kind == kind }) else { return }
        segments[index].color = color
    }

    public func color(of kind: Kind) -> Color {
        segments.first { $0.kind == kind }?.color ?? .white
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case style, layout, segments, symbol, separator, directoryStyle, showsGitChanges, durationThreshold,
             blankLineBetweenCommands, connectingWords, appearance, spaceAboveCommandLine
    }

    /// Decodes leniently: anything missing or unknown falls back to the default.
    public init(from decoder: Decoder) throws {
        let fallback = Self.default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ defaultValue: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? defaultValue
        }
        self.init(style: value(.style, fallback.style),
                  layout: value(.layout, fallback.layout),
                  segments: value(.segments, fallback.segments),
                  symbol: value(.symbol, fallback.symbol),
                  separator: value(.separator, fallback.separator),
                  directoryStyle: value(.directoryStyle, fallback.directoryStyle),
                  showsGitChanges: value(.showsGitChanges, fallback.showsGitChanges),
                  durationThreshold: value(.durationThreshold, fallback.durationThreshold),
                  blankLineBetweenCommands: value(.blankLineBetweenCommands, fallback.blankLineBetweenCommands),
                  connectingWords: value(.connectingWords, fallback.connectingWords),
                  appearance: value(.appearance, fallback.appearance),
                  spaceAboveCommandLine: value(.spaceAboveCommandLine, fallback.spaceAboveCommandLine))
    }
}

// MARK: - Preview

extension PromptConfiguration {
    /// Example values for the Settings preview.
    public struct Sample: Sendable {
        public var directory = "/Users/you/code/codec"
        public var home = "/Users/you"
        public var branch: String? = "main"
        public var hasChanges = true
        public var user = "you"
        public var host = "mac"
        public var time = "14:05"
        public var date = "Jul 12"
        public var diffStats: (files: Int, insertions: Int, deletions: Int)? = (3, 10, 2)
        public var pythonEnvironment: String? = "venv"
        public var kubernetesContext: String? = "dev-cluster"
        public var duration: Double = 3.2
        public var exitStatus: Int32 = 1
        public var jobs = 1
        public init() {}
    }

    public struct Run: Equatable, Sendable {
        public var text: String
        /// Nil for plain text in the terminal's foreground color.
        public var color: Color?
        public var bold: Bool
        /// Drawn as a tinted pill (the chips appearance).
        public var chip: Bool
        /// A panel tag, drawn in a dimmed `color`.
        public var tag: Bool
        /// The panel's corners and bars, drawn in the theme's frame color rather than `color`.
        public var frame: Bool

        public init(text: String, color: Color?, bold: Bool = false, chip: Bool = false, tag: Bool = false,
                    frame: Bool = false) {
            self.text = text
            self.color = color
            self.bold = bold
            self.chip = chip
            self.tag = tag
            self.frame = frame
        }
    }

    /// The panel's corners, which Codec draws at the edges of their cells.
    public static let panelCorners: (open: Character, close: Character) = ("⌈", "⌋")
    public static let panelBar: Character = "│"
    /// U+1FBF0–U+1FBF9, the segmented digits zero to nine, which Codec draws as LCD digits.
    public static let lcdDigits: [Character] = (0x1FBF0...0x1FBF9).map { Character(Unicode.Scalar($0)!) }

    /// `text` with its digits 0–9 as LCD digits.
    public static func lcd(_ text: String) -> String {
        String(text.map { character in
            character.wholeNumberValue.flatMap { character.isASCII ? lcdDigits[$0] : nil } ?? character
        })
    }

    /// The prompt as colored runs of text, exactly as zsh draws it for `sample` (without the blank
    /// line between commands). Empty for the shell style.
    public func preview(_ sample: Sample = Sample()) -> [Run] {
        guard style == .codec else { return [] }
        var runs: [Run] = []
        for segment in enabledSegments {
            guard let value = value(segment.kind, sample) else { continue }
            if !runs.isEmpty { runs.append(joiner) }
            if let connector = connector(for: segment.kind) {
                runs.append(Run(text: connector + " ", color: .gray))
            }
            if appearance == .panel {
                runs.append(Run(text: segment.kind.tag, color: segment.color, tag: true))
                runs.append(Run(text: " ", color: nil))
            }
            let shown = appearance == .panel && segment.kind.isReadout ? Self.lcd(value) : value
            runs.append(Run(text: shown, color: segment.color, bold: segment.kind == .directory,
                            chip: appearance == .chips))
        }
        if appearance == .panel, !runs.isEmpty {
            runs.insert(contentsOf: [Run(text: String(Self.panelCorners.open), color: nil, frame: true),
                                     Run(text: " ", color: nil)], at: 0)
            runs += [Run(text: " ", color: nil), Run(text: String(Self.panelCorners.close), color: nil, frame: true)]
        }
        if !runs.isEmpty {
            switch layout {
            case .singleLine:
                runs.append(Run(text: " ", color: nil))
            case .twoLines:
                runs.append(Run(text: "\n", color: nil))
                if spaceAboveCommandLine { runs.append(Run(text: "\n", color: nil)) }
            }
        }
        runs.append(Run(text: symbol, color: sample.exitStatus == 0 ? .green : .red, bold: true))
        runs.append(Run(text: " ", color: nil))
        return runs
    }

    /// Between two segments: a space before a connecting word, else the separator. The panel uses its bar.
    private var joiner: Run {
        switch appearance {
        case .panel: Run(text: " \(Self.panelBar) ", color: nil, frame: true)
        case .chips: Run(text: " ", color: nil)
        case .text: connectingWords ? Run(text: " ", color: nil) : Run(text: separator, color: .gray)
        }
    }

    /// The dim word before a segment, if any. Chips carry their meaning inside the pill instead.
    private func connector(for kind: Kind) -> String? {
        guard appearance == .text else { return nil }
        return connectingWords || kind == .duration ? kind.connector : nil
    }

    /// What a segment looks like with the sample's values, as shown on its chip. Unlike the preview,
    /// conditional segments (exit status, duration, jobs) always show an example.
    public func chipText(_ kind: Kind, _ sample: Sample = Sample()) -> String {
        var always = sample
        always.exitStatus = always.exitStatus == 0 ? 1 : always.exitStatus
        always.duration = max(always.duration, durationThreshold, 0.1)
        always.jobs = max(always.jobs, 1)
        // Chips have their own icon, so drop the glyph the terminal prompt uses instead.
        switch kind {
        case .exitStatus: return "exit \(always.exitStatus)"
        case .jobs: return "\(always.jobs) job\(always.jobs == 1 ? "" : "s")"
        case .kubernetesContext: return always.kubernetesContext ?? kind.label
        case .duration: return "took " + String(format: "%.1fs", always.duration)
        case .gitBranch: return always.branch.map { $0 + (showsGitChanges && always.hasChanges ? "*" : "") } ?? kind.label
        default: return value(kind, always) ?? kind.label
        }
    }

    /// A segment's value for `sample`, without its connecting word; nil when it has nothing to show.
    private func value(_ kind: Kind, _ sample: Sample) -> String? {
        switch kind {
        case .directory:
            switch directoryStyle {
            case .full: return sample.directory
            case .home:
                return sample.directory.hasPrefix(sample.home)
                    ? "~" + sample.directory.dropFirst(sample.home.count) : sample.directory
            case .lastFolder: return (sample.directory as NSString).lastPathComponent
            }
        case .gitBranch:
            return sample.branch.map { (appearance == .chips ? "⎇ " : "") + $0 + (showsGitChanges && sample.hasChanges ? "*" : "") }
        case .gitDiffStats:
            return sample.diffStats.map { "\($0.files) • +\($0.insertions) -\($0.deletions)" }
        case .userHost: return "\(sample.user)@\(sample.host)"
        case .time: return sample.time
        case .date: return sample.date
        case .pythonEnvironment:
            return sample.pythonEnvironment.map { appearance != .text || connectingWords ? $0 : "(\($0))" }
        case .kubernetesContext:
            return sample.kubernetesContext.map { (appearance == .panel ? "" : "⎈ ") + $0 }
        case .duration:
            guard sample.duration >= durationThreshold else { return nil }
            return (appearance == .chips ? "took " : "") + String(format: "%.1fs", sample.duration)
        case .exitStatus:
            // The panel's tag says what the number is.
            guard sample.exitStatus != 0 else { return nil }
            return appearance == .panel ? "\(sample.exitStatus)" : "✘ \(sample.exitStatus)"
        case .jobs:
            guard sample.jobs > 0 else { return nil }
            return appearance == .panel ? "\(sample.jobs)" : "\(sample.jobs) job\(sample.jobs == 1 ? "" : "s")"
        }
    }
}

// MARK: - zsh

extension PromptConfiguration {
    /// Code the integration sources before every prompt. For the codec style it saves the user's own
    /// prompt once and sets PROMPT; for the shell style it puts the user's prompt back if Codec had replaced it.
    ///
    /// The integration provides `_codec_last_status` and `_codec_last_duration` (zero when no command ran).
    /// Fixed text goes into single-quoted strings and newlines are written as `$'\n'` outside double
    /// quotes, so no character the user picks can change how zsh parses the script.
    ///
    /// `chipFills` gives each segment color's pill background as `#rrggbb`, derived from the theme;
    /// `tagColors` each color's dimmed panel tag, and `frameColor` the panel's corners and bars.
    public func zshScript(chipFills: [Color: String] = [:], tagColors: [Color: String] = [:],
                          frameColor: String? = nil) -> String {
        guard style == .codec else {
            return """
            # Generated by Codec: your own prompt is in use.
            if (( ${_codec_prompt_overridden:-0} )); then
              PROMPT=$_codec_user_prompt
              RPROMPT=$_codec_user_rprompt
              _codec_prompt_overridden=0
            fi

            """
        }
        let frame = frameColor.flatMap(Self.validHex) ?? "8"
        let joiner = switch appearance {
        case .panel: " %F{\(frame)}\(Self.panelBar)%f "
        case .chips: " "
        case .text: connectingWords ? " " : "%F{8}" + Self.promptEscaped(separator) + "%f"
        }
        var lines = [
            "# Generated by Codec from Settings › Prompt. Edits are overwritten.",
            "if (( ! ${_codec_prompt_overridden:-0} )); then",
            "  typeset -g _codec_user_prompt=$PROMPT _codec_user_rprompt=$RPROMPT",
            "  typeset -g _codec_prompt_overridden=1",
            "fi",
            "# Makes a value safe to put in PROMPT: % is a prompt escape, and with prompt_subst set",
            "# zsh would also run $(...) and `...` found in a branch or environment name.",
            "_codec_prompt_escape() {",
            "  REPLY=${1//\\%/%%}",
            "  if [[ -o prompt_subst ]]; then",
            "    REPLY=${REPLY//\\\\/\\\\\\\\}",
            "    REPLY=${REPLY//\\$/\\\\\\$}",
            "    REPLY=${REPLY//\\`/\\\\\\`}",
            "  fi",
            "}",
            "# Adds a segment to the caller's parts: color, connecting word ('' for none), prompt-safe value,",
            "# bold (0 or 1), and a pill fill (#rrggbb, or '' for plain text). Pills are drawn with the rounded",
            "# half-circles U+E0B6 and U+E0B4, which Codec renders itself in any font.",
            "_codec_prompt_add() {",
            "  local part='' text=\"%F{$1}$3%f\"",
            "  (( $4 )) && text=\"%B${text}%b\"",
            "  if [[ -n $5 ]]; then",
            // Literal characters rather than $'\u…' escapes, which zsh can't evaluate outside a UTF-8 locale.
            "    local left='\u{E0B6}' right='\u{E0B4}'",
            "    part=\"%F{$5}${left}%K{$5} ${text} %k%F{$5}${right}%f\"",
            "  else",
            "    [[ -n $2 ]] && part=\"%F{8}$2%f \"",
            "    part+=$text",
            "  fi",
            "  parts+=(\"$part\")",
            "}",
        ]
        if appearance == .panel {
            lines += [
                "# Adds a panel segment: color, tag color (#rrggbb or 8), tag, prompt-safe value, bold (0 or 1).",
                "_codec_prompt_tag() {",
                "  local text=\"%F{$1}$4%f\"",
                "  (( $5 )) && text=\"%B${text}%b\"",
                "  parts+=(\"%F{$2}$3%f ${text}\")",
                "}",
                "# Makes a reading prompt-safe with its digits as LCD digits (U+1FBF0–U+1FBF9), which Codec draws",
                "# itself. zsh doesn't know they're one column wide, so each says so with %{…%1G%}.",
                "_codec_prompt_lcd() {",
                "  _codec_prompt_escape $1",
                "  local -a digits=(\(Self.lcdDigits.map(String.init).joined(separator: " ")))",
                "  local reading=$REPLY c i",
                "  REPLY=''",
                "  for (( i = 1; i <= ${#reading}; i++ )); do",
                "    c=${reading[i]}",
                "    if [[ $c == [0-9] ]]; then REPLY+=\"%{${digits[c+1]}%1G%}\"; else REPLY+=$c; fi",
                "  done",
                "}",
            ]
        }
        lines += [
            "_codec_prompt_render() {",
            "  local -a parts",
            "  local value REPLY",
        ]
        for segment in enabledSegments {
            lines.append("  # \(segment.kind.label)")
            lines.append(contentsOf: zsh(segment, fill: chipFills[segment.color], tagColor: tagColors[segment.color])
                .map { "  " + $0 })
        }
        lines += [
            "  local joiner=\(Self.singleQuoted(joiner)) line='' part",
            "  for part in $parts; do",
            "    [[ -n $line ]] && line+=$joiner",
            "    line+=$part",
            "  done",
        ]
        if appearance == .panel {
            let (open, close) = Self.panelCorners
            lines.append("  [[ -n $line ]] && line=\"%F{\(frame)}\(open)%f ${line} %F{\(frame)}\(close)%f\"")
        }
        lines += [
            "  local symbol_color=2",
            "  (( _codec_last_status != 0 )) && symbol_color=1",
            "  local symbol_text=\(Self.singleQuoted(Self.promptEscaped(symbol)))",
            "  local symbol=\"%B%F{$symbol_color}${symbol_text}%f%b\"",
            "  local lead=''",
        ]
        if blankLineBetweenCommands {
            lines.append("  (( ${_codec_prompt_count:-0} > 0 )) && lead=$'\\n'")
            lines.append("  typeset -gi _codec_prompt_count=$(( ${_codec_prompt_count:-0} + 1 ))")
        }
        let afterLine = switch layout {
        case .singleLine: "' '"
        case .twoLines: spaceAboveCommandLine ? "$'\\n\\n'" : "$'\\n'"
        }
        lines += [
            "  if [[ -n $line ]]; then",
            "    PROMPT=\"${lead}${line}\"\(afterLine)\"${symbol} \"",
            "  else",
            "    PROMPT=\"${lead}${symbol} \"",
            "  fi",
            "  RPROMPT=''",
            "}",
            "_codec_prompt_render",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// The zsh that computes one segment and hands it to `_codec_prompt_add`.
    private func zsh(_ segment: Segment, fill: String?, tagColor: String?) -> [String] {
        let color = segment.color.ansiIndex
        let word = Self.singleQuoted(connector(for: segment.kind) ?? "")
        let bold = segment.kind == .directory ? 1 : 0
        let chips = appearance == .chips
        let panel = appearance == .panel
        // A hex fill only; anything else falls back to the terminal's black.
        let pill = chips ? Self.singleQuoted(fill.flatMap(Self.validHex) ?? "0") : "''"
        let tag = "\(Self.singleQuoted(tagColor.flatMap(Self.validHex) ?? "8")) \(Self.singleQuoted(segment.kind.tag))"
        /// `value` is zsh text placed in double quotes: a prompt escape or an already escaped variable.
        func add(_ value: String) -> String {
            panel ? "_codec_prompt_tag \(color) \(tag) \"\(value)\" \(bold)"
                : "_codec_prompt_add \(color) \(word) \"\(value)\" \(bold) \(pill)"
        }
        /// A reading, as `add` would take it; the panel shows its digits as LCD digits. Unlike `add`'s,
        /// `value` must be plain text, not a prompt escape.
        func reading(_ value: String) -> [String] {
            panel ? ["_codec_prompt_lcd \"\(value)\"", add("$REPLY")] : [add(value)]
        }
        /// The panel shows the clock as LCD digits, so it expands the escape itself.
        func clock(_ escape: String) -> [String] {
            panel ? ["print -P -r -v value -- \(Self.singleQuoted(escape))"] + reading("$value") : [add(escape)]
        }
        switch segment.kind {
        case .directory:
            let escape = switch directoryStyle {
            case .full: "%/"
            case .home: "%~"
            case .lastFolder: "%1~"
            }
            return [add(escape)]
        case .gitBranch:
            var code = [
                "value=$(command git symbolic-ref --short -q HEAD 2>/dev/null || command git rev-parse --short -q HEAD 2>/dev/null)",
                "if [[ -n $value ]]; then",
                "  _codec_prompt_escape $value",
                "  value=$REPLY",
            ]
            if showsGitChanges {
                code.append("  command git diff-index --quiet HEAD -- 2>/dev/null || value+='*'")
            }
            code += ["  " + add(chips ? "⎇ $value" : "$value"), "fi"]
            return code
        case .gitDiffStats:
            // "3 files changed, 10 insertions(+), 2 deletions(-)" → "3 • +10 -2". Only digits reach the prompt.
            return [
                "value=$(command git diff --shortstat HEAD 2>/dev/null)",
                "if [[ -n $value ]]; then",
                "  local files=${value%% file*} insertions=0 deletions=0",
                "  files=${files//[^0-9]/}",
                "  [[ $value == *insertion* ]] && insertions=${${value%% insertion*}##*, }",
                "  [[ $value == *deletion* ]] && deletions=${${value%% deletion*}##*, }",
            ] + reading("$files • +${insertions//[^0-9]/} -${deletions//[^0-9]/}").map { "  " + $0 } + [
                "fi",
            ]
        case .userHost:
            return [add("%n@%m")]
        case .time:
            return clock("%D{%H:%M}")
        case .date:
            return clock("%D{%b %d}")
        case .pythonEnvironment:
            let shown = !chips && !panel && !connectingWords ? "($REPLY)" : "$REPLY"
            return [
                "value=${VIRTUAL_ENV:t}",
                "[[ -z $value ]] && value=${CONDA_DEFAULT_ENV}",
                "if [[ -n $value && $value != base ]]; then",
                "  _codec_prompt_escape $value",
                "  " + add(shown),
                "fi",
            ]
        case .kubernetesContext:
            return [
                "value=${KUBECONFIG%%:*}",
                "[[ -z $value ]] && value=$HOME/.kube/config",
                "value=$(command awk '/^current-context:/ { print $2; exit }' $value 2>/dev/null)",
                "if [[ -n $value ]]; then",
                "  _codec_prompt_escape $value",
                "  " + add(panel ? "$REPLY" : "⎈ $REPLY"),
                "fi",
            ]
        case .duration:
            let threshold = String(format: "%g", max(0, durationThreshold))
            return ["if (( _codec_last_duration >= \(threshold) )); then"]
                + reading((chips ? "took " : "") + "$(printf '%.1f' $_codec_last_duration)s").map { "  " + $0 }
                + ["fi"]
        case .exitStatus:
            return ["if (( _codec_last_status != 0 )); then"]
                + (panel ? reading("$_codec_last_status") : [add("✘ $_codec_last_status")]).map { "  " + $0 }
                + ["fi"]
        case .jobs:
            if panel {
                return ["value=${(%):-%j}", "if (( value > 0 )); then"] + reading("$value").map { "  " + $0 } + ["fi"]
            }
            return [
                "value=${(%):-%j}",
                "if (( value > 0 )); then",
                "  local plural=s",
                "  (( value == 1 )) && plural=''",
                "  " + add("$value job$plural"),
                "fi",
            ]
        }
    }

    /// Escapes text for a zsh prompt string: `%` is a prompt escape.
    static func promptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "%", with: "%%")
    }

    /// `#rrggbb`, or nil if `text` isn't one.
    static func validHex(_ text: String) -> String? {
        let digits = text.dropFirst()
        guard text.hasPrefix("#"), digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return text.lowercased()
    }

    /// Quotes text as a single zsh word with no expansion at all.
    static func singleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
