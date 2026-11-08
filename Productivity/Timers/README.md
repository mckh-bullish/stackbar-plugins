# Timers

Countdown timers from the palette. Choose Start Timer and type a length and
a name ("10m tea", "tea 1h30", "90s", "5m30s eggs") or a clock time
("17:45 call", "5pm"). Several run at once; the soonest counts down in the
menu bar, and each ends with a sound, a notification and a message on
screen. The panel shows every timer with +1m, +5m, Pause and Cancel, and starts the
lengths you use most with one click.

- **Needs:** nothing beyond Stackbar 0.35.0 or later.
- **Surfaces:** menu bar (the soonest timer), panel, settings.
- **Commands:** Start Timer, Show Timers, Stop All Timers.
- **Settings:** the sound when a timer ends, and whether the menu bar shows
  the countdown.
- **Note:** `1:30` is a clock time; write `1h30` for an hour and a half.
  `noon`, `midnight` and `at 12` are clock times too.

## What's new in 1.2.0

- Cancel Timer asks through Stackbar, naming the timer.
- Stackbar 0.35.0 now asks for the second press itself, the same way in the panel, the palette and every window, and VoiceOver reads the question.

## What's new in 1.1.0

- "tea for 3 min", "in 10 minutes pasta" and "at 5 pm call" no longer put "for", "in" or "at" in the timer's name.
- "lunch at 12" sets an alarm for the next 12 o'clock instead of a 12-minute timer; "noon", "midnight" and "5.30pm" work too.
- Clock times are right on the days the clocks change.
- Pause and resume a timer from the panel or Show Timers.
- The "done" notification has Again and 5 More Minutes buttons.
- Stop All Timers asks you to run it again within 10 seconds when more than one is running.
- Several timers ending together come as one notification.

## What's new in 1.0.1

- A unit written after the number is now respected: "30 seconds" is 30 seconds, "1 hour tea" is an hour, "2 hours 15 min" is two and a quarter hours, and "10minutes" works. "5 pm" with a space is a time, not 5 minutes.

## What's new in 1.0.0

- First release.
