# Applications

Your apps and System Settings panes in the command palette, as Spotlight and
Raycast have them. Type a few letters ("saf", "vsc", "wi-fi") and the app
comes first in the results; Return opens it, ⌘K copies its path or bundle id.
The ones you open most rank higher. Search Applications lists them all.

- **Needs:** the list of installed apps and opening them (`.apps`), and
  opening System Settings panes by their link. Stackbar 0.20.0 or later.
- **Surfaces:** panel (your most opened apps).
- **Commands:** Search Applications, which also feeds the palette's results.
- **Looks in:** /Applications (one folder deep), ~/Applications and the
  system's own apps, plus every pane System Settings lists.

## What's new in 1.0.0

- First release: the palette's app search, now a plugin.
