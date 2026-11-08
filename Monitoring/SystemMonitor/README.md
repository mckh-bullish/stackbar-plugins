# System Monitor

CPU, memory, network and temperature in the menu bar, with the processes
using the most a click away and a notification when something stays high.

- **Needs:** to run `ps`, `sysctl`, `vm_stat`, `netstat`, `df` and `kill`
  (all come with macOS), and the Mac's temperature sensors and fans, which
  Stackbar reads for it. No network, files or secrets.
- **Surfaces:** menu bar, panel, widget, settings.
- **How it measures:** every 10 seconds, `ps` gives every process's CPU and
  memory (total CPU is their sum over the cores), `sysctl` the load, memory
  pressure and swap, `vm_stat` memory the way Activity Monitor counts it (app
  memory, wired and compressed, not the file cache), `netstat` the bytes
  through Wi-Fi and Ethernet, and `df` the disk. Each answers at once, so
  nothing waits a second between two samples the way `top` does.
- **In the panel:** memory pressure and swap, a CPU chart for the last five
  minutes, load averages, memory and disk bars, download and upload speeds
  with their recent history, CPU, GPU, SSD and battery temperatures and fan
  speeds (where the Mac reports them), and the top eight processes, each with
  Copy PID and Quit Process. Top Processes lists every process.
- **Quitting:** Quit Process asks once more: press it again within ten
  seconds. Stackbar says whether the process ended. It never offers to quit
  loginwindow, WindowServer, Dock, launchd, kernel_task or Stackbar itself.
- **Alerts:** a notification when CPU stays above your line (85% by
  default) for a minute, naming the busiest process; when memory pressure is
  Warning or Critical for a minute; and when the disk is 95% full. Once per
  spell, then quiet for 30 minutes (six hours for the disk).
- **Settings:** what the menu bar shows (CPU and memory, CPU, memory, download
  speed, or CPU temperature), and the alerts and the CPU line.
- **Agent tool:** `usage` returns CPU, memory, pressure, swap, disk, network,
  temperatures and the busiest processes.
- **Requires:** Stackbar 0.26.0 or later.

## Highlights

### CPU and memory, always in view
The menu bar shows CPU and memory. The panel adds five minutes of CPU
history, load averages, memory pressure, and memory and disk bars.

### Find what's slowing you down
The busiest processes are one click away, sorted by CPU or by memory in use
(resident), each with Copy PID and Quit Process.
<!-- preview: memory -->

### Counts memory like Activity Monitor
App memory, wired and compressed, without the file cache, so the totals match
what Activity Monitor shows.

### Temperatures and fans
CPU, GPU, SSD and battery temperatures, and fan speeds where the Mac has
fans.
<!-- preview: sensors -->

### On your desktop too
A widget shows your Mac's load without opening anything.
<!-- preview: widget -->

## What's new in 1.7.0

- Top Processes lists every process, not just the first eight, and searching it no longer re-reads the Mac on every keystroke.
- The CPU chart and the busy alert count real minutes, so opening Top Processes or changing the sort no longer makes the chart fill faster.
- Memory alerts follow memory pressure, as macOS reports it, instead of a fixed 90% used. The panel shows the pressure and the swap in use.
- Quit Process asks you to press it again within ten seconds, and tells you whether the process ended.
- When a reading can't be taken, the panel says how old its numbers are instead of showing zeros. Network speed shows a dash until it can be read again.
- Busy alerts have a Show Processes button that opens Top Processes.
- Disk sizes match Finder (1 GB is 1,000 MB). Memory is still counted the way Activity Monitor counts it.
- Process names show the program's file name, also for programs started from a relative path.

## What's new in 1.6.1

- A reading that flaps around a threshold no longer notifies again within the 30 minutes (six hours for the disk) after an alert.

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
