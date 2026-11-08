# Color Picker

Pick a color from anywhere on screen and copy it. Run **Pick Color** from the palette (or press the button in the panel), click any pixel with the magnifier, and the color is on your clipboard as hex, RGB or HSL.

**Picked Colors** lists the last 30 colors you picked. Return copies a color in your chosen format, and ⌘⇧X, ⌘⇧R, ⌘⇧L and ⌘⇧S copy it as hex, RGB, HSL or SwiftUI.

- **Needs:** nothing. The magnifier is macOS's own.
- **Surfaces:** panel, settings.
- **Commands:** Pick Color, Picked Colors, Convert Color (type a hex color like #0A60C8 in the palette).
- **Settings:** copy as hex (`#0A60C8`), RGB (`rgb(10, 96, 200)`), HSL (`hsl(213, 90%, 41%)`) or SwiftUI (`Color(red: 0.039, green: 0.376, blue: 0.784)`), and Clear Picked Colors.
- **Requires:** Stackbar 0.26.0 or later.

## What's new in 1.1.0

- Convert Color: type a hex color like #0A60C8 in the palette and copy it as RGB, HSL or SwiftUI.
- A new SwiftUI format: Color(red:green:blue:).
- Copying a picked color in another format now uses ⌘⇧X, ⌘⇧R, ⌘⇧L and ⌘⇧S, so ⌘1 to ⌘9 pick rows again.
- Clearing picked colors asks for a second click.

## What's new in 1.0.0

- First version: pick, copy as hex, RGB or HSL, and a list of recent colors.
