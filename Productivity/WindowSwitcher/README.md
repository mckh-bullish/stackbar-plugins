# Window Switcher

Every open window in the command palette, as Raycast's Switch Windows has
it. Open the palette, choose Switch Windows and type a few letters of the
app or the window's title ("saf pull" finds Safari's Pull requests window).
Return brings that window to the front, out of the Dock if it was
minimized; ⌘⇧C copies its title.

- **Needs:** listing and focusing windows (`.windows`), which uses
  Accessibility access. Stackbar 0.25.0 or later.
- **Surfaces:** panel (the windows open now).
- **Commands:** Switch Windows.
- **Order:** front to back when nothing is typed; with more than one
  display, each row says which display the window is on.

## What's new in 1.0.0

- First release.
