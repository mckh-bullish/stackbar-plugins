# Emoji

An emoji picker in the command palette. Search Emoji opens a grid of every
emoji, grouped as Unicode groups them, with the ones you use most at the top.
Type to narrow it ("party", "thumbs up", "flag japan"), move with the arrow
keys, and press Return to paste the emoji where you were typing. ⌘K copies it
instead. The panel keeps your frequent ones a click from the clipboard.

- **Needs:** the clipboard, to paste (your clipboard is put back afterwards).
  Stackbar 0.20.0 or later, which draws grids in the palette.
- **Surfaces:** panel.
- **Commands:** Search Emoji. Give it a hotkey in Settings › Commands.
- **Data:** Unicode's Emoji 15.1 list and English names, without skin-tone
  variants. Nothing leaves your Mac.

## What's new in 1.1.1

- Hyphenated names are found: left-facing, heart-eyes, upside-down, star-struck.
- Typing only a colon or a dash no longer lists the whole table as if it were a result.
- Searching and browsing do less work on every keystroke and redraw.

## What's new in 1.1.0

- Type a colon and a name, like :tada, in the palette to find an emoji without opening Emoji first.

## What's new in 1.0.0

- First release: every emoji in a searchable grid in the palette.
