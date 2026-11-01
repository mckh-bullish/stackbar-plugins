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
