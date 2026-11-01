# Commands sidebar (zsh)

![The Commands sidebar, with a command's output open](images/commands.png)

You tried a few things, went on for a while, and now you want to see what happened earlier. The Commands sidebar is that pane's story: every command it ran, with how it went and what it printed.

Open it with ⇧⌘L, or the sidebar button at the right end of the tab bar. It follows the focused pane, like the file tree.

## What it shows

Commands are listed oldest first, under the folder they ran in. Each row has:

- a green or red dot for whether it worked (pulsing while it runs),
- when it ran and how long it took,
- the last line it printed (`Build complete!`, `3 tests failed`), or the exit status of a failed one.

## Going back to a command

Click a command, or move through the list with ↑ / ↓: the terminal scrolls back to it and marks it, with a bar beside its rows and a tint on its line. Return goes there and gives the terminal the keyboard; Esc goes back to where you were.

Typing a new command in the terminal never pulls you back to the selected one.

## A command's output

Space or a double-click opens its output in a viewer you can select from and search (⌘F), with Copy Output, Go to Command, Save to Intel, Insert and Run Again.

Codec keeps each command's output when it finishes (its first and last few thousand lines), so it's still there after it has left the scrollback or ⌘K cleared it. Such commands show a small box icon; clicking them opens the viewer.

## Filtering

The filter field searches commands and what they printed. A row shows the line that matched, and going to it scrolls to that line. ⚠ shows failed commands only; the bin clears the list (the commands are still tracked, just hidden).

## Right-click

Go to Command, Show Output, Save to Intel…, Copy Command, Copy Output, Select Output, Insert Command, Run Again, Copy Folder Path.

## Saving a command for later

Hover a row and click its bookmark, or right-click › Save to Intel…, to keep the command as an [Intel](intel.md) script. Codec offers the parts that tend to change as variables.
