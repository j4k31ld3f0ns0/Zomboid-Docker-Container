# Project Zomboid Dedicated Server (Docker)

A custom Docker setup for hosting a Project Zomboid **Build 42** dedicated server.

## Features
* **Security:** Runs as a non-root user (`pzuser`).
* **Graceful Shutdown:** Signal trap saves the world before stopping, and tells
  a genuinely-saving server apart from a wedged one instead of always waiting
  out the full timeout.
* **Auto-Configuration:** Injects server settings via `CFG_` environment variables.
* **Real Health Checks:** Queries the player list over RCON and restarts the
  container if the server stops responding.
* **Update Safety:** Tracks the installed Steam build and backs up the world
  before a new build is allowed to open it.
* **Mod Support:** Simplified Steam Workshop integration.

---

## 🚀 Quick Start

### 1. Prerequisite Checklist
* Docker installed (25.0+ / API 1.44+ — required for `start_interval`)
* Docker Compose installed (2.24+ — required for `!override` in the test overlay)
* RAM: Java heap + ~2GB overhead. The stock config asks for 12g, so ~14GB.

### 2. Create the `.env` file

`docker-compose.yml` reads three secrets from `CustomImage_B42/.env`:

```bash
cp CustomImage_B42/.env.example CustomImage_B42/.env
# then edit it:
#   ADMIN_PASSWORD=...    admin account
#   CFG_PASSWORD=...      password players type to join
#   RCON_PASSWORD=...     also used by the health check
```

`.env` is gitignored; `.env.example` is committed as the template.

> If `RCON_PASSWORD` is empty the health check degrades to a process-liveness
> check and says so in its output. It will not silently pretend to be healthy.

### 3. Create Required Folders & Set Permissions

Because the container runs as a non-root user (UID `1000`), host directories
must exist with the right ownership to prevent "Permission Denied" crashes.

```bash
cd CustomImage_B42
mkdir -p zomboid_data server_files
sudo chown -R 1000:1000 zomboid_data server_files
```

### 4. Launch the Server

```bash
docker compose up -d
docker logs -f zomboid
```

* **First Run:** SteamCMD downloads ~7GB, then the server downloads every
  workshop mod. Expect 15–30 minutes before the server is joinable.
