# Timers

Countdown timers from the palette. Choose Start Timer and type a length and
a name ("10m tea", "tea 1h30", "90s", "5m30s eggs") or a clock time
("17:45 call", "5pm"). Several run at once; the soonest counts down in the
menu bar, and each ends with a sound, a notification and a message on
screen. The panel shows every timer with +1m, +5m and Cancel, and starts the
lengths you use most with one click.

- **Needs:** nothing beyond Stackbar 0.22.0 or later.
- **Surfaces:** menu bar (the soonest timer), panel, settings.
- **Commands:** Start Timer, Show Timers, Stop All Timers.
- **Settings:** the sound when a timer ends, and whether the menu bar shows
  the countdown.
- **Note:** `1:30` is a clock time; write `1h30` for an hour and a half.

## What's new in 1.0.1

- A unit written after the number is now respected: "30 seconds" is 30 seconds, "1 hour tea" is an hour, "2 hours 15 min" is two and a quarter hours, and "10minutes" works. "5 pm" with a space is a time, not 5 minutes.

## What's new in 1.0.0

- First release.
