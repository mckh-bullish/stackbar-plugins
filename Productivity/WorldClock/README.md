# World Clock

The time in the cities you work with. The menu bar shows one city; the panel
lists them all with the offset from you, whether it is already tomorrow or
still yesterday there, and whether it is working hours (weekdays, 9 to 18 by
default).

- **Needs:** nothing beyond Stackbar 0.22.0 or later. No network, files or secrets.
- **Surfaces:** menu bar, panel, widget, settings.
- **Settings:** the cities (type a time zone like `Asia/Tokyo`, or a city name
  like `Tokyo`), which one the menu bar shows, 12- or 24-hour time, and your
  working hours.
- **In the panel:** tap a city to show it in the menu bar. The time-travel
  slider moves every clock up to 12 hours either way in half-hour steps, so
  you can see what time it is everywhere when it's 3pm here; Now puts it back.
  Copy times copies every city's time, at the slider's time, for an invite.
  The menu bar and widget always show the real time.
- **Commands:** World Clock lists your cities with their times; each row can
  be copied or shown in the menu bar. Copy My Cities' Times copies every
  city's time now.
- **Agent tool:** `times` returns the time in every city.

## Highlights

### Every city you work with
Each city shows its offset from you, whether it is already tomorrow there, and
whether it is working hours.

### Find a time that works everywhere
Slide up to 12 hours either way and every clock moves with you, so you can see
what 3pm here means for everyone. Now puts it back.
<!-- preview: plan -->

### Type a city, not a time zone
Add `Tokyo` or `Asia/Tokyo`, and pick which city the menu bar shows.

### On your desktop too
A widget keeps your cities on the desktop.
<!-- preview: widget -->

## What's new in 1.6.0

- Type the cities people actually say: Mumbai, Bangalore, San Francisco, Beijing, São Paulo, and in "time in …" also NYC, SF, PST or UTC. A question mark at the end is fine, and so is the curly apostrophe in "what’s the time in".
- A name typed in full wins: "time in ist" shows India and "time in la" Los Angeles first, ahead of cities that only start with those letters.
- A city added by its own name keeps that name, so Mumbai shows as Mumbai.
- Settings tells you when it can't find a city, or when it's already in your list.
- Copy times: one click copies every city's time at the slider's time, ready to paste into an invite. Also a Copy My Cities' Times command.
- Removing the city shown in the menu bar now moves the menu bar to your next city, and so does a city this Mac no longer recognises, instead of an empty menu bar.
- Lighter on redraws: each clock no longer rebuilds its date formatter.

## What's new in 1.5.1

- Night-shift working hours (like 22:00 to 06:00) now work.
- Settings no longer crashes on an out-of-range stored hour.

## What's new in 1.5.0

- Type a city like Tokyo in the palette to see its time right away.

## What's new in 1.4.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.3.1

- Its own icon and colour in the Store and in Settings.
