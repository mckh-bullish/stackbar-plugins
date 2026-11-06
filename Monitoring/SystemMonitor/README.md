# System Monitor

CPU, memory, network and temperature in the menu bar, with the processes
using the most a click away and a notification when something stays high.

- **Needs:** to run `ps`, `sysctl`, `vm_stat`, `netstat`, `df` and `kill`
  (all come with macOS), and the Mac's temperature sensors and fans, which
  Stackbar reads for it. No network, files or secrets.
- **Surfaces:** menu bar, panel, widget, settings.
- **How it measures:** every 10 seconds, `ps` gives every process's CPU and
  memory (total CPU is their sum over the cores), `sysctl` the load,
  `vm_stat` memory the way Activity Monitor counts it (app memory, wired
  and compressed, not the file cache), `netstat` the bytes through Wi-Fi and
  Ethernet, and `df` the disk. Each answers at once, so nothing waits a
  second between two samples the way `top` does.
- **In the panel:** a CPU chart for the last five minutes, load averages,
  memory and disk, download and upload speeds with their recent history,
  CPU, GPU, SSD and battery temperatures and fan speeds (where the Mac
  reports them), and the top eight processes, each with Copy PID and Quit
  Process.
- **Alerts:** a notification when CPU stays above your line (85% by
  default) or memory above 90% for a minute, naming the busiest process,
  and when the disk is 95% full. Once per spell, then quiet for 30 minutes.
- **Settings:** what the menu bar shows (CPU and memory, CPU, memory, or
  download speed, or CPU temperature), alerts and the CPU line, and whether processes are
  sorted by CPU or memory.
- **Agent tool:** `usage` returns CPU, memory, disk, network, temperatures
  and the busiest processes.
- **Requires:** Stackbar 0.26.0 or later.

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

## What's new in 1.6.0

- Temperatures (CPU, GPU, SSD, battery) and fan speeds in the panel, and CPU temperature as a menu bar choice.

## What's new in 1.5.0

- Download and upload speeds in the panel, the widget and (if you pick it) the menu bar.
- A notification when CPU or memory stays high for a minute, naming the process behind it, and when the disk is nearly full.
- Lighter: it reads `ps` instead of running `top` for two seconds every ten.
- Updating asks once more for approval, because it now runs `ps`, `sysctl` and `netstat` instead of `top`.

## What's new in 1.4.0

- A Top Processes command in the palette shows what is using your CPU and memory, and can quit it.

## What's new in 1.3.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.2.1

- Its own icon and colour in the Store and in Settings.
