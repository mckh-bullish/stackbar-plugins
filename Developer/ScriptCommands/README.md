# Script Commands

Your own scripts as palette commands, in the format Raycast's Script
Commands use, so the scripts you already have work as they are. Put them in
a folder named **Script Commands** in your home folder. Each script with a
`@raycast.title` line becomes a command within a minute (or right away with
Reload Script Commands).

```bash
#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Say Hello
# @raycast.mode compact
# @raycast.packageName Demo
# @raycast.argument1 { "type": "text", "placeholder": "Name", "optional": true }
echo "Hello ${1:-world}"
```

- **Modes:** `silent` shows the last line it prints on screen, `compact` (and
  `inline`) shows it in the palette, `fullOutput` opens a view with all of it.
- **Also read:** `packageName`, `description`, `icon` (an emoji),
  `argument1` to `argument3`, and `needsConfirmation`, which asks before the
  script runs.
- **Interpreters:** the first line names it: bash, zsh, sh, python3, node,
  ruby, perl, php, swift or osascript.
- **Needs:** the ~/Script Commands folder, running grep (to read the
  `@raycast.` lines) and those interpreters. Stackbar 0.22.0 or later.
- **Surfaces:** panel (your scripts).
- **Commands:** one for each script, Script Commands (the list), and Reload Script Commands.

## What's new in 1.1.0

- A folder with an unreadable file or subfolder no longer stops the script list from refreshing.
- A slow or failed scan keeps your last list of commands instead of emptying it.
- Script Commands opens a list of your scripts and rescans the folder as it opens, so a new script shows without waiting for the timer.
- Skips .git, node_modules and similar folders, and rescans every 5 minutes (Reload Script Commands does it at once).

## What's new in 1.0.0

- First release.
