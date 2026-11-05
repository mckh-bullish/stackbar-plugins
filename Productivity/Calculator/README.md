# Calculator

Sums, unit and currency conversions and times across zones, answered right in
the command palette. Type `12*(3+4)`, `2^10`, `15% * 80`, `sqrt(2)`,
`3h in min`, `72 f to c`, `5 km in mi`, `100 usd in eur`, `$50 to gbp`,
`5pm london in tokyo` or `now in sf`, and the answer comes first in the
results. Return copies it and ⌘Return pastes it. Plain numbers and words get
no answer, so it never crowds a normal search. The panel keeps your last ten
answers.

- **Needs:** network access to `api.frankfurter.dev` for exchange rates.
  Stackbar 0.20.0 or later.
- **Surfaces:** panel.
- **Commands:** Calculate.
- **Units:** length, mass, time, data, volume and temperature.
- **Currencies:** the European Central Bank's reference rates (about 30
  currencies, updated each working day) from Frankfurter, fetched at launch
  and every six hours. `$`, `€`, `£`, `¥`, `₹` and names like `euros` work
  as well as codes.
- **Time zones:** any city in a time zone's name (`tokyo`, `new york`), plus
  common ones like `sf`, `nyc`, `bangalore`, `uk` and abbreviations like
  `pst` and `ist`. Without a starting place, the time is yours.

## What's new in 1.1.0

- Currency conversion: `100 usd in eur`, `$50 to gbp`.
- Times across zones: `5pm london in tokyo`, `now in sf`.
- Asks for network access to fetch exchange rates.

## What's new in 1.0.0

- First release: the palette's calculator, now a plugin.
