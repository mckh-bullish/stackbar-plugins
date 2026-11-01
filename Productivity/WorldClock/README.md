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
- **In the panel:** each row can be pinned to the menu bar or copied.
- **Agent tool:** `times` returns the time in every city.
