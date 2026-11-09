# Calculator

Sums, unit and currency conversions and times across zones, answered right in
the command palette. Type `12*(3+4)`, `2^10`, `15% * 80`, `sqrt(2)`,
`3h in min`, `72 f to c`, `5 km in mi`, `100 usd in eur`, `$50 to gbp`,
`5pm london in tokyo` or `now in sf`, and the answer comes first in the
results. Return copies it. Plain numbers and words get
no answer, so it never crowds a normal search. The panel keeps your last ten
answers.

- **Needs:** network access to `api.frankfurter.dev` for exchange rates.
  Stackbar 0.21.0 or later.
- **Settings:** turn currency conversion off, and Calculator makes no
  network requests at all.
- **Surfaces:** panel, settings.
- **Commands:** Calculate.
- **Units:** length, mass, time, data, volume, speed and temperature, including
  mixed amounts such as `5 ft 10 in to cm` or `1h 30min in min`.
- **Currencies:** the European Central Bank's reference rates (about 30
  currencies, updated each working day) from Frankfurter, fetched at launch
  and every six hours. `$`, `€`, `£`, `¥`, `₹` and names like `euros` work
  as well as codes.
- **Dates:** `days until dec 20`, `days since jan 1`, `weeks until
  christmas`, `today + 3 weeks`, `in 10 days`.
- **Time zones:** any city in a time zone's name (`tokyo`, `new york`), plus
  common ones like `sf`, `nyc`, `bangalore`, `uk` and abbreviations like
  `pst` and `ist`. Without a starting place, the time is yours.

## What's new in 1.7.0

- Date math: `days until dec 20`, `weeks until christmas`, `days since 2026-01-01`, `today + 3 weeks`, `in 10 days`, `friday - 2 days`.

## What's new in 1.6.0

- Adding or taking off a percent works the way you'd expect: 100 + 10% is 110 and 200 - 15% is 170.
- Speeds: 60 mph in km/h, 10 m/s in mph, knots.
- The constant e works, as in 2*e or e^2.
- On a Mac that writes decimal commas, answers use a decimal comma too, so they paste straight into your spreadsheet.
- Opening Calculate with nothing typed lists your recent answers.
- A currency sum with no exchange rates says why (offline, or conversion turned off), and dividing by zero says so, instead of asking for a sum.
- Accented city names work: now in são paulo.
- Removed Paste Answer, which never worked: Calculator has no clipboard access. Return still copies the answer.

## What's new in 1.5.0

- Mixed amounts convert: `5 ft 10 in to cm`, `1h 30min in min`.

## What's new in 1.4.0

- A decimal comma works: 2,5*2 is 5 and 1,5 km in m is 1500 m. A comma is a thousands separator only when it can be one (1,000 and 1,234.56 as before), and on a Mac that writes decimal commas it is always the decimal mark.
- If the exchange rates can't be fetched (offline at launch, say), it tries again after 30 seconds, 2, 10 and 30 minutes, and on wake, instead of waiting six hours.
- Time-zone answers no longer rebuild a date formatter and a pattern on every keystroke.
- Indian digit grouping works: 1,00,000 and 12,34,567 are read as lakhs and crores. A lone . or , is no longer a number.

## What's new in 1.3.0

- The answer is always first in the palette, above a past answer to the
  same sum that the panel keeps.
- The palette only asks Calculator about text that can have an answer.

## What's new in 1.2.0

- A setting to turn currency conversion off. Off, no exchange rates are
  fetched and the plugin never goes online.

## What's new in 1.1.0

- Currency conversion: `100 usd in eur`, `$50 to gbp`.
- Times across zones: `5pm london in tokyo`, `now in sf`.
- Asks for network access to fetch exchange rates.

## What's new in 1.0.0

- First release: the palette's calculator, now a plugin.
