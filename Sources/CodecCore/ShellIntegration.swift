import Foundation

/// zsh integration, injected through ZDOTDIR the way kitty and Ghostty do it. The hooks report:
/// - OSC 133 prompt marks (A/B/C/D), used to jump between commands,
/// - OSC 7 working directory,
/// - OSC 6973 `exec;<command>` and `done;<status>;<seconds>` (see `IntegrationEvent`).
///
/// The user's own startup files still load, unchanged: the bootstrap `.zshenv` restores `ZDOTDIR`
/// before zsh looks for `.zprofile` and `.zshrc`.
public struct ShellIntegration: Sendable {
    /// Where the scripts are installed; `zsh/` inside it becomes the shell's ZDOTDIR.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The default location, in Application Support.
    public static func standard(fileManager: FileManager = .default) -> ShellIntegration? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return ShellIntegration(directory: support.appendingPathComponent("Codec/shell-integration"))
    }

    public var zshDirectory: URL { directory.appendingPathComponent("zsh") }
    public var zshScript: URL { zshDirectory.appendingPathComponent("codec-integration.zsh") }
    /// Generated from `PromptConfiguration`; sourced before every prompt, so edits apply to open shells.
    public var promptFile: URL { zshDirectory.appendingPathComponent("prompt.zsh") }

    /// Writes the scripts, replacing older versions.
    public func install(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: zshDirectory, withIntermediateDirectories: true)
        try Self.zshenv.write(to: zshDirectory.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        try Self.zshHooks.write(to: zshScript, atomically: true, encoding: .utf8)
        if !fileManager.fileExists(atPath: promptFile.path) {
            try writePrompt(.default)
        }
    }

    /// Writes the prompt open zsh sessions pick up at their next prompt.
    public func writePrompt(_ configuration: PromptConfiguration,
                            chipFills: [PromptConfiguration.Color: String] = [:]) throws {
        try FileManager.default.createDirectory(at: zshDirectory, withIntermediateDirectories: true)
        try configuration.zshScript(chipFills: chipFills).write(to: promptFile, atomically: true, encoding: .utf8)
    }

    /// Whether integration is available for `shell` (a path or a name).
    public static func supports(shell: String) -> Bool {
        (shell as NSString).lastPathComponent == "zsh"
    }

    /// `environment` with what `shell` needs to load the integration. Unchanged for unsupported shells.
    public func environment(_ environment: [String: String], forShell shell: String) -> [String: String] {
        guard Self.supports(shell: shell) else { return environment }
        var result = environment
        if let original = environment["ZDOTDIR"] {
            result["CODEC_ORIG_ZDOTDIR"] = original
        }
        result["ZDOTDIR"] = zshDirectory.path
        result["CODEC_SHELL_INTEGRATION"] = zshScript.path
        result["CODEC_PROMPT_FILE"] = promptFile.path
        return result
    }

    static let zshenv = #"""
    # Codec shell integration bootstrap. Puts your ZDOTDIR back, loads your own
    # .zshenv, then loads Codec's hooks in interactive shells.
    if [[ -n "${CODEC_ORIG_ZDOTDIR+x}" ]]; then
      export ZDOTDIR="$CODEC_ORIG_ZDOTDIR"
      unset CODEC_ORIG_ZDOTDIR
    else
      unset ZDOTDIR
    fi
    [[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]] && source "${ZDOTDIR:-$HOME}/.zshenv"
    if [[ -o interactive && -n "$CODEC_SHELL_INTEGRATION" && -f "$CODEC_SHELL_INTEGRATION" ]]; then
      source "$CODEC_SHELL_INTEGRATION"
    fi

    """#

    static let zshHooks = #"""
    # Codec shell integration for zsh.
    [[ -n "$_CODEC_HOOKED" ]] && return
    typeset -g _CODEC_HOOKED=1
    zmodload zsh/datetime 2>/dev/null
    typeset -gF _codec_started=0
    typeset -gi _codec_running=0
    typeset -gi _codec_status=0
    # The last command's status and duration, for the prompt; zero when no command ran.
    typeset -gi _codec_last_status=0
    typeset -gF _codec_last_duration=0

    _codec_osc() { builtin print -rn -- $'\e]'"$1"$'\a' }

    # Runs first, so $? is still the command's status.
    _codec_capture_status() { _codec_status=$? }

    # Runs last, after themes have built PS1.
    _codec_precmd() {
      if (( _codec_running )); then
        _codec_running=0
        _codec_last_status=$_codec_status
        _codec_last_duration=$(( EPOCHREALTIME - _codec_started ))
        _codec_osc "133;D;$_codec_status"
        _codec_osc "6973;done;$_codec_status;$_codec_last_duration"
      else
        _codec_last_status=0
        _codec_last_duration=0
      fi
      local dir=${PWD//\%/%25}
      _codec_osc "7;file://${HOST}${dir// /%20}"
      [[ -n "$CODEC_PROMPT_FILE" && -r "$CODEC_PROMPT_FILE" ]] && source "$CODEC_PROMPT_FILE"
      _codec_osc "133;A"
      [[ "$PS1" == *$'\e]133;B'* ]] || PS1+=$'%{\e]133;B\a%}'
    }

    _codec_preexec() {
      _codec_started=$EPOCHREALTIME
      _codec_running=1
      local line=${1%%$'\n'*}
      _codec_osc "133;C"
      _codec_osc "6973;exec;${line//[$'\a\e']/}"
    }

    # Install on the first prompt so these hooks wrap whatever .zshrc set up.
    _codec_install() {
      precmd_functions=(_codec_capture_status ${precmd_functions:#_codec_install} _codec_precmd)
      preexec_functions+=(_codec_preexec)
      _codec_precmd
    }
    precmd_functions+=(_codec_install)

    """#
}
