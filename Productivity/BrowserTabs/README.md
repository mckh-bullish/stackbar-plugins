# Browser Tabs

Your open browser tabs and your bookmarks in the palette. Search Browser
Tabs lists every tab in Safari, Chrome, Arc, Brave and Edge while they run;
type part of a title or address and Return switches to it (⌘W closes it,
⌘⇧C copies the link). Search Bookmarks finds the bookmarks Chrome, Brave,
Edge and Vivaldi keep, and opens one in its browser.

- **Needs:** running `osascript` to read and switch tabs (macOS asks once to
  let Stackbar control each browser), `cat` to read each Chromium browser's
  `Bookmarks` file in its profile folder, and the list of running apps, so a
  browser that isn't open is never started. Stackbar 0.22.0 or later.
- **Surfaces:** panel (the open tabs).
- **Commands:** Search Browser Tabs, Search Bookmarks.
- **Leaves out:** Safari's bookmarks, which macOS keeps behind Full Disk
  Access, and browser profiles other than the default one.

## What's new in 1.0.0

- First release.