* The container reports `starting` for this entire period — **not** `unhealthy`.
  See [Health Checks](#-health-checks--auto-restart).

---

## ⚙️ Configuration

### Container Environment Variables

| Variable | Description | Default |
| :--- | :--- | :--- |
| `SERVER_NAME` | Save file / config name | `servertest` |
| `ADMIN_PASSWORD` | Default admin account password | `12345` |
| `PZ_JVM_MEMORY` | Java heap size (e.g. `4g`, `12g`) | `4g` |
| `HEALTH_FAIL_THRESHOLD` | Consecutive failed health checks before self-restart | `6` |
| `SHUTDOWN_TIMEOUT` | Max seconds to wait for a save on shutdown. Keep below `stop_grace_period` | `150` |
| `STALL_LIMIT` | Seconds of zero CPU **and** zero disk activity before declaring the server wedged | `30` |
| `PZ_BACKUP_KEEP` | Pre-update world backups to retain | `5` |
| `MIN_RUNTIME_SECONDS` | Server exiting sooner than this is treated as a failed launch | `60` |

### Game Settings (`CFG_` Injection)

Any variable prefixed with `CFG_` is stripped of the prefix and written into
`<SERVER_NAME>.ini` on startup. Existing keys are updated in place.

* `CFG_Public=false` — hide from the Steam server browser
* `CFG_PVP=true`
* `CFG_MaxPlayers=32`
* `CFG_RCONPassword=...` — required for the RCON health check

Full list: <https://pzwiki.net/wiki/Server_settings>

### A note on JVM memory

Build 42's launcher (`pzexe`) takes JVM arguments **only** from
`ProjectZomboid64.json`. Anything passed on the command line goes to the
*game's* argument parser, which rejects it:

```
pzexe: arg: -Xmx12g
LOG : General ...> unknown option "-Xmx12g"
```

So `start.sh` rewrites `ProjectZomboid64.json` with `jq` on every boot. This has
to happen on every boot because SteamCMD's `validate` restores the stock file
each time — editing it by hand will not survive a restart. Confirm it took hold
with:

```bash
docker logs zomboid | grep 'pzexe: vmArg'
```

---

## 🛠️ Adding Mods (Steam Workshop)

Set both the Workshop IDs (for downloading) and the Mod IDs (for loading):

```yaml
environment:
  - CFG_WorkshopItems=2611652230;2611652231
  - CFG_Mods=ModManager;AnotherModName
```

Apply with `docker compose up -d` — no rebuild needed.

---

## 🩺 Health Checks & Auto-Restart

The health check (`healthcheck.sh`) runs in three stages, each gating the next:

1. **Process alive** — `kill -0` on the PID recorded in `/tmp/pz/server.pid`.
2. **RCON listening** — TCP connect to the RCON port. Nothing is sent before this passes.
3. **Player list** — an RCON `players` round-trip, proving the game loop is
   still servicing commands rather than merely that the process exists.

> Stage 1 uses a PID file rather than a process name on purpose. Build 42
> replaced the `java ... zombie.network.GameServer` process with a native
> `./ProjectZomboid64` launcher that loads `libjvm.so` in-process, which
> silently broke name-based checks. A PID cannot go stale that way.

### Why first boot shows `starting`, not `unhealthy`

`start_period: 45m` covers a cold SteamCMD download plus mod downloads. During
the start period a failing check reports `starting` and does not count toward
`retries`. `start_interval: 10s` polls quickly during that window, and the
first success ends it immediately — so a warm restart still goes healthy within
seconds of the server finishing load.

### Restart behaviour

Failures only count toward a restart **after the server has answered RCON at
least once**. A slow first boot therefore cannot trigger a restart loop, and
neither can a wrong RCON password (restarting would not fix it).

Once the server has been healthy, `HEALTH_FAIL_THRESHOLD` consecutive failures
signal PID 1, which runs the normal save-and-quit path; `restart: unless-stopped`
brings the container back. A transient stall resets the counter and does **not**
restart.

Measured on a real hang (server SIGSTOPped):

| Phase | Duration |
| :--- | :--- |
| Detection (6 failed checks) | ~3m40s |
| Shutdown (wedge detected at 30s) | 32s |
| **Total to restart** | **~4m15s** |

Probes land ~37s apart, not 30s: `interval` is the gap *between* checks, and a
failing check spends ~10s in the RCON timeout first. To detect faster, lower
`HEALTH_FAIL_THRESHOLD` rather than `interval` — the threshold is what provides
immunity to false positives during long autosaves.

### Shutdown: saving vs. wedged

A server writing a large save and a deadlocked server both stop answering RCON,
so the shutdown does not guess from silence. It watches the launcher's CPU time
(`/proc/<pid>/stat`) and bytes written (`/proc/<pid>/io`):

* Either advancing → still saving → keep waiting, up to `SHUTDOWN_TIMEOUT`.
* Both flat for `STALL_LIMIT` → wedged → terminate immediately.

**Known limitation:** a deadlock with spinning threads keeps CPU advancing and
will still consume the full `SHUTDOWN_TIMEOUT`. Only an idle wedge exits early.

---

## 💾 Updates & World Backups

SteamCMD runs `app_update` on **every container start** with no branch or build
pinning, so a Project Zomboid update can land during a routine restart.

To keep that from silently eating a world, `start.sh`:

1. Records the installed build id in `zomboid_data/.pz_buildid`, next to the save.
2. Compares it to the build id after the update.
3. If it changed and a world exists, tars `Saves/` and `Server/` to
   `zomboid_data/backups/pre-update-<old>-to-<new>-<timestamp>.tar.gz`
   **before launching**, keeping the newest `PZ_BACKUP_KEEP`.

The backup happens after the download but before the launch, which is a genuine
"before" — the save is only at risk once the new binary opens it. **A failed
backup is fatal**: the server will not start rather than run an untested build
against an unprotected world.

The build id lives beside the save rather than in `server_files` so that wiping
and re-downloading the game cannot lose the history.

```bash
cat CustomImage_B42/zomboid_data/.pz_buildid
ls -lh CustomImage_B42/zomboid_data/backups/
```

### Install validation

Before launching, the install is checked for `start-server.sh`,
`ProjectZomboid64`, `ProjectZomboid64.json`, `java/projectzomboid.jar` and
`jre64/bin/java` — all present and non-empty. SteamCMD's exit code is logged but
not decisive, since some builds return non-zero on a good install.

### Runtime pre-flight

Project Zomboid's own `start-server.sh` tests the bundled JRE and, if it fails,
prints `Only 64bit is supported` and **exits 0** — which looks like a clean stop
to the restart policy and produces a silent crash loop. `start.sh` therefore
tests the JRE itself first and exits with a diagnostic instead.

Build 42 currently ships Zulu OpenJDK 25 against this image's Debian Bookworm
base (glibc 2.36). If a future update ships a runtime needing newer glibc, you
will see that diagnostic; the fix is to rebuild on a newer base such as
`debian:trixie-slim`.

---

## 🎮 Management Commands

> The container is named **`zomboid`** (`container_name` in `docker-compose.yml`).

```bash
# Logs
docker logs -f zomboid

# Health status and the last few check results
docker inspect --format '{{.State.Health.Status}}' zomboid
docker inspect --format '{{range .State.Health.Log}}{{.Output}}{{end}}' zomboid | tail -3

# Safe stop (saves the world; allow up to SHUTDOWN_TIMEOUT)
docker compose down

# RCON
docker exec zomboid bash -c '/usr/local/bin/rcon -a 127.0.0.1:27015 -p "$CFG_RCONPassword" players'

# Or send a command down the input pipe
docker exec zomboid sh -c 'echo "kickuser Spiffo" > /home/pzuser/zomboid.in'
```

Reading the password from the container's own environment (as above) avoids
quoting mistakes that come with extracting it from `.env` on the host.

---

## 🧪 Testing Changes

`docker-compose.test.yml` runs an isolated stack — separate world, separate
ports, small heap, no mods — so you can test without touching the live save. It
shares `./server_files` to avoid re-downloading 7GB, so **do not run it at the
same time as the production stack**.

```bash
docker compose -f docker-compose.yml -f docker-compose.test.yml -p zomboid-test up -d --build
docker compose -p zomboid-test logs -f
docker compose -p zomboid-test down && rm -rf zomboid_data_test
```

Test ports are offset (`16361`, `16362`, `8767`, `27016`). Join locally at
`127.0.0.1:16361` — Docker Desktop maps published ports onto Windows
`localhost`, but the server browser will not list it while `Public=false`.

---

## ⚠️ Troubleshooting

### "Permission Denied" errors
Docker auto-created the data folders as `root`.
```bash
docker compose down
sudo chown -R 1000:1000 zomboid_data server_files
docker compose up -d
```

### Container stuck "Restarting (127)" / "exec format error"
`start.sh` has Windows CRLF line endings. The repo's `.gitattributes` forces LF
on checkout and the Dockerfile strips CR as a backstop; if you hit this anyway,
rebuild with `docker compose up -d --build`.

### Server exits within seconds, repeatedly
Look for `server exited after Ns, before it could finish starting`. This means a
broken install or an unrunnable runtime. `start.sh` sleeps 30s before exiting so
the restart policy cannot spin — check the launcher's own error above that line.

### Health check never leaves `starting`
Expected during the first boot (up to 45m). Beyond that, check the reason:
```bash
docker inspect --format '{{range .State.Health.Log}}{{.Output}}{{end}}' zomboid | tail -3
```
* `server not launched yet` — still installing or updating.
* `RCON port ... not accepting connections yet` — still loading world/mods.
* `RCON query failed: ... authentication failed` — `RCON_PASSWORD` mismatch.
  This deliberately never triggers a restart, since restarting cannot fix it.

### Heap size seems wrong
```bash
docker logs zomboid | grep 'pzexe: vmArg'
```
If you see `unknown option "-Xmx..."`, the memory is reaching the game's arg
parser instead of the JVM — see [A note on JVM memory](#a-note-on-jvm-memory).

### `libjsig.so ... cannot be preloaded: ignored`
Harmless. Project Zomboid's own `start-server.sh` sets `LD_PRELOAD=libjsig.so`
without a path. It is a warning, not a failure.

---

## 📁 Repository Layout

```
CustomImage_B42/
├── dockerfile               # Debian bookworm + SteamCMD + jq + rcon-cli
├── start.sh                 # entrypoint: update, validate, back up, launch, shutdown
├── healthcheck.sh           # three-stage health check
├── docker-compose.yml       # production stack
├── docker-compose.test.yml  # isolated test overlay
├── .env                     # secrets (gitignored)
├── .env.example             # template for .env
├── server_files/            # game install (SteamCMD, gitignored)
└── zomboid_data/            # worlds, configs, backups, .pz_buildid (gitignored)

.gitattributes               # forces LF so Windows checkouts cannot break the scripts
.gitignore                   # keeps secrets, the 7GB install and saves out of git
```
