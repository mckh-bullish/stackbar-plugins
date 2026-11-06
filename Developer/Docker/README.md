# Docker

Your containers in the menu bar. The number is how many are running; the
panel lists them grouped by Compose project, each with its CPU and memory,
Start, Stop, Restart, Logs, Open (for a published port), Copy ID and Remove,
and each project with Start all, Restart and Stop.

- **Needs:** to run `docker`, from Docker Desktop, OrbStack, Colima or
  Rancher Desktop. No network, files or secrets of its own.
- **Surfaces:** menu bar, panel, settings.
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
- **Settings:** show stopped containers, group by Compose project, the
  trouble notification (on by default), and
  Remove Stopped Containers (`docker container prune`; images and volumes
  are left alone).
- **Commands:** Docker Containers, Docker Compose Projects, Stop All Docker
  Containers, Docker Logs (the last 200 lines of one container), Remove
  Stopped Docker Containers.
- **Agent tool:** `containers` lists every container with its image, state,
  CPU and memory.

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
