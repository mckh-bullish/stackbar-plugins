# Ports

Which process is listening on which TCP port, and a way to stop it. The
command you'll use most is **Kill Port** from the palette: type `3000` and
whatever holds it is asked to stop.

- **Needs:** to run `lsof` and `kill` (both come with macOS). No network,
  files or secrets.
- **Surfaces:** panel, settings. No menu-bar item.
- **In the panel:** every listening port with its process and pid, marked
  local (127.0.0.1 or ::1 only) or open (all interfaces). Each row can open
  `http://localhost:<port>`, stop the process (SIGTERM), force quit it
  (SIGKILL) or copy its pid.
- **Settings:** hide ports below 1024 (or 3000).
- **Commands:** Kill Port (port, and TERM or KILL), Listening Ports.
- **Agent tool:** `listening` lists ports with their processes.

Processes owned by another user, like system services, can't be stopped
from here.

## What's new in 1.3.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.2.2

- Its own icon and colour in the Store and in Settings.
