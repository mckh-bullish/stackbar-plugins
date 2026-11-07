# Dictionary

Look words up in the Mac's own Dictionary without leaving what you're doing. Open the palette, type **Define Word**, then the word, and the definition shows as you type. It works offline.

Return copies the definition, ⌘⇧C copies the word, and ⌘O opens it in the Dictionary app. Words you used stay in a Recent list.

## What it needs

Stackbar 0.26.0 or later, and permission to open `dict://` links (that is how ⌘O opens the Dictionary app). It uses the dictionaries turned on in the Dictionary app's settings, so other languages work too.

## What's new in 1.1.0

- Open in Dictionary (⌘O) works: it now declares the dict:// link it opens, which Stackbar shows on the install sheet. If something is refused you see why.
- A look-up that fails shows the error instead of telling you to check the spelling.

## What's new in 1.0.0

- First version: definitions in the palette, copy or open in Dictionary, and recent words.
