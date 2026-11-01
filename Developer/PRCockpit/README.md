# PR Cockpit

Your pull requests and the ones waiting on your review, with CI, review state
and merge conflicts, in the menu bar. It tells you when someone asks for your
review, and when one of your own pull requests is approved, gets changes
requested, or fails its checks.

- **Needs:** network access to `api.github.com` only, and a `GITHUB_TOKEN`
  secret kept in the Keychain. A fine-grained token with read access to pull
  requests is enough.
- **Surfaces:** menu bar, panel, window, widget, settings.
- **Settings:** include team review requests, include drafts, notifications,
  repositories to hide, and the inbox view.
- **Commands:** Search Pull Requests, Review Queue, Open Next Review, Refresh
  Pull Requests.
- **Agent tools:** `review_queue` and `my_pull_requests`.
