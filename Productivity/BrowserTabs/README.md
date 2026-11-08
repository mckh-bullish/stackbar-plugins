# Browser Tabs

Your open browser tabs and your bookmarks in the palette. Search Browser
Tabs lists every tab in Safari, Chrome, Arc, Brave and Edge while they run;
type part of a title or address and Return switches to it (⌘W closes it,
⌘⇧C copies the link). Search Bookmarks finds the bookmarks Chrome, Brave,
Edge and Vivaldi keep, and opens one in its browser.

- **Needs:** running `osascript` to read and switch tabs (macOS asks once to
  let Stackbar control each browser), `cat` to read each Chromium browser's
  `Bookmarks` file in its profile folder, and the list of running apps, so a
  browser that isn't open is never started. Stackbar 0.35.0 or later.
- **Surfaces:** panel (the open tabs).
- **Commands:** Search Browser Tabs, Search Bookmarks.
- **Leaves out:** Safari's bookmarks, which macOS keeps behind Full Disk
  Access, and browser profiles other than the default one.

## What's new in 1.2.0

- Close Tab says outright that it closes at once, so Stackbar doesn't ask.
- Stackbar 0.35.0 now asks for the second press itself, the same way in the panel, the palette and every window, and VoiceOver reads the question.

## What's new in 1.1.0

- Switching to or closing a tab checks that it's still the same page first. After you rearrange tabs, Close no longer closes a different tab, and a tab that has gone says so.
- Copy as Markdown Link on every tab and bookmark.
- When a browser doesn't answer, or its bookmarks can't be read, the panel says which one instead of showing nothing.
- Tabs from the panel no longer show up in the palette's results with out-of-date titles.
- A page title with a tab in it no longer breaks that tab's address.

## What's new in 1.0.1

- Tabs are read from every running browser at the same time, so one slow browser no longer holds up the rest.
- Bookmark search is lighter on big bookmark sets.
- A bookmarks file too large to read now says so instead of showing no bookmarks.

## What's new in 1.0.0

- First release.
