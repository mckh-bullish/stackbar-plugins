# Stay Awake

Keeps your Mac awake for a while, until a time, while an app runs, on a
weekday schedule, or until you say stop. It lets go when the battery runs low,
and the host releases the sleep assertion if the plugin ever stops or
crashes, so it can't leave the Mac awake by accident.

- **Needs:** power management (the sleep assertion), through the host.
- **Surfaces:** menu bar, panel, widget, settings.
- **Settings:** keep the display on, the battery floor, pausing in Low Power
  Mode, a notification when it ends, what a click does, a weekday schedule,
  and staying awake while plugged in, on an external display, on a VPN or
  while downloading.
- **Agent tools:** `awake_status`, `keep_awake` and `allow_sleep`.
