# Docker

Your containers in the menu bar. The number is how many are running; the
panel lists them grouped by Compose project, each with its CPU and memory,
Start, Stop, Restart, Open Shell, Logs, Open (for a published port), Copy ID
and Remove,
and each project with Start all, Restart and Stop.

- **Needs:** to run `docker`, from Docker Desktop, OrbStack, Colima or
  Rancher Desktop. No network, files or secrets of its own. Open Shell
  needs to open your terminal app.
- **Surfaces:** menu bar, panel, window (logs), widget, settings.
- **How it checks:** `docker ps --all` every 15 seconds while something runs,
  every minute otherwise, and one `docker stats --no-stream` snapshot while
  anything runs.
- **Compose:** a project's buttons run `docker compose -p <project>
  start|stop|restart`, which finds the project from its containers, so no
  compose file is needed.
- **When something goes wrong:** a container that crashes (exits with an
  error on its own), turns unhealthy or keeps restarting sends a notification,
  turns the menu bar red with a count, and gets a banner in the panel until
  it is started again or removed. Stops from the panel don't count.
- **Settings:** group by Compose project, the trouble notification (on by
  default), and Remove Stopped Containers (press again within 10 seconds;
  it removes the stopped containers with `docker rm`, and images and volumes
  are left alone).
- **Commands:** Docker Containers, Docker Compose Projects, Stop All Docker
  Containers, Docker Logs (the last 200 lines of one container), Remove
  Stopped Docker Containers. Stop All Docker Containers and Remove Stopped
  Docker Containers each show the containers they will act on, and act when
  you press Return on that row.
- **Open Shell** (⌘T on a running container) opens your terminal app in
  `docker exec -it <container>`, with bash when the image has it.
- **Requires:** Stackbar 0.26.0 or later.
- **Agent tool:** `containers` lists every container with its image, state,
  CPU and memory.

## What's new in 1.8.0

- Stop All Docker Containers: press Return on the row that says what it will stop. Remove Stopped Docker Containers: press Return on the row that says what it will remove. Remove Stopped Containers in Settings asks for a second press within 10 seconds.
- Removing a container asks for a second press, since its files are gone afterwards. Stopping one still takes a single click, because Start brings it back.
- A notice shows while a container or project is stopping, starting or restarting.
- Paused containers can be resumed; Start used to fail on them.
- "Docker isn't running" now also shows for newer Docker versions and for a Docker that has stopped answering.
- A crash notification has a Show Logs button.
- The CPU and memory totals no longer count containers that have stopped.

## What's new in 1.7.1

- The logs window stops refreshing on its own two minutes after you open it or press Refresh, instead of polling for the rest of the session.
- While Docker is down, it checks once a minute instead of every 15 seconds.
- The Containers and Compose commands reuse a list read a few seconds ago while you type.

## What's new in 1.7.0

- Open Shell on a running container opens your terminal app inside it.

## What's new in 1.6.0

- CPU and memory for every running container, and the totals at the top of the panel.
- Start, restart or stop a whole Compose project from its section, or from the new Docker Compose Projects command.
- Stop All Docker Containers, from the palette or a hotkey.

## What's new in 1.5.0

- A container's logs open in their own window, so you can keep them beside your editor while the panel closes.

## What's new in 1.4.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.3.1

- Its own icon and colour in the Store and in Settings.
