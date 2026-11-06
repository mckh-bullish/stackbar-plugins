# Kill Process

Find a stuck process by name and end it from the palette. Choose Kill
Process and type part of the name (or a pid): each row shows its CPU and
memory, Return asks it to quit, and ⌘⇧Return force quits it. When several
processes share a name, one action quits them all. The panel lists the
heaviest processes, by CPU or memory.

- **Needs:** running `ps` and `kill`. Stackbar 0.22.0 or later.
- **Surfaces:** panel (the heaviest processes now).
- **Commands:** Kill Process.
- **Leaves alone:** other users' processes, and loginwindow, WindowServer,
  launchd and Stackbar itself, which would log you out or freeze the screen.

## What's new in 1.0.0

- First release.
