# Jira

Your Jira issues in the menu bar and the palette, on Jira Cloud or Jira Data
Center. The number is how
many assigned issues are in progress; the panel lists them, in progress
first.

- **Needs:** `*.atlassian.net` and the secret `JIRA_API_TOKEN`, an API token
  from id.atlassian.com (Security > API tokens). Your site and email are set
  in Settings. On Data Center, `JIRA_SERVER_URL` is your server's address and
  `JIRA_API_TOKEN` a personal access token; the plugin reaches that server
  and no other.
- **Surfaces:** menu bar, panel, widget, settings.
- **On each issue:** Open, Change Status (the issue's own workflow), Comment,
  Assign to Me (on issues that aren't yours yet), Watch, Copy Link, Copy Key,
  Copy Branch Name (`ABC-123-short-summary`, which Jira's development panel
  links).
- **Notifications:** when an issue is newly assigned to you; Highest and
  Blocker issues say so in the title. Turn it off in Settings.
- **Commands:** My Jira Issues, Search Jira (text, a key like `ABC-123`, or a
  pasted issue link), Change Jira Issue Status, Comment on Jira Issue, Create
  Jira Issue (project, type, summary, description).
- **Settings:** Cloud or Data Center, site, email, the JQL behind the menu
  bar and panel (open issues assigned to you by default), notifications,
  and the default project for new issues.
- **Agent tool:** `assigned` lists your open issues.

## What's new in 1.6.0

- Paste a Jira issue link into Search Jira to open that issue.
- Switching to another API token no longer announces every issue on that account as newly assigned, and Assign to Me and Watch act as the new account.
- Projects created since you set up Jira show up in Create Jira Issue (the list refreshes hourly).
- Search Jira waits until you pause typing instead of asking Jira on every keystroke.
- A slow or unreachable Jira holds up clicks for less time.

## What's new in 1.5.1

- Your assigned and done lists load past the first 50 issues (up to 200).
- Typing in My Jira Issues, Change Status and Jira Issue by Key no longer asks Jira again on every keystroke; a lookup that failed says why.
- Changing the site, email or JQL no longer announces the new list as freshly assigned.
- A workflow's transitions are looked up again after a minute, so a status changed elsewhere shows up in Change Jira Issue Status.

## What's new in 1.5.0

- Change an issue's status, comment on it, assign it to yourself or watch it, from its row.
- A notification when an issue is assigned to you, louder for Highest and Blocker.
- Jira Data Center: pick it in Settings and enter your server and a personal access token.
- Updating asks once more for approval, because the plugin can now reach a Data Center server you enter.

## What's new in 1.4.0

- Type an issue key like ABC-123 in the palette and the issue comes up first, without opening Jira's command.
- A desktop widget shows your open issues.

## What's new in 1.3.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.2.2

- Its own icon and colour in the Store and in Settings.
