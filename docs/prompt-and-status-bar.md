# Prompt and status bar

## The prompt builder

Settings › Prompt › Edit Prompt… lets you keep your shell's own prompt (PS1) or use the Codec prompt, built from chips:

- **Add** a chip by clicking or dragging it in; **drag** to reorder; **×** to remove; **right-click** to recolor.
- **Chips**: working directory, git branch (with `*` for uncommitted changes), git changes (`3 • +10 -2`), Python environment, Kubernetes context, the last command's duration and exit status, background jobs, user@host, time and date.
- **Style**: by default, segments are drawn as chips (tinted, rounded pills like the ones in Codec's status bar, colored from your theme, with the directory in bold). The Text style draws them as a phrase instead: `~/code/codec on main* via venv took 3.2s`.
- **Layout**: one line, or the context on a line above the command.
- **Symbol**: the character before the command, which turns red after a failed command.

Changes apply to open zsh panes at their next prompt. Values that come from the shell (branch names and the like) are escaped, so they can't run code even with `prompt_subst` on.

## Branch switcher

Click the branch in the status bar, or in the prompt itself (it works for your own PS1 too, wherever it shows the branch), or press ⇧⌘B:

- fuzzy-search local branches, most recent first, and remote ones, which become tracking branches,
- type a new name to create a branch.

If git refuses, say because uncommitted changes would be overwritten, its explanation shows in the popover. The prompt and status bar update straight away.

## Status bar (zsh)

Along the bottom of the window:

- the **directory**: click to open it in Finder,
- the **git branch**: click to switch,
- the **running or last command**, with its exit status and how long it took.

## System meters

The right end of the status bar shows CPU, memory and network as codec-style rising bars and seven-segment readouts; bars turn red above 85 %. Click them to open Activity Monitor. Hide them in Settings › Appearance › Status bar.
