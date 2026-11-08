# Git Sync

Which of your local git repositories are behind their remote, ahead of it,
diverged or holding uncommitted changes, in the menu bar, with the safe
ones updated in one click. Worktrees show under their repository, and the
merged ones left behind are cleaned up in one go.

- **Needs:** to run `git` and `find` (Stackbar finds them in `/usr/bin` or
  Homebrew and asks you to approve those paths once), your SSH agent for
  remotes over SSH, and to open folders in your editor, terminal or Finder.
  It never reads your files itself: git runs only in the folders you
  choose, and each plugin's Settings page lists them with Remove. Needs
  Stackbar 0.35.0 or later, and git (the Xcode Command Line Tools or
  Homebrew's).
- **Surfaces:** menu bar (only when something is behind, by default),
  panel, window, widget, settings.
- **How it checks:** it finds the repositories in your folders (2 levels
  deep by default; skipping `node_modules`, `.build`, `Pods` and the like),
  and reads each with `git status --porcelain=v2 --branch` every two
  minutes, which uses no network. `git fetch --prune --no-tags` runs every
  15 minutes per repository, a few repositories a minute, and on wake; it
  never changes your files. Prompts are off, so a remote that wants a
  password says so instead of waiting.
- **Updating:** Pull is fast-forward only (or rebase, in Settings), so it
  never makes a merge commit. A repository with uncommitted changes is
  skipped, or stashed, pulled and restored, or offered on its row, as you
  choose; if restoring conflicts, your changes stay in the stash. Diverged
  repositories always wait for you. Push never forces. Update All does
  every repository that is safe to, three at a time, and says what it
  skipped and why.
- **Worktrees:** a count on each repository, and under it each worktree's
  branch, ↓↑, changes and last commit, with Agent (Claude Code, Codex,
  Conductor), Locked, Merged and Missing labels. Remove one (only when
  clean), prune missing ones, or Clean Up every worktree whose branch was
  merged or deleted on the remote. A branch that was never pushed is never
  offered for clean-up. Changes in a worktree outside your folders show as
  unknown, with Add its folder.
- **Settings:** your folders and how deep to look in each, how often to
  check the remote, fast-forward or rebase, what to do with uncommitted
  changes, worktrees shown and included in Update All, where new worktrees
  go (next to the repository, a `.worktrees` folder inside it, or a folder
  you choose), every local branch in the window, the menu bar (when behind,
  always, never) and whether it counts unpushed repositories, the editor
  and terminal to open in, notifications (never, when a repository falls
  behind, or only when you have unpushed work too), and hidden
  repositories.
- **Commands:** Search Local Repositories (also in the palette's own
  results), Update All Repositories, Fetch All Repositories, Search
  Worktrees, Clean Up Worktrees, New Git Worktree.
- **Agent tool:** `repo_status` lists each repository's state.

## Highlights

### What's behind, at a glance
Every repository by what it needs: behind, not pushed, diverged or with
changes. Update the safe ones with one click.
<!-- preview: hero -->

### Worktrees under their repository
See every worktree's branch and state, spot the ones agents made, and clean
up the merged ones.
<!-- preview: worktrees -->

### On your desktop too
A widget with what's behind and unpushed, and an Update button.
<!-- preview: widget -->

## What's new in 1.1.0

- Clean Up asks through Stackbar before it removes merged worktrees, naming how many.
- Stackbar 0.35.0 now asks for the second press itself, the same way in the panel, the palette and every window, and VoiceOver reads the question.

## What's new in 1.0.0

- First release.
