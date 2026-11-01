# Docker

Your containers in the menu bar. The number is how many are running; the
panel lists them grouped by Compose project, with Start, Stop, Restart,
Logs, Open (for a published port), Copy ID and Remove.

- **Needs:** to run `docker`, from Docker Desktop, OrbStack, Colima or
  Rancher Desktop. No network, files or secrets of its own.
- **Surfaces:** menu bar, panel, settings.
- **How it checks:** `docker ps --all` every 15 seconds while something runs,
  every minute otherwise.
- **Settings:** show stopped containers, group by Compose project, and
  Remove Stopped Containers (`docker container prune`; images and volumes
  are left alone).
- **Commands:** Docker Containers, Docker Logs (the last 200 lines of one
  container), Remove Stopped Docker Containers.
- **Agent tool:** `containers` lists every container with its image and state.
