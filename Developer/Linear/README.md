# Linear

Your Linear issues and inbox in the menu bar and the palette. The number is
how many assigned issues are in progress, or a bell with the unread count
while your inbox has something new; the panel shows new inbox entries, then
groups everything assigned to you by state, ordered by priority.

- **Needs:** `api.linear.app` and the secret `LINEAR_API_KEY`, a personal API
  key from Linear (Settings > Security & access).
- **Surfaces:** menu bar, panel, settings.
- **On each issue:** Open, Start Work (moves it to In Progress, assigns it to
  you and copies the branch name), Change Status, Set Priority, Comment, Copy
  Branch Name (Linear's own, so the branch links back to the issue), Copy
  Link, Copy ID.
- **Inbox:** assignments, mentions and comments, with a notification for each
  new one. Open marks it read.
- **Commands:** My Linear Issues, Search Linear Issues (by title, or paste an
  ID like `ENG-123` or an issue link), Linear Inbox, Change Linear Issue
  Status, Set Linear Issue Priority, Comment on Linear Issue, Create Linear
  Issue (team, title, description, priority, assign to me).
- **Settings:** what the menu-bar number counts, inbox notifications, and the
  default team for new issues.
- **Agent tool:** `assigned` lists your open issues with their branch names.

## What's new in 1.5.0

- Your Linear inbox in the panel and the palette, with a notification when something new arrives and a bell in the menu bar while it's unread.
- Start Work on any issue: In Progress, assigned to you, branch name copied.
- Change status, set priority and comment from an issue's row.
- Search finds an ID like ENG-123 or a pasted issue link, and says why when it can't search.

## What's new in 1.4.0

- Type an issue ID like ENG-42 in the palette and the issue comes up first, without opening Linear's command.
- A desktop widget shows your open issues.

## What's new in 1.3.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.2.1

- Its own icon and colour in the Store and in Settings.
