# Clipboard History

Everything you copy, searchable, pinnable and one keystroke from being pasted
back. ⌘⇧V opens it from anywhere: type to filter, ↑↓ and Return (or ⌘1 to ⌘9)
to paste into the app you were in, ⌥Return to paste as plain text, ⌘P to pin
and ⌥⌫ to delete. Formatted text keeps its formatting, and images are kept by
the host and pasted back.

- **Needs:** the clipboard. Passwords are skipped: the host never hands out
  items an app marks as concealed or transient, and copies from password
  managers (or any app you add) are ignored.
- **Surfaces:** menu bar, panel, window, settings. Hotkey ⌘⇧V.
- **Settings:** how many items to keep, the order, pasting directly or only
  copying, keeping images, plain text by default, apps and text patterns to
  ignore, and pausing the history.
- **Commands:** Search Clipboard History, Paste Last Copy as Plain Text,
  Pause Clipboard History, Ignore Next Copy.
- **Agent tools:** `recent_clips`, `search_clips` and `copy_clip`.
