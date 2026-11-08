# Recent Projects

The folders and workspaces you opened lately in VS Code, Cursor, Windsurf
and VSCodium, in the palette. Type a few letters of a project's name or path
and Return opens it in the editor you last used it in, or in the default
editor you pick in Settings; ⌘K opens it in another editor you have or
copies its path. The projects you open from here
rank higher, and they show up in the palette's own results too.

- **How it finds projects:** VS Code, Cursor, Windsurf and VSCodium each
  keep their recently opened list in `state.vscdb` under
  `~/Library/Application Support/<Editor>/User/globalStorage`. The plugin
  reads its `history.recentlyOpenedPathsList` entry, up to 30 from each editor,
  and lists each folder or workspace once. VS Code 1.118 and later keep this
  list in `~/.vscode-shared/sharedStorage/state.vscdb` instead, which is read
  too.
- **Settings:** the default editor. "Where it was last opened" (the
  default) keeps each project in the editor it came from; or pick any
  installed editor: the VS Code family, Zed, Xcode, Sublime Text, Nova,
  BBEdit, TextMate, IntelliJ IDEA, WebStorm, PyCharm, GoLand, RustRover or
  Android Studio. Workspace files (`.code-workspace`) still open in a VS
  Code-style editor.
- **Needs:** running `sqlite3` (part of macOS) in read-only mode on each
  editor's `state.vscdb`, the editors' storage folders under Application
  Support and VS Code's `~/.vscode-shared/sharedStorage`, opening links and folders in any app (to hand a folder to your
  default editor), and the list of installed apps (to show which editors
  you have). Stackbar 0.22.0 or later.
- **Surfaces:** panel (your recent projects, searchable) and settings.
- **Commands:** Search Recent Projects, which also feeds the palette's
  results.
- **Leaves out:** single files and remote (SSH, container) projects.

## What's new in 1.3.0

- VS Code 1.118 and later: your recent projects show up again. VS Code moved its list to `~/.vscode-shared/sharedStorage`, and the plugin now reads it there as well as in the old place. Updating asks you once to allow reading that folder.

## What's new in 1.2.0

- Show in Finder on every project.
- The panel lists all your recent projects, with search, not only the latest 8.
- If VS Code's projects are missing because VS Code moved its list, or an editor's list can't be read, the panel says so instead of looking empty.
- Typing in the palette answers from the list read in the last few minutes, so results show faster.

## What's new in 1.1.0

- A default editor in Settings, picked from the editors installed on your
  Mac, Zed, Xcode, Sublime Text and JetBrains IDEs included. Return opens
  projects there; ⌘K still offers the others.
- Asks to open folders in any app and to list installed apps, for the
  setting.

## What's new in 1.0.0

- First release.
