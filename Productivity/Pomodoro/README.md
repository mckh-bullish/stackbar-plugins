# Pomodoro

A focus timer in the Stackbar look: red for focus, teal for breaks. Pick Focus or Break, a preset (25, 50 or
90 minutes of focus; 5, 10 or 15 of break), and press play. The countdown and
the ring around it move on their own, the menu bar shows the time
left (dimmed behind a pause sign while paused), and a chime and a
notification mark the end. Today's finished sessions
and focused minutes sit under the timer.

- **Needs:** nothing. No network, files or secrets.
- **Surfaces:** menu bar, panel, widget, settings.
- **In the panel:** the tag chip cycles through your tags; skip ends the
  session without counting it; Auto starts the next session on its own; the
  note turns the sound on or off; reset clears the timer.
- **No lost sessions:** once a session is a minute in, a mode, preset, skip
  or reset tap asks first, with a banner to confirm or keep going.
- **Commands:** Start or Pause Pomodoro, Start a Focus Session (optional
  minutes and tag), Take a Break (optional minutes), Skip and Reset. Run them
  from the palette, give them a hotkey, or call them from a Shortcut or a
  `stackbar://commands/io.navbytes.stackbar.plugins.pomodoro/<command>` link.
- **Settings:** custom focus and break lengths, auto-start, the sound, and
  your tags.
- **Agent tool:** `status` returns the mode, the time left and today's focus.
- **Requires:** Stackbar 0.14.0 or later.
