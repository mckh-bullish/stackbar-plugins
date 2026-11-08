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
  (SIGKILL) or copy its pid. Stop and Force Quit ask for a second press.
- **Settings:** hide ports below 1024 (or 3000).
- **Commands:** Kill Port (port, and TERM or KILL): shows what holds the port;
  Return stops it. Listening Ports.
- **Agent tool:** `listening` lists ports with their processes.

Processes owned by another user, like system services, can't be stopped
from here.

## What's new in 1.5.0

- Stop and Force Quit ask through Stackbar, naming the process and port. Kill Port's confirm row still acts at once.
- Stackbar 0.35.0 now asks for the second press itself, the same way in the panel, the palette and every window, and VoiceOver reads the question.

## What's new in 1.4.2

- Kill Port shows which process holds the port and stops it only when you press Return, so you see what you're about to end.
- Stop Process and Force Quit in the panel ask for a second press within 10 seconds.
- Stopping a process no longer makes the plugin pause for a moment.
- A process listening on both localhost and all interfaces is marked as reachable from the network.
- Searching Listening Ports reuses the list from the last few seconds.

## What's new in 1.4.1

- Ports slows its scan from every 30 seconds to every two minutes while nothing has changed, and returns to 30 seconds when a port opens or closes.

## What's new in 1.4.0

- Type a port number like 3000 or :8080 in the palette to see what is listening on it.

## What's new in 1.3.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.2.2

- Its own icon and colour in the Store and in Settings.
