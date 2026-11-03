# Docker

Your containers in the menu bar. The number is how many are running; the
panel lists them grouped by Compose project, with Start, Stop, Restart,
Logs, Open (for a published port), Copy ID and Remove.

- **Needs:** to run `docker`, from Docker Desktop, OrbStack, Colima or
  Rancher Desktop. No network, files or secrets of its own.
- **Surfaces:** menu bar, panel, settings.
- **How it checks:** `docker ps --all` every 15 seconds while something runs,
  every minute otherwise.
- **When something goes wrong:** a container that crashes (exits with an
  error on its own), turns unhealthy or keeps restarting sends a notification,
  turns the menu bar red with a count, and gets a banner in the panel until
  it is started again or removed. Stops from the panel don't count.
- **Settings:** show stopped containers, group by Compose project, the
  trouble notification (on by default), and
  Remove Stopped Containers (`docker container prune`; images and volumes
  are left alone).
- **Commands:** Docker Containers, Docker Logs (the last 200 lines of one
  container), Remove Stopped Docker Containers.
- **Agent tool:** `containers` lists every container with its image and state.

## What's new in 1.3.0

- Tells you when a container crashes, turns unhealthy or keeps restarting: a notification (setting, on by default), a red count in the menu bar, a banner in the panel and a crashed badge on the row.
- Stopping a container yourself, from the panel, `docker stop` or Ctrl-C, doesn't count as a crash.
- A bolder look on the Stackbar design system.
