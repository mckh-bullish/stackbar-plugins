# Pomodoro

A focus timer in the Stackbar look: red for focus, teal for breaks. Pick Focus or Break, a preset (25, 50 or
90 minutes of focus; 5, 10 or 15 of break), and press play. The countdown and
the ring around it move on their own, the menu bar shows the time
left (dimmed behind a pause sign while paused), and a chime and a
notification mark the end, with buttons to start the next session or take five more minutes. Today's finished sessions
and focused minutes sit under the timer, with the last seven days in a chart.

- **Needs:** nothing. No network, files or secrets.
- **Surfaces:** menu bar, panel, widget, settings.
- **In the panel:** the tag chip cycles through your tags; skip ends the
  session without counting it; Auto starts the next session on its own; the
  note turns the sound on or off; reset clears the timer.
- **Long breaks:** after four focus sessions (you can pick two to six, or
  off) the break is a long one, 15 minutes by default. Dots under the timer
  show how far you are into the round.
- **No lost sessions:** once a session is a minute in, a mode, preset, skip
  or reset tap asks first, with a banner to confirm or keep going.
- **Commands:** Start or Pause Pomodoro, Start a Focus Session (optional
  minutes and tag), Take a Break (optional minutes), Skip and Reset. Skip and
  Reset ask once a session is a minute in: run them again within 30 seconds to
  confirm. Run them from the palette, give them a hotkey, or call them from a
  Shortcut or a
  `stackbar://commands/io.navbytes.stackbar.plugins.pomodoro/<command>` link.
- **Settings:** custom focus, break and long-break lengths, how many
  sessions before a long break, a daily goal, auto-start, the sound, and your
  tags.
- **Agent tool:** `status` returns the mode, the time left, today's focus
  and the last seven days, and your daily goal.
- **Requires:** Stackbar 0.26.0 or later.

## What's new in 1.8.0

- Start a Focus Session and Take a Break take lengths like "45 minutes", "45m", "1h" or "1 hour", not only a bare number.
- Reset and Skip from the palette, a hotkey or a Shortcut now ask first once a session is a minute in: run it again within 30 seconds to confirm.
- A daily goal: pick 4 to 12 sessions in Settings, see "3/8" under the timer and a goal line on the week chart.
- A session that ended while your Mac was asleep counts on the day it ended, and Auto no longer starts the next session hours later.

## What's new in 1.7.1

- Start a Focus Session and Take a Break no longer throw away a session that is more than a minute in without asking: the first run says so, and running it again within 30 seconds replaces the session.
- The week chart no longer rebuilds its date formatter on every redraw.

## What's new in 1.7.0

- The end-of-session notification has Start Break (or Start Focus) and 5 More Minutes buttons, unless Auto is on.

## What's new in 1.6.0

- A long break every four sessions (or two to six, or off), with dots under the timer for where you are in the round.
- The last seven days of focus in a chart under the timer.

## What's new in 1.5.0

- Click the timer in the menu bar to start or pause it (turn it off in Settings to open the panel instead).
- The desktop widget has a Start/Pause button.

## What's new in 1.4.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.3.1

- Its own icon and colour in the Store and in Settings.
