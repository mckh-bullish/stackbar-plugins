# Clipboard History

Everything you copy, searchable, pinnable and one keystroke from being pasted
back. ⌘⇧V opens it in the palette from anywhere, with a preview of the
selected copy beside the list: type to filter, ↑↓ and Return (or ⌘1 to ⌘9)
to paste into the app you were in, ⌥Return to paste as plain text, ⌘P to pin
and ⌥⌫ to delete. Formatted text keeps its formatting, and images are kept by
the host and pasted back. The text in a copied image (a screenshot, a
photo of a receipt) is read on your Mac, so typing finds the image, and ⌘⇧T
copies that text. ⌘K holds every action, Pause Recording and Ignore Next
Copy included. The popup with the last copy and the Pause buttons is still on
the menu bar icon, if you turn the icon on.

- **Needs:** the clipboard. Passwords are skipped: the host never hands out
  items an app marks as concealed or transient, and copies from password
  managers (or any app you add) are ignored. Copies that look like secrets
  (API keys and tokens, JSON web tokens, private keys, card numbers, six-digit
  codes) are shown masked, kept out of agent tools, and dropped after 15
  minutes unless you pin them.
- **Surfaces:** menu bar, panel, window, settings. Hotkey ⌘⇧V.
- **Settings:** how many items to keep, the order, pasting directly or only
  copying, showing matching copies in the palette's results (off by default), keeping images, finding images by their text, plain text by default, how long to keep secrets
  (not at all, 5 minutes to an hour, or like any copy), apps and text patterns
  to ignore, and pausing the history.
- **Commands:** Search Clipboard History, Paste Last Copy as Plain Text,
  Pause Clipboard History, Ignore Next Copy.
- **Agent tools:** `recent_clips`, `search_clips` and `copy_clip`.
- **Requires:** Stackbar 0.27.0 or later.

## Highlights

### One keystroke from anything you copied
⌘⇧V opens your history in the palette from anywhere, and again closes it.
Type to filter, then Return pastes it into the app you were in. ⌥Return pastes it as plain text.

### Pin what you paste every day
Pinned items stay at the top and are never pushed out by new copies.
<!-- preview: pinned -->

### Secrets don't stick around
Copies from password managers are skipped. Anything that looks like a token,
key or card number is masked, kept away from agent tools, and dropped after
15 minutes unless you pin it.

### See what you copy
The window shows how much you copy, and from which apps.
<!-- preview: insights -->

## What's new in 1.10.0

- Copies no longer show in the command palette's main results unless you turn on "Show matching copies in the palette's results" in Settings. Search Clipboard History (⌘⇧V) works as before.

## What's new in 1.9.1

- Pinned items now count against the storage limit, so pinning many large copies can no longer stop new copies from being saved. Pins past their share are unpinned, and pinning more than fits says so.
- A text-reading hiccup on an image is retried instead of marking it as having no text, and saving copies, text reading and the day counts write less often.
- Long copies are counted once instead of on every redraw.
- When older pins are unpinned to keep the history within its storage, a notice says how many and why.

## What's new in 1.9.0

- ⌘⇧V opens your history in the command palette, with the preview beside it and every action, Pause and Ignore Next Copy included, under ⌘K. The popup stays on the menu bar icon.

## What's new in 1.8.1

- Every copy now has a preview, short ones too, so the palette's list keeps its detail pane and stops jumping as you move through it.

## What's new in 1.8.0

- Search finds images by the text in them, read on your Mac with Apple's text recognition, and Copy Text in Image (⌘⇧T) copies it.

## What's new in 1.7.0

- The menu bar icon is off by default: ⌘⇧V and the palette open the history. It comes back while recording is paused, and Settings can keep it on.
- Agents can no longer read your clipboard unless you allow it in Stackbar's Settings → Agents.

## What's new in 1.6.0

- Matching copies show in the command palette's own results as you type, so
  you can paste one without opening the history first (Stackbar 0.20.0). Turn
  it off in Settings.

## What's new in 1.5.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.4.1

- Its own icon and colour in the Store and in Settings.
