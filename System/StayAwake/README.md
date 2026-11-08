# Stay Awake

Keeps your Mac awake for a while, until a time, while an app runs, on a
weekday schedule, or until you say stop. It lets go when the battery runs low,
and the host releases the sleep assertion if the plugin ever stops or
crashes, so it can't leave the Mac awake by accident.

- **Needs:** power management (the sleep assertion), through the host. Requires Stackbar 0.26.0 or later.
- **Surfaces:** menu bar, panel, widget, settings.
- **Settings:** keep the display on, the battery floor, pausing in Low Power
  Mode, a notification when it ends, what a click does, a weekday schedule,
  and staying awake while plugged in, on an external display, on a VPN or
  while downloading, and whether the menu bar shows the time left as digits
  or a ring.
- **Commands:** Toggle Stay Awake, Keep Awake For… ("2 hours", "90m", "17:30" or "until 17:30", "noon"; "1:30" is an hour and a half)
  and Allow Sleep. Allow Sleep and Toggle pause the rules for an hour when a rule is holding the Mac awake. Give them a hotkey or an alias in Stackbar's Settings, or
  run them from Spotlight, Shortcuts or a `stackbar://` link.
- **Agent tools:** `awake_status`, `keep_awake` and `allow_sleep`.

## What's new in 1.6.0

- Type durations and times the way you'd say them: "2 hours", "45 mins", "1 hour 30 minutes", "for 2h", "at 5pm", "noon", "until midnight". The panel's box takes "17:30" or "until 17:30" too.
- "until 12" late in the evening means midnight, not noon tomorrow, and "0" is no longer read as midnight.
- When "while plugged in", a display, a VPN, downloads or the schedule keeps your Mac awake, Allow Sleep, Toggle and a click on the cup pause those rules for an hour instead of saying the Mac can sleep when it can't.
- An overnight schedule with "Weekdays only" now runs through Friday night and leaves Sunday night alone.
- "Until 17:30" is right on the days the clocks change.
- The "sleep in 5 minutes" and "time's up" notifications have a button to keep it awake an hour longer.

## What's new in 1.5.1

- A very large duration (like 1e20) no longer crashes the plugin.
- Awake time is saved once a minute instead of every refresh.
- A stale error banner clears once the system status reads again.

## What's new in 1.5.0

- The desktop widget has a button: Keep Awake when the Mac sleeps normally, Stop while it's held awake. Needs Stackbar 0.21.0.

## What's new in 1.4.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.3.1

- Its own icon and colour in the Store and in Settings.
