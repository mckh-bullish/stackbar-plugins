# Snippets

Text you paste by name, with placeholders filled in. Each snippet becomes a
command of its own that pastes into the app you were in, then puts your
clipboard back. Snippets use Raycast's template syntax: `{clipboard}`,
`{selection}`, `{date format="d MMM"}`, `{argument name="who"}` asks first,
`{cursor}` leaves the caret there, and `{snippet name="Signature"}` pulls in
another snippet.

- **Needs:** the clipboard (to paste), what you had selected for
  `{selection}`, 16 MB of storage for the snippets, and keyword expansion.
  Stackbar 0.24.0 or later.
- **Surfaces:** panel, settings. Hotkey ⌃⌥S opens Search Snippets.
- **Settings:** your snippets, importing from Raycast, TextExpander, Espanso or
  Apple's Text Replacements, and whether
  keywords are expanding.
- **Commands:** Search Snippets, Create Snippet, Import Snippets, Export
  Snippets (a file Raycast reads too), plus one command per snippet.
- **Keywords:** type a snippet's keyword, like `;sig`, in any app and it is
  replaced with the snippet. A snippet that asks for an argument opens in the
  palette first. Stackbar does the watching, so this plugin never sees what
  you type; switch it off or skip apps in Settings › Privacy & Secrets.

## Bring your snippets with you

Import Snippets reads:

- **Raycast:** its JSON export, as it is.
- **TextExpander:** a `.textexpander` group file or its CSV export.
  `%clipboard`, `%|` (cursor), fill-ins (`%filltext:name=who%`) and date
  codes like `%Y-%m-%d` become placeholders; abbreviations become keywords.
- **Espanso:** a match file (`base.yml`). `trigger` or `triggers` become
  keywords, `$|$` the cursor and `{{clipboard}}` the clipboard.
- **Text Replacements:** select them in System Settings > Keyboard > Text
  Replacements and drag them to the Desktop, then import the plist.

Duplicates are skipped, and keywords already taken are left off.

## What's new in 1.5.1

- Importing a big snippet file saves once instead of once per snippet, and editing a snippet saves once.
- Snippet lists open and search faster with many snippets, and keyword changes are sent to Stackbar in order, so a deleted keyword can no longer keep expanding.

## What's new in 1.5.0

- Import from TextExpander, Espanso and Apple's Text Replacements, with their placeholders and keywords.

## What's new in 1.4.0

- Keywords expand as you type them, in any app. Keywords are now at most 32
  characters; longer ones you already have stay searchable.

## What's new in 1.3.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.2.1

- Its own icon and colour in the Store and in Settings.
