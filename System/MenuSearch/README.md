# Menu Search

The menus of the app you're in, searchable from the palette, as Raycast's
Search Menu Items has it. In any app, open the palette, choose Search Menu
Items and type part of an item ("export", "view zoom"). Return chooses it.
Each row shows where the item lives (File › Export) and its keyboard
shortcut, so you learn them as you go. The items you choose most rank
higher for that app.

- **Needs:** reading the menus of the app you were in and choosing an item
  (`.menus`), which uses Accessibility access. Stackbar 0.31.0 or later.
- **Surfaces:** panel (your most chosen menu items).
- **Commands:** Search Menu Items.
- **Leaves out:** the Apple menu, submenu titles and separators. Dimmed
  items show at the bottom and can't be chosen.

## What's new in 1.1.0

- Typos, initials and dots are forgiven: "zom in" finds Zoom In, "nw" finds New Window and "export..." finds Export as PDF….
- The panel lists the menu items you choose most, across your apps. Click one to choose it again.

## What's new in 1.0.1

- A failed menu read is remembered for a few seconds, so typing no longer repeats the whole menu walk on every key.

## What's new in 1.0.0

- First release.
