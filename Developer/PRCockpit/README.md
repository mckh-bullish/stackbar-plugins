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
  which needs write access to issues.
- **Surfaces:** menu bar, panel (To review, Mine, Issues and an optional
  Inbox), window, widget, settings.
- **Settings:** include team review requests, include drafts, notifications,
  repositories (include archived, copy clone URLs as SSH or HTTPS, reload),
  repositories to hide, and the inbox view.
- **Commands:** Search Pull Requests, Review Queue, Open Next Review, Search
  GitHub Repositories (yours first, recently opened on top, then GitHub
  search; each row opens the repository, its pull requests, issues or
  Actions, copies the clone URL, or starts a new issue), My GitHub Issues,
  Create GitHub Issue, Refresh Pull Requests.
- **Agent tools:** `review_queue`, `my_pull_requests` and `my_issues`.

## What's new in 1.4.3

- Its own icon and colour in the Store and in Settings.
