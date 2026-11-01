# Homebrew

What Homebrew can upgrade, in the menu bar. The number is how many formulae
and casks are outdated; the panel lists them with Upgrade on each row and
Upgrade All at the bottom.

- **Needs:** to run `brew` (Stackbar finds it in `/opt/homebrew/bin` or
  `/usr/local/bin` and asks you to approve that path once). No network,
  files or secrets of its own.
- **Surfaces:** menu bar, panel, settings.
- **How it checks:** hourly and on wake it runs `brew outdated --json=v2`,
  which reads what Homebrew already knows. Update Homebrew runs `brew update`
  to fetch the latest first.
- **Settings:** show casks, hide pinned formulae, include casks that update
  themselves (`--greedy`), and a notification when new updates appear.
- **Commands:** Upgrade All Homebrew Packages, Update Homebrew, Outdated
  Homebrew Packages.
- **Agent tool:** `outdated` lists what can be upgraded.
