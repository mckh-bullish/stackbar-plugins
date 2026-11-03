# Snippets

Text you paste by name, with placeholders filled in. Each snippet becomes a
command of its own that pastes into the app you were in, then puts your
clipboard back. Snippets use Raycast's template syntax: `{clipboard}`,
`{selection}`, `{date format="d MMM"}`, `{argument name="who"}` asks first,
`{cursor}` leaves the caret there, and `{snippet name="Signature"}` pulls in
another snippet.

- **Needs:** the clipboard (to paste), what you had selected for
  `{selection}`, and 16 MB of storage for the snippets.
- **Surfaces:** panel, settings. Hotkey ⌃⌥S opens Search Snippets.
- **Settings:** your snippets, and importing a Raycast export.
- **Commands:** Search Snippets, Create Snippet, Import Snippets, Export
  Snippets (a file Raycast reads too), plus one command per snippet.
- **Not yet:** keywords are kept but not expanded as you type, because that
  needs a system-wide keyboard monitor.

## What's new in 1.2.1

- Its own icon and colour in the Store and in Settings.
