# System Commands

Lock, sleep, restart, empty the Trash or switch to dark mode from the command
palette, by name: type `lock`, `sleep`, `empty trash` or `dark mode` and press
Return. Restart, Shut Down, Log Out, Empty Trash and Quit Other Apps open a
second row that says what happens, so nothing is lost to a stray Return.
Give any of them an alias or a hotkey in Settings › Commands.

- **Needs:** system actions (`.systemActions`). macOS asks once to let
  Stackbar control System Events (restart, shut down, log out, dark mode) and
  Finder (the Trash). Locking the screen uses Stackbar's Accessibility access.
  Stackbar 0.35.0 or later.
- **Surfaces:** panel, which lists every command.
- **Commands:** Lock Screen, Sleep, Sleep Displays, Start Screen Saver, Toggle
  Dark Mode, Hide Other Apps, Eject All Disks, Empty Trash, Quit Other Apps,
  Log Out, Restart, Shut Down.

## What's new in 1.1.0

- Restart, Shut Down, Log Out and the other destructive commands ask through Stackbar, naming what they do.
- Stackbar 0.35.0 now asks for the second press itself, the same way in the panel, the palette and every window, and VoiceOver reads the question.

## What's new in 1.0.2

- When an action can't run (for example, Stackbar isn't allowed to control System Events, or there's no disk to eject), it now says why instead of doing nothing.
- Clicking a confirmation that has run out now tells you to click again within 10 seconds.

## What's new in 1.0.1

- Restart, Shut Down, Log Out, Empty Trash and Quit Other Apps in the panel forget their first click after 10 seconds, so a click out of habit later can't run one on its own.

## What's new in 1.0.0

- First release.
