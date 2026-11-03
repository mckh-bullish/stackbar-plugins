# World Clock

The time in the cities you work with. The menu bar shows one city; the panel
lists them all with the offset from you, whether it is already tomorrow or
still yesterday there, and whether it is working hours (weekdays, 9 to 18 by
default).

- **Needs:** nothing. No network, files or secrets.
- **Surfaces:** menu bar, panel, widget, settings.
- **Settings:** the cities (type a time zone like `Asia/Tokyo`, or a city name
  like `Tokyo`), which one the menu bar shows, 12- or 24-hour time, and your
  working hours.
- **In the panel:** tap a city to show it in the menu bar. The time-travel
  slider moves every clock up to 12 hours either way in half-hour steps, so
  you can see what time it is everywhere when it's 3pm here; Now puts it back.
  The menu bar and widget always show the real time.
- **Commands:** World Clock lists your cities with their times; each row can
  be copied or shown in the menu bar.
- **Agent tool:** `times` returns the time in every city.

## What's new in 1.4.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.3.1

- Its own icon and colour in the Store and in Settings.
