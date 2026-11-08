# Dictionary

Look words up in the Mac's own Dictionary without leaving what you're doing. Open the palette, type **Define Word**, then the word, and the definition shows as you type. It works offline.

Return copies the definition, ⌘⇧C copies the word, and ⌘O opens it in the Dictionary app. Words you used stay in a Recent list.

- **Needs:** permission to open `dict://` links (how ⌘O opens the Dictionary app). Definitions come from the dictionaries turned on in the Dictionary app's settings, so other languages work too.
- **Surfaces:** panel.
- **Commands:** Define Word (also offered under the palette's results for any text).
- **Requires:** Stackbar 0.26.0 or later.

## What's new in 1.2.0

- Look a word up right in the panel, and click a recent word to see its definition again.
- Picking a recent word in Define Word shows its definition instead of the list again.
- Type any word in the palette and Define Word is offered under the results.

## What's new in 1.1.0

- Open in Dictionary (⌘O) works: it now declares the dict:// link it opens, which Stackbar shows on the install sheet. If something is refused you see why.
- A look-up that fails shows the error instead of telling you to check the spelling.

## What's new in 1.0.0

- First version: definitions in the palette, copy or open in Dictionary, and recent words.
