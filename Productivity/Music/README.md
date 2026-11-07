# Music

What's playing in Music or Spotify, in the menu bar. Click it to play or
pause; right-click for the panel with the track, Previous, Next and volume.

- **Needs:** to run `osascript`, the only way to talk to Music and Spotify.
  The install sheet warns that osascript can run any program; this plugin
  only sends the fixed scripts in its source. macOS asks once whether
  Stackbar may control Music or Spotify.
- **Surfaces:** menu bar, panel, widget, settings.
- **How it checks:** every 5 seconds, and only players that are already
  running; it never opens one.
- **Settings:** which player to follow (whichever is playing, Music or
  Spotify) and what the menu bar shows (title and artist, title, or just
  the icon).
- **Commands:** Play or Pause Music, Next Track, Previous Track, Copy
  Current Track.
- **Agent tool:** `now_playing` describes the current track.

## What's new in 1.4.1

- With neither Music nor Spotify open, it checks every 30 seconds instead of every 5, and goes back to 5 as soon as a player is running or you click.
- Dragging the volume slider sends a few values and the last one instead of one per step, so the volume no longer lags or snaps back.
- A slow cover lookup no longer holds up play, pause and skip, and a failed one is retried after a minute.

## What's new in 1.4.0

- The desktop widget has Play/Pause and Next buttons. Needs Stackbar 0.21.0.

## What's new in 1.3.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.2.1

- Its own icon and colour in the Store and in Settings.
