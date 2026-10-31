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
      # cl=line: clicking on the command line moves the cursor there.
      _codec_osc "133;A;cl=line"
      _codec_osc "6973;prompt"
      [[ "$PS1" == *$'\e]133;B'* ]] || PS1+=$'%{\e]133;B\a%}'
    }

    _codec_preexec() {
      _codec_started=$EPOCHREALTIME
      _codec_running=1
      local line=${1%%$'\n'*}
      _codec_osc "133;C"
      _codec_osc "6973;exec;${line//[$'\a\e']/}"
    }

    # --- Editing the command line like a text field ------------------------------
    # The zsh region (mark to cursor) is the selection. Codec sends the private sequences bound below
    # (see CommandLineEditing) for mouse selections and macOS shortcuts.

    _codec_select_by() {
      (( REGION_ACTIVE )) || { MARK=$CURSOR; REGION_ACTIVE=1 }
      zle $1
    }
    _codec_select_left() { _codec_select_by .backward-char }
    _codec_select_right() { _codec_select_by .forward-char }
    _codec_select_word_left() { _codec_select_by .backward-word }
    _codec_select_word_right() { _codec_select_by .forward-word }
    _codec_select_to_start() { _codec_select_by .beginning-of-line }
    _codec_select_to_end() { _codec_select_by .end-of-line }
    _codec_mark() { MARK=$CURSOR; REGION_ACTIVE=1 }
    _codec_unmark() { REGION_ACTIVE=0 }
    _codec_step_left() { (( CURSOR > 0 )) && (( CURSOR-- )); return 0 }
    _codec_step_right() { (( CURSOR < $#BUFFER )) && (( CURSOR++ )); return 0 }
    _codec_select_all() { MARK=0; CURSOR=$#BUFFER; REGION_ACTIVE=1 }
    _codec_save_cursor() { typeset -gi _codec_saved_cursor=$CURSOR }
    _codec_restore_cursor() { CURSOR=${_codec_saved_cursor:-$CURSOR} }
    # The word around the cursor: everything up to the surrounding whitespace, so paths stay whole.
    _codec_select_word() {
      local start=$CURSOR end=$CURSOR
      while (( start > 0 )) && [[ ${BUFFER[start]} != [[:space:]] ]]; do (( start-- )); done
      while (( end < $#BUFFER )) && [[ ${BUFFER[end+1]} != [[:space:]] ]]; do (( end++ )); done
      MARK=$start CURSOR=$end REGION_ACTIVE=1
    }
    _codec_cut() { (( REGION_ACTIVE )) && zle kill-region; REGION_ACTIVE=0; return 0 }
    _codec_delete_to_start() {
      if (( REGION_ACTIVE )); then zle kill-region; REGION_ACTIVE=0; else zle backward-kill-line; fi
    }
    _codec_move_to_start() { REGION_ACTIVE=0; zle .beginning-of-line }
    _codec_move_to_end() { REGION_ACTIVE=0; zle .end-of-line }

    # Typing, pasting or deleting with a selection replaces it. These wrap whatever the widgets were
    # (plugins such as zsh-autosuggestions wrap them too), so existing behavior is kept.
    _codec_self_insert() {
      (( REGION_ACTIVE )) && { zle kill-region; REGION_ACTIVE=0 }
      zle _codec_orig_self-insert
    }
    _codec_bracketed_paste() {
      (( REGION_ACTIVE )) && { zle kill-region; REGION_ACTIVE=0 }
      zle _codec_orig_bracketed-paste
    }
    _codec_backward_delete_char() {
      if (( REGION_ACTIVE )); then zle kill-region; REGION_ACTIVE=0; else zle _codec_orig_backward-delete-char; fi
    }
    _codec_delete_char() {
      if (( REGION_ACTIVE )); then zle kill-region; REGION_ACTIVE=0; else zle _codec_orig_delete-char; fi
    }

    # Plain cursor movement ends a selection, as in a text field.
    _codec_collapse_on_move() {
      (( REGION_ACTIVE )) || return 0
      case $LASTWIDGET in
        (*forward-char|*backward-char|*forward-word|*backward-word|*beginning-of-line|*end-of-line|*-line-or-*|*history*)
          REGION_ACTIVE=0 ;;
      esac
    }

    _codec_setup_editing() {
      local widget
      for widget in self-insert bracketed-paste backward-delete-char delete-char; do
        zle -A $widget _codec_orig_$widget
      done
      zle -N self-insert _codec_self_insert
      zle -N bracketed-paste _codec_bracketed_paste
      zle -N backward-delete-char _codec_backward_delete_char
      zle -N delete-char _codec_delete_char
      for widget in _codec_select_left _codec_select_right _codec_select_word_left _codec_select_word_right \
                    _codec_select_to_start _codec_select_to_end _codec_mark _codec_unmark _codec_step_left \
                    _codec_step_right _codec_select_all _codec_select_word _codec_cut _codec_delete_to_start \
                    _codec_move_to_start _codec_move_to_end _codec_save_cursor _codec_restore_cursor; do
        zle -N $widget
      done
      local map
      for map in emacs viins; do
        # Shift+arrows, Shift+Option+arrows and Shift+Home/End extend the selection.
        bindkey -M $map $'\e[1;2D' _codec_select_left $'\e[1;2C' _codec_select_right \
          $'\e[1;4D' _codec_select_word_left $'\e[1;4C' _codec_select_word_right \
          $'\e[1;2H' _codec_select_to_start $'\e[1;2F' _codec_select_to_end
        # Codec's private sequences.
        bindkey -M $map $'\e[57001~' _codec_mark $'\e[57002~' _codec_step_left $'\e[57003~' _codec_step_right \
          $'\e[57004~' _codec_unmark $'\e[57005~' _codec_cut $'\e[57006~' _codec_select_word \
          $'\e[57007~' _codec_select_all $'\e[57008~' _codec_select_to_start $'\e[57009~' _codec_select_to_end \
          $'\e[57010~' _codec_delete_to_start $'\e[57011~' _codec_move_to_start $'\e[57012~' _codec_move_to_end \
          $'\e[57013~' _codec_save_cursor $'\e[57014~' _codec_restore_cursor
        # Forward delete, if nothing else claims it.
        [[ $(bindkey -M $map $'\e[3~') == *undefined-key ]] && bindkey -M $map $'\e[3~' delete-char
      done
      autoload -Uz add-zle-hook-widget && add-zle-hook-widget line-pre-redraw _codec_collapse_on_move
      # Show the selection in the theme's selection color, unless the user styled it.
      [[ -n $CODEC_SELECTION_STYLE && ${(j: :)zle_highlight} != *region:* ]] && zle_highlight+=(region:$CODEC_SELECTION_STYLE)
    }

    # Install on the first prompt so these hooks wrap whatever .zshrc set up.
    _codec_install() {
      precmd_functions=(_codec_capture_status ${precmd_functions:#_codec_install} _codec_precmd)
      preexec_functions+=(_codec_preexec)
      _codec_setup_editing
      _codec_precmd
    }
    precmd_functions+=(_codec_install)

    """#
}
