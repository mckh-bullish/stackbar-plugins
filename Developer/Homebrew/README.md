# Homebrew

What Homebrew can upgrade, in the menu bar. The number is how many formulae
and casks are outdated; the panel lists them with Upgrade on each row and
Upgrade All at the top.

- **Needs:** to run `brew` (Stackbar finds it in `/opt/homebrew/bin` or
  `/usr/local/bin` and asks you to approve that path once). No network,
  files or secrets of its own.
- **Surfaces:** menu bar, panel, widget, settings.
- **How it checks:** hourly and on wake it runs `brew outdated --json=v2`,
  which reads what Homebrew already knows. When that list is more than 6 hours
  old it runs `brew update` first (from the second check after launch, so
  the list shows right away), so the count doesn't go stale; the panel says
  how old the list is. Update Homebrew fetches it now.
- **Settings:** show casks, hide pinned formulae, include casks that update
  themselves (`--greedy`), fetch the latest formulae every 6 hours (on by
  default), and a notification when new updates appear.
- **Commands:** Upgrade All Homebrew Packages, Update Homebrew, Outdated
  Homebrew Packages, Homebrew Services (the background services, like
  postgresql or redis, with Start, Stop and Restart).
- **Agent tool:** `outdated` lists what can be upgraded.
- **Requires:** Stackbar 0.26.0 or later.

## What's new in 1.6.0

- Homebrew Services: see which background services are running, and start, stop or restart them from the palette.
- The new-updates notification has an Upgrade All button.
- A notice shows when an upgrade or Update Homebrew starts, since they can take minutes.
- Searching Outdated Homebrew Packages no longer re-runs brew on every keystroke.
- Casks and formulae with the same name upgrade the right one.
- Pinned formulae offer to copy the unpin command instead of an Upgrade that would fail.
- Cask versions drop the build number (4.98.0 instead of 4.98.0,245422).
- Needs Stackbar 0.26.0.

## What's new in 1.5.0

- The desktop widget has a button: Upgrade All when there are updates, Check when there aren't. Needs Stackbar 0.21.0.

## What's new in 1.4.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.3.1

- Its own icon and colour in the Store and in Settings.
