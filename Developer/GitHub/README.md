# GitHub

GitHub from the palette: jump to any of your repositories, see the issues
assigned to you, and file a new issue without opening a browser first. For
pull requests and review requests in the menu bar, use PR Cockpit, which
ships with Stackbar.

- **Needs:** `api.github.com` and the secret `GITHUB_TOKEN`, the same one PR
  Cockpit uses. A fine-grained token with read access to metadata and issues
  covers everything except creating issues, which needs write access to
  issues.
- **Surfaces:** panel, settings. No menu-bar item.
- **Search GitHub Repositories:** your repositories and those of your
  organizations, recently opened first, then GitHub search for anything
  else. Each row opens the repository, its issues, pull requests or Actions,
  copies the clone URL, or starts a new issue there.
- **My GitHub Issues:** open issues assigned to you.
- **Create GitHub Issue:** repository, title and Markdown description; the
  new issue opens in your browser.
- **Settings:** include archived repositories, copy clone URLs as SSH or
  HTTPS, reload.
