# Quicklinks

Links and folders you open by name from the palette, Spotlight, a hotkey or a
link, with placeholders filled in as you go. Each quicklink becomes a command
of its own. Links use Raycast's template syntax:
`https://github.com/search?q={argument name="query"}` asks for a query,
`{clipboard}` and `{selection}` take what you copied or selected, and
`{date format="yyyy-MM-dd"}` gives today's date.

- **Needs:** opening links and folders (in the app each quicklink names), the
  clipboard, and what you had selected, for `{clipboard}` and `{selection}`.
- **Surfaces:** panel, settings.
- **Settings:** your quicklinks, and importing a Raycast export.
- **Commands:** Search Quicklinks, Create Quicklink, Import Quicklinks, Export
  Quicklinks (a file Raycast reads too), plus one command per quicklink.
