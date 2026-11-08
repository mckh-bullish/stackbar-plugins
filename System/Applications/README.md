# Applications

Your apps and System Settings panes in the command palette, as Spotlight and
Raycast have them. Type a few letters ("saf", "vsc", "wi-fi") and the app
comes first in the results; Return opens it, ⌘K copies its path or bundle id.
The ones you open most rank higher. Search Applications lists them all.

- **Needs:** the list of installed apps and opening them (`.apps`), and
  opening System Settings panes by their link. Stackbar 0.31.0 or later.
- **Surfaces:** panel (your most opened apps).
- **Commands:** Search Applications, which also feeds the palette's results.
- **Looks in:** /Applications (one folder deep), ~/Applications and the
  system's own apps, plus every pane System Settings lists.

## What's new in 1.2.2

- System Settings panes open again: picking Wi-Fi, Displays or any other pane brings it up.
- Typing in the palette always answers straight away. The app list refreshes in the background every few minutes instead of making a keystroke wait.
- Your most opened apps in the panel no longer show up a second time in the palette's results.

## What's new in 1.2.1

- A failed app listing is retried after a few seconds instead of on every keystroke.

## What's new in 1.2.0

- Matches the way the rest of the palette does, with Stackbar's own matcher,
  so apps and commands rank on one scale. Stackbar now also learns which app
  you pick for what you type.

## What's new in 1.1.0

- The panel points to App Switcher, for switching apps with Right ⌘ and a
  letter. It stays a separate plugin, because it listens to the keyboard.

## What's new in 1.0.1

- Typing "settings" finds the System Settings app first. Every pane used to
  outrank it, because each one has "settings" as a keyword.

## What's new in 1.0.0

- First release: the palette's app search, now a plugin.
