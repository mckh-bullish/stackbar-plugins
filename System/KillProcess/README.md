# Kill Process

Find a stuck process by name and end it from the palette. Choose Kill
Process and type part of the name, its command line or a pid: each row shows
the command it runs and its CPU and memory. Return asks it to quit, and
⌘⇧Return force quits it. Quitting asks once more: press again within ten
seconds. When several processes share a name, one action quits them all. The
panel lists the heaviest processes, by CPU or memory, each with its command
line.

- **Needs:** running `ps` and `kill`. Stackbar 0.26.0 or later.
- **Surfaces:** panel (the heaviest processes now), settings.
- **Commands:** Kill Process.
- **Settings:** an alert when one of your processes stays busy: on or off,
  and the line it has to stay above (50%, 90% or 150% of a core).
- **Leaves alone:** other users' processes, and loginwindow, WindowServer,
  Dock, launchd and Stackbar itself, which would log you out or freeze the
  screen.
- To free a port, use Ports; for the whole-system view, use System Monitor.

## What's new in 1.2.0

- Quit Process, Force Quit and Quit All ask once more: press again within ten seconds, so a stray Return doesn't end a process.
- A process that has quit leaves the results at once, and Stackbar says whether it ended or is still running.
- Processes with the same name show their command line, so you can tell a helper from the app. Search finds a process by its command line too.
- An optional alert, in Settings, for a process that stays busy for two minutes. Its Show button opens the search for it.
- The panel's title names the busiest process and its CPU.
- A failed scan keeps the list you had, under a note.
- Processes of Stackbar plugins are labelled "Stackbar plugin: name", and Dock is left alone.

## What's new in 1.1.0

- The panel's process list now refreshes every minute, and has a Refresh button, instead of showing what was running at launch.

## What's new in 1.0.0

- First release.
