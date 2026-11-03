# Homebrew

What Homebrew can upgrade, in the menu bar. The number is how many formulae
and casks are outdated; the panel lists them with Upgrade on each row and
Upgrade All at the bottom.

- **Needs:** to run `brew` (Stackbar finds it in `/opt/homebrew/bin` or
  `/usr/local/bin` and asks you to approve that path once). No network,
  files or secrets of its own.
- **Surfaces:** menu bar, panel, settings.
- **How it checks:** hourly and on wake it runs `brew outdated --json=v2`,
  which reads what Homebrew already knows. When that list is more than 6 hours
  old it runs `brew update` first (from the second check after launch, so
  the list shows right away), so the count doesn't go stale; the panel says
  how old the list is. Update Homebrew fetches it now.
- **Settings:** show casks, hide pinned formulae, include casks that update
  themselves (`--greedy`), fetch the latest formulae every 6 hours (on by
  default), and a notification when new updates appear.
- **Commands:** Upgrade All Homebrew Packages, Update Homebrew, Outdated
  Homebrew Packages.
- **Agent tool:** `outdated` lists what can be upgraded.

## What's new in 1.3.0

- Runs `brew update` in the background when the formula list is more than 6 hours old (setting, on by default), so "Everything's fresh" is never said from a stale list.
- Says how old the list is, and shows it straight away after launch while the update runs.
