# PR Cockpit

Your pull requests and the ones waiting on your review, with CI, review state
and merge conflicts, in the menu bar; the issues assigned to you; and your
repositories and new issues from the palette. It tells you when someone asks
for your review, when an issue is assigned to you, and when one of your own
pull requests is approved, gets changes requested, or fails its checks.

The separate GitHub plugin is now part of PR Cockpit. If you had it, you can
uninstall it: its repositories, assigned issues and Create GitHub Issue are
all here, with the same `GITHUB_TOKEN`.

- **Needs:** network access to `api.github.com` only, and a `GITHUB_TOKEN`
  secret kept in the Keychain. A fine-grained token with read access to pull
  requests, issues and metadata covers everything except creating issues,
  which needs write access to issues. On GitHub Enterprise Server, turn it
  on in Settings and enter the server as `GITHUB_ENTERPRISE_URL`; the plugin
  then reaches that server and no other.
- **Surfaces:** menu bar, panel (To review, Mine, Issues and an optional
  Inbox), window, widget, settings.
- **Settings:** include team review requests, include drafts, how recently a
  pull request or issue must have changed to show (any age, or the last week
  to three months), notifications, repositories (include archived, copy clone
  URLs as SSH or HTTPS, reload), repositories to hide, and the inbox view.
- **Commands:** Search Pull Requests, Review Queue, Open Next Review, Search
  GitHub Repositories (yours first, recently opened on top, then GitHub
  search; each row opens the repository, its pull requests, issues or
  Actions, copies the clone URL, or starts a new issue), My GitHub Issues,
  Create GitHub Issue, Refresh Pull Requests.
- **Agent tools:** `review_queue`, `my_pull_requests` and `my_issues`.

## Highlights

### Everything waiting on your review
Every pull request waiting on you, with its CI, review state and conflicts.
Open the next one with a single command, or snooze one until it changes.

### Your own pull requests at a glance
See which of yours passed their checks, got approved or need changes, and get
a notification the moment that changes.
<!-- preview: mine -->

### All of GitHub from the palette
Search your repositories (recently opened first), jump to their pull
requests, issues or Actions, copy a clone URL, or start a new issue.

### On your desktop too
A widget keeps the review queue in view.
<!-- preview: widget -->

## What's new in 1.8.0

- GitHub Enterprise Server: turn it on in Settings and enter your server's address. Pull requests, issues, the inbox and search all come from it.
- Updating asks once more for approval, because the plugin can now reach an Enterprise server you enter.

## What's new in 1.7.0

- Type owner/repo or repo#123 in the palette to jump straight to the repository or pull request.

## What's new in 1.6.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.5.0

- Switching tabs is quicker: a refresh now fetches pull requests, issues and
  the inbox side by side instead of one after another, and a click no longer
  waits as long behind it.
- A new **Updated within** setting shows only pull requests and issues
  changed in the last week, two weeks, month or three months, and fetches
  only those pull requests.
