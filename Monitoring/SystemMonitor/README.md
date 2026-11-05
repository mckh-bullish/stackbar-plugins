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

## Highlights

### CPU and memory, always in view
The menu bar shows CPU and memory. The panel adds five minutes of CPU
history, load averages, and memory and disk bars.

### Find what's slowing you down
The busiest processes are one click away, sorted by CPU or memory, each with
Copy PID and Quit Process.
<!-- preview: memory -->

### Counts memory like Activity Monitor
App memory, wired and compressed, without the file cache, so the number means
the same thing it does in Activity Monitor.

### On your desktop too
A widget shows your Mac's load without opening anything.
<!-- preview: widget -->

## What's new in 1.4.0

- A Top Processes command in the palette shows what is using your CPU and memory, and can quit it.

## What's new in 1.3.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.2.1

- Its own icon and colour in the Store and in Settings.
