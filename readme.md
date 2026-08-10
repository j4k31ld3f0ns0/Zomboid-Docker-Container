# Project Zomboid Dedicated Server (Docker)

A custom Docker setup for hosting a Project Zomboid Dedicated Server.

## Features
* **Security:** Runs as a non-root user (`pzuser`).
* **Graceful Shutdown:** Utilizes a signal trap to save world data cleanly before stopping.
* **Auto-Configuration:** Injects server settings dynamically via `CFG_` environment variables.
* **Mod Support:** Simplified Steam Workshop integration.

---

## 🚀 Quick Start

### 1. Prerequisite Checklist
* Docker installed
* Docker Compose installed
* At least 10GB RAM available (8GB for Java Heap + 2GB for OS overhead)

### 2. Create Required Folders & Set Permissions
Because the container runs as a non-root user (UID `1000`), host directories must be manually created with proper ownership to prevent "Permission Denied" crashes.

Run these commands in the directory containing your `docker-compose.yml`:

```bash
# Create the data directories
mkdir -p zomboid_data server_files mod_watcher_state

# Set ownership to UID 1000 (standard Linux user)
sudo chown -R 1000:1000 zomboid_data server_files mod_watcher_state
```

### 3. Launch the Server

```bash
docker compose up -d
```

* **First Run:** SteamCMD will take 5–10 minutes to download game files.
* **Check Progress:** View real-time initialization logs using:
  ```bash
  docker logs -f project-zomboid-server
  ```

---

## ⚙️ Configuration

Server settings can be managed directly through `docker-compose.yml` environment variables without editing `.ini` files manually.

### Common Environment Variables

| Variable | Description | Default |
| :--- | :--- | :--- |
| `SERVER_NAME` | Name of the save file and config entry | `servertest` |
| `ADMIN_PASSWORD` | Password for the default admin account | `ChangeThis...` |
| `PZ_JVM_MEMORY` | Java Heap Size allocation (e.g., `4g`, `8g`) | `4g` |

### Game Settings (`CFG_` Injection)
Any environment variable prefixed with `CFG_` is automatically stripped and appended to `servertest.ini` on startup.

**Examples:**
* `CFG_Public=false` (Sets server to private)
* `CFG_Password=secret` (Sets a join password)
* `CFG_PVP=true` (Enables PVP)
* `CFG_MaxPlayers=32` (Sets maximum player capacity)

---

## 🛠️ Adding Mods (Steam Workshop)

To add mods, update the `environment` section in your `docker-compose.yml` with both the Workshop ID (for downloading) and the Mod ID (for loading):

```yaml
environment:
  # List of Workshop IDs (Numbers) separated by semicolons
  - CFG_WorkshopItems=2611652230;2611652231

  # List of Mod IDs (Names) separated by semicolons
  - CFG_Mods=ModManager;AnotherModName
```

**Apply Changes:**
```bash
docker compose up -d
```
*(No container rebuild needed).*

---

## 🔄 Automatic Mod Updates (`mod-watcher`)

The stack includes a `mod-watcher` sidecar that polls the Steam Workshop API for
changes to your subscribed mods and restarts the server when one is published.

### How the restart works (and why there's no Docker socket)

A sidecar that restarts a container would normally mount `/var/run/docker.sock`,
which is effectively root on the host. This one doesn't need it:

1. `mod-watcher` detects an updated mod and warns players via RCON `servermsg`.
2. It waits for the server to empty out, then sends RCON `save` and `quit`.
3. The game process exits, so `start.sh` finishes and the container stops.
4. `pz-server`'s `restart: unless-stopped` policy starts it again, which re-runs
   `steamcmd +app_update` — and that's what actually downloads the new mod files.

Docker itself performs the restart, so the watcher never touches the Docker API.
It runs unprivileged with a read-only filesystem and all capabilities dropped;
its only reach is outbound HTTPS to Steam and RCON to the game server.

> **Keep the mod lists in sync.** `WORKSHOP_ITEMS` on `mod-watcher` must match
> `CFG_WorkshopItems` on `pz-server`, or updates to the missing mods won't be seen.

### Watcher Environment Variables

| Variable | Description | Default |
| :--- | :--- | :--- |
| `WORKSHOP_ITEMS` | Semicolon-separated Workshop IDs to watch | *(required)* |
| `POLL_INTERVAL_SECONDS` | How often to check Steam for updates | `600` |
| `MAX_RESTART_WAIT_SECONDS` | How long to wait for an empty server before forcing a restart | `3600` |
| `EMPTY_CHECK_INTERVAL_SECONDS` | How often to re-check the player count while waiting | `60` |
| `EMPTY_RESTART_GRACE_SECONDS` | Pause after the server empties, in case of a reconnect | `10` |
| `FORCED_RESTART_WARNING_SECONDS` | Notice given before a forced (non-empty) restart | `300` |
| `SHUTDOWN_TIMEOUT_SECONDS` | How long to wait for the RCON port to close before declaring failure | `120` |

If a restart can't be confirmed, the watcher leaves its saved timestamps
untouched and retries on the next poll — so a transient failure self-heals
rather than silently skipping the update.

### Watcher Logs
```bash
docker logs -f pz-mod-watcher
```

---

## 🎮 Management Commands

### Safely Stopping the Server
This container includes a trap script that sends a `/quit` command to save world state cleanly upon stopping.

```bash
docker compose down
```
> **Note:** Allow 10–20 seconds for the save process to complete before forcibly terminating.

### Viewing Logs
```bash
docker logs -f project-zomboid-server
```
*(Press `Ctrl + C` to exit the log stream).*

### RCON / Console Access
The server exposes RCON on port `27015`. You can use clients like `rcon-cli` or `Arrcon`.

Alternatively, send commands directly via the input pipe:

```bash
# Example: Kick a user named Spiffo
docker exec project-zomboid-server sh -c 'echo "kickuser Spiffo" > /home/pzuser/zomboid.in'
```

---

## ⚠️ Troubleshooting

### 1. "Permission Denied" Errors
* **Cause:** Running `docker compose up` before creating folders causes Docker to auto-create them as `root`.
* **Fix:** Stop the container, update ownership, and restart:
  ```bash
  docker compose down
  sudo chown -R 1000:1000 zomboid_data server_files
  docker compose up -d
  ```

### 2. Server Stuck "Restarting (127)"
* **Cause:** `start.sh` has Windows CRLF line endings instead of Linux LF.
* **Fix:** Rebuild the image to execute the line-ending converter in the Dockerfile:
  ```bash
  docker compose up -d --build
  ```

### 3. "SteamCMD: Command not found"
* **Cause:** Incorrect binary path within the container.
* **Fix:** Verify `start.sh` references the absolute path `/usr/games/steamcmd/steamcmd.sh`.