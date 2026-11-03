# Jira

Your Jira Cloud issues in the menu bar and the palette. The number is how
many assigned issues are in progress; the panel lists them, in progress
first.

- **Needs:** `*.atlassian.net` and the secret `JIRA_API_TOKEN`, an API token
  from id.atlassian.com (Security > API tokens). Your site and email are set
  in Settings.
- **Surfaces:** menu bar, panel, settings.
- **On each issue:** Open, Copy Link, Copy Key, Copy Branch Name
  (`ABC-123-short-summary`, which Jira's development panel links).
- **Commands:** My Jira Issues, Search Jira (text, or a key like `ABC-123`),
  Create Jira Issue (project, type, summary, description).
- **Settings:** site, email, the JQL behind the menu bar and panel (open
  issues assigned to you by default), and the default project for new
  issues.
- **Agent tool:** `assigned` lists your open issues.

Jira Server and Data Center aren't supported: only Atlassian's cloud sites.

## What's new in 1.2.2

- Its own icon and colour in the Store and in Settings.
