# System Monitor

CPU and memory in the menu bar, with the processes using the most a click
away.

- **Needs:** to run `top`, `vm_stat`, `df` and `kill` (all come with
  macOS). No network, files or secrets.
- **Surfaces:** menu bar, panel, widget, settings.
- **How it measures:** every 10 seconds, `top` takes two one-second samples
  (the second is the accurate one), `vm_stat` gives memory the way Activity
  Monitor counts it (app memory, wired and compressed, not the file cache),
  and `df` the disk.
- **In the panel:** a CPU chart for the last five minutes, load averages,
  memory and disk bars, and the top eight processes, each with Copy PID and
  Quit Process.
- **Settings:** what the menu bar shows (CPU and memory, CPU, or memory)
  and whether processes are sorted by CPU or memory.
- **Agent tool:** `usage` returns CPU, memory, disk and the busiest processes.

## What's new in 1.2.1

- Its own icon and colour in the Store and in Settings.
