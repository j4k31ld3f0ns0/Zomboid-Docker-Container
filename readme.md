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
* Docker Compose installed (2.24.4+ — required for `!override` in the test overlay)
* RAM: Java heap + ~2GB overhead. The stock config asks for 12g, so ~14GB.

### 2. Create your compose file

There is no compose file at the repo root, so **every `docker compose` command
below runs from `Build42/`.** Paths written as `Build42/...` are relative to the
repo root; every other path is relative to `Build42/`.

```bash
cd Build42
cp docker-compose.example.yml docker-compose.yml
```

`docker-compose.yml` is gitignored and `docker-compose.example.yml` is the
committed template, so your edits survive a `git pull` and are never clobbered
by one — the same arrangement as `.env` / `.env.example` below.

Open it before your first boot. The template carries the full production stack
and every explanatory comment, but the Workshop and mod ids in it are
placeholders marked `REPLACE` — see
[Adding Mods (Steam Workshop)](#️-adding-mods-steam-workshop).

### 3. Create the `.env` file

`docker-compose.yml` reads three secrets from `Build42/.env`:

```bash
cp .env.example .env
# then edit it:
#   ADMIN_PASSWORD=...    admin account
#   SERVER_PASSWORD=...   password players type to join
#   RCON_PASSWORD=...     also used by the health check
```

`.env` is gitignored; `.env.example` is committed as the template.

> **Upgrading an existing `.env`?** `SERVER_PASSWORD` used to be called
> `CFG_PASSWORD`. Rename that one line. The old name was wrong: `start.sh` writes
> *every* `CFG_`-prefixed variable into the `.ini` with the prefix stripped, so it
> added a junk `PASSWORD=` key the game never reads. The key players actually
> authenticate against is `Password`, set separately by `CFG_Password` in
> `docker-compose.yml` — which is what now reads `SERVER_PASSWORD`.

> If `RCON_PASSWORD` is empty the health check degrades to a process-liveness
> check and says so in its output. It will not silently pretend to be healthy.

### 4. Create Required Folders & Set Permissions

Because the container runs as a non-root user (UID `1000`), host directories
must exist with the right ownership to prevent "Permission Denied" crashes.

```bash
mkdir -p zomboid_data server_files mod_watcher_state sandbox_config
sudo chown -R 1000:1000 zomboid_data server_files mod_watcher_state
```

`mod_watcher_state` is easy to overlook because the watcher is a sidecar, but it
is a bind mount into a non-root container exactly like the other two. Skip it and
mod-watcher cannot record its baseline — see the troubleshooting entry below.

`sandbox_config` is deliberately **not** chowned: it is mounted read-only, so
the container never writes to it. It still has to be created by hand, because a
directory Docker creates for you belongs to `root` and you would then need
`sudo` just to drop a file into it. Leaving it empty is fine — see
[Sandbox Settings](#sandbox-settings-pz_sandbox_source).

### 5. Launch the Server

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
| `PZ_JVM_EXTRA_ARGS` | Extra JVM args, space separated, appended to `vmArgs` | unset |
| `PZ_SANDBOX_SOURCE` | Path **inside the container** to a sandbox `.cfg`/`.ini` or `SandboxVars.lua` to install. Unset disables the feature | unset |
| `PZ_SANDBOX_FORCE` | `true` re-installs the sandbox file even if the source is unchanged | unset |
| `CFG_RCONPort` | RCON port. Injected into the `.ini` **and** read by the health check | `27015` |
| `HEALTH_FAIL_THRESHOLD` | Consecutive failed health checks before self-restart | `6` |
| `SHUTDOWN_TIMEOUT` | Max seconds to wait for a save on shutdown. Keep below `stop_grace_period` | `150` |
| `STALL_LIMIT` | Seconds of zero CPU **and** zero disk activity before declaring the server wedged | `30` |
| `PZ_BACKUP_KEEP` | Pre-update world backups to retain | `5` |
| `MIN_RUNTIME_SECONDS` | Server exiting sooner than this is treated as a failed launch | `60` |
| `STARTUP_STALL_LIMIT` | Seconds of no meaningful progress during boot before the startup is called wedged | `300` |
| `STARTUP_MIN_TICKS_PER_SEC` | CPU ticks/sec that count as real work during boot | `5` |
| `STARTUP_MIN_BYTES_PER_SEC` | Bytes/sec written that count as real work during boot | `10240` |

### Game Settings (`CFG_` Injection)

Any variable prefixed with `CFG_` is stripped of the prefix and written into
`<SERVER_NAME>.ini` on startup. Existing keys are updated in place.

* `CFG_Public=false` — hide from the Steam server browser
* `CFG_PVP=true`
* `CFG_MaxPlayers=32`
* `CFG_RCONPassword=...` — required for the RCON health check

Full list: <https://pzwiki.net/wiki/Server_settings>

**Known limit: a value cannot contain `|`.** `start.sh` updates an existing key
with `sed "s|^$key=.*|$key=$val|"` and escapes only `&`, so a pipe in the value
terminates the expression and corrupts the line. No stock Project Zomboid setting
needs one; a mod option that does has to be written into the `.ini` by hand.

**`CFG_`-prefixed names are injected verbatim**, minus the prefix. Do not name an
unrelated variable `CFG_ANYTHING` in `.env` or compose expecting it to be ignored
— it becomes an `.ini` key. This is why the join password is
`SERVER_PASSWORD` rather than `CFG_PASSWORD`.

### Sandbox Settings (`PZ_SANDBOX_SOURCE`)

The `.ini` above is only half the configuration. The other half — zombie counts,
loot rarity, day length, every mod's own options — lives in
`zomboid_data/Server/<SERVER_NAME>_SandboxVars.lua`, inside a **gitignored**
bind mount. `PZ_SANDBOX_SOURCE` is an **optional** override for it.

Point it at a file mounted into the container and `start.sh` installs it on
boot. Both shapes of input work, decided by content rather than by file
extension:

| Source | What happens |
| :--- | :--- |
| A ready `SandboxVars.lua` | Validated, then copied verbatim |
| A single-player sandbox `.cfg` / `.ini` | Converted by `pzConfigConverter.py`, validated, then installed |

Already wired up in `docker-compose.yml`:

```yaml
    environment:
      PZ_SANDBOX_SOURCE: "/config/sandbox.lua"
    volumes:
      - ./sandbox_config:/config:ro
```

**`sandbox_config/` is gitignored and starts out empty.** Sandbox settings are
local server config, not repo content, so nothing is shipped for you.

| What is at the source path | What the server does |
| :--- | :--- |
| Nothing (empty `sandbox_config/`, no mount) | Starts on the game's **default** sandbox settings — or on the existing `<SERVER_NAME>_SandboxVars.lua` if there is one. Logged as a `WARNING:`. |
| A valid `.cfg` / `.ini` / `SandboxVars.lua` | Installed as `<SERVER_NAME>_SandboxVars.lua` |
| A file that is present but **invalid** | **The server refuses to start**, with the reason in the log |

That last row is deliberate: a broken source means the server would silently run
settings nobody chose, and for a brand-new world some of those are fixed at world
generation.

Quick Start step 4 already creates this directory. Do not skip it and let Docker
create it for you: that copy is owned by `root`, and you will need `sudo` to put a
file in it.

**To seed it**, either copy the running server's own file:

```bash
cp zomboid_data/Server/MySurvivorServer_SandboxVars.lua sandbox_config/sandbox.lua
```

or drop in a single-player preset from `Zomboid/Sandbox Presets/*.cfg`
(Windows: `%USERPROFILE%\Zomboid\Sandbox Presets`) and point
`PZ_SANDBOX_SOURCE` at it — `.cfg`, `.ini` or `.lua`, the name does not matter.

**When it re-applies.** The sha256 of the source is recorded in
`zomboid_data/.pz_sandbox_source.sha256` after each successful install, and the
file is only rewritten when that hash changes (or when the destination is
missing, e.g. after a `SERVER_NAME` rename). That is deliberate: sandbox changes
made in-game through the admin panel are written back to the same file, and
re-installing on every boot would silently throw them away. To push the mounted
file over an in-game change, set `PZ_SANDBOX_FORCE=true` for one boot.

**Safety net.** The previous version is always kept as
`<SERVER_NAME>_SandboxVars.lua.bak`, and a source that fails to validate is never
installed — the file already on disk is left byte-for-byte intact.

Check what happened with:

```bash
docker logs zomboid | grep -A5 'Applying sandbox settings'
```

### Converting a preset by hand

`pzConfigConverter.py` also runs on the host if you would rather do the
conversion yourself:

```bash
python3 pzConfigConverter.py "map_sand.cfg" MySurvivorServer
python3 pzConfigConverter.py --check MySurvivorServer_SandboxVars.lua
```

It refuses to write a file it knows the server cannot use: a category split
across two places in the `.cfg` (Lua would keep only the last block), a
duplicated key, unbalanced braces, or a missing `VERSION` line. Values are typed
as booleans, numbers or quoted strings, dotted keys become nested tables, and
comments and blank lines are carried across so the result stays hand-editable.

Values are typed from what they look like: `true`/`false` become booleans,
numerals become numbers, everything else becomes a quoted string. A `.cfg`
carries no type information, so to keep a numeric-looking value as *text* —
some mods declare options like a drop rate of `.1` as a string — quote it:

```ini
PhunCure.DefDropRate=".1"     # stays the string ".1"
PhunCure.DefDropRate=.1       # becomes the number .1
```

Known limit: an inline comment (`Zombies=4 # some note`) becomes part of the
value, because stripping it would corrupt any legitimate value containing `#`.
Put comments on their own line.

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

Set both the Workshop IDs (for downloading) and the Mod IDs (for loading). These
are **two separate edits in two places**, and neither block is a YAML list:

```yaml
# 1. Top of docker-compose.yml. The single source of truth for downloads:
#    pz-server's CFG_WorkshopItems and mod-watcher's WORKSHOP_ITEMS are both
#    *workshop_items, so editing here updates both and they cannot drift.
x-workshop-items: &workshop_items "2611652230;2611652231"
```

```yaml
# 2. Under pz-server's environment:. The load order, separate from the download
#    list because one Workshop item can ship several mods.
    environment:
      CFG_Mods: "ModManager;AnotherModName"
```

> **Do not edit `CFG_WorkshopItems` or `WORKSHOP_ITEMS` directly**, and do not
> convert either `environment:` block to a `- KEY=value` list. Both keys are YAML
> aliases of the anchor above, and an alias substitutes a whole node rather than a
> fragment of a string — which only works if the block is a mapping.
> Replacing an alias with a literal is exactly the drift the anchor prevents.

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

### Failed startups that hang

A fatal script error does not always exit the process: Project Zomboid logs
`Server Terminated.` and the JVM can stay resident. `start.sh` only notices a
server that *exits*, so without extra help the container would sit in `starting`
for the whole 45m `start_period` and then stay `unhealthy` forever — a crash
that reads like a slow boot.

The health check therefore watches boot progress the same way the shutdown does,
but on a **rate**, not on change: a crashed-but-resident JVM still burns ~0.5 CPU
ticks/sec from background threads, and keeps dribbling bytes to disk (~56
bytes/sec measured on a real crash), so "did anything change" never fires on
either signal. **Both** are therefore measured as rates. If the server stays
under `STARTUP_MIN_TICKS_PER_SEC` *and* `STARTUP_MIN_BYTES_PER_SEC` for
`STARTUP_STALL_LIMIT`, the startup is judged wedged, and that verdict latches so
the restart threshold is reached in a few checks rather than a few stall windows.
Real work in a later window clears the latch, so a transient stall self-heals.

**Detection can take up to 2x `STARTUP_STALL_LIMIT`.** Progress is averaged over
a fixed window, so the window that happens to span the moment of failure is
diluted by the work done before it and resets instead of latching; only the next
full window is entirely idle. Observed on a real crash: the straddling window
showed ~31 ticks/sec and 407MB written and correctly declined to latch, while a
sample taken minutes later showed 3 ticks in 10s and zero writes. So budget
~10 minutes at the default 300s, not ~5.

Note this restarts on a *deterministic* startup failure too, such as a mod with a
broken recipe — each loop costs a full boot. Check the logs rather than assuming
a restart loop is transient.

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
cat zomboid_data/.pz_buildid
ls -lh zomboid_data/backups/
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

> **The mod list is defined once.** `x-workshop-items` at the top of
> `docker-compose.yml` is a YAML anchor that both `CFG_WorkshopItems` and
> `WORKSHOP_ITEMS` alias, so they cannot drift. Add or remove a mod there and
> both services see it. Because YAML aliases substitute whole nodes rather than
> fragments of a string, both `environment:` blocks are mappings
> (`KEY: "value"`) rather than `- KEY=value` lists.

### Watcher Environment Variables

| Variable | Description | Default |
| :--- | :--- | :--- |
| `WORKSHOP_ITEMS` | Workshop IDs to watch. Aliased from `x-workshop-items`, shared with `CFG_WorkshopItems` | *(required)* |
| `RCON_PASSWORD` | RCON password. Read with `os.environ[...]`, so an unset value is a hard startup failure, not a default | *(required)* |
| `RCON_HOST` | Compose service name of the game server, on the internal network | `pz-server` |
| `RCON_PORT` | Must match the server's `CFG_RCONPort` | `27015` |
| `STATE_FILE` | Where the mod-timestamp baseline is written, inside the `./mod_watcher_state` mount | `/state/mod_watcher_state.json` |
| `POLL_INTERVAL_SECONDS` | How often to check Steam for updates | `600` |
| `MAX_RESTART_WAIT_SECONDS` | How long to wait for an empty server before forcing a restart | `3600` |
| `EMPTY_CHECK_INTERVAL_SECONDS` | How often to re-check the player count while waiting | `60` |
| `EMPTY_RESTART_GRACE_SECONDS` | Pause after the server empties, in case of a reconnect | `10` |
| `FORCED_RESTART_WARNING_SECONDS` | Notice given before a forced (non-empty) restart | `300` |
| `SHUTDOWN_TIMEOUT_SECONDS` | How long to wait for the RCON port to close before declaring failure | `120` |

`docker-compose.yml` raises `SHUTDOWN_TIMEOUT_SECONDS` to `300`; the `120` above
is the code default that applies if you drop the line. Every other default in this
table is the code's, not compose's.

If a restart can't be confirmed, the watcher leaves its saved timestamps
untouched and retries on the next poll — so a transient failure self-heals
rather than silently skipping the update.

### Interaction with the health check

Both the watcher and the health check talk to the server over RCON, and both
tolerate the other:

* The first-run baseline needs only the Steam API, so the watcher starts cleanly
  next to a server still doing its 15–30 minute first boot. `depends_on`
  deliberately does **not** use `condition: service_healthy` — against a 45m
  `start_period` that would make `docker compose up -d` block.
* If a mod update lands while RCON is unreachable, the watcher skips the restart
  and retries next cycle instead of failing.
* During a watcher-initiated restart the server stops answering RCON, so the
  health check begins counting failures. A normal save finishes long before the
  6-failure threshold (a clean idle shutdown measured 8s). If it ever did not,
  the health check would signal the same save-and-quit path the watcher already
  triggered — they agree rather than fight, and the shutdown's stall detection
  sees the save still making progress and lets it finish.
* `SHUTDOWN_TIMEOUT_SECONDS` must exceed the worst-case save. Set too low, the
  watcher calls a successful restart "unconfirmed", never commits the new
  timestamps, and restarts a second time on the next poll.

### Watcher Logs
```bash
docker logs -f pz-mod-watcher
```

### Testing the restart algorithm

The player-presence branches are impractical to test against a live server: the
forced-restart path needs `MAX_RESTART_WAIT_SECONDS` to elapse (an hour by
default) with someone actually logged in, and the "count unavailable" path needs
RCON broken in a specific way. `test_restart_logic.py` runs the real
`graceful_restart()` against a stub RCON server serving a scripted sequence of
player counts, so every branch runs deterministically in seconds:

```bash
docker compose run --rm --no-deps --entrypoint python mod-watcher test_restart_logic.py
```

| Scenario | Expected |
| :--- | :--- |
| Server already empty | restarts immediately |
| Players online, then leave | defers, restarts once empty |
| Stays occupied past the cap | warns players, restarts anyway |
| Player count unparseable | treated as occupied, ends in a forced restart |

The stub answers auth with two packets exactly as a real server does, so it also
guards against a regression to the single-read handshake bug.

`--no-deps` matters: mod-watcher `depends_on` pz-server, and without it
`docker compose run` starts the game server too — a ~7GB SteamCMD
download to run a test that finishes in seconds.

To exercise the empty path against the *real* server instead, seed a stale
timestamp and let the watcher poll immediately:

```bash
python3 -c "import json;p='mod_watcher_state/mod_watcher_state.json';d=json.load(open(p));d[sorted(d)[0]]=1;json.dump(d,open(p,'w'))"
docker compose restart mod-watcher
```

For the occupied path end-to-end, do the same with someone logged in and
`MAX_RESTART_WAIT_SECONDS` temporarily lowered, then have them disconnect.

### Verifying the Watcher (`probe.py`)

The watcher spends most of its life doing nothing, so a broken assumption can sit
unnoticed until the day it actually needs to restart the server. `probe.py` checks
those assumptions on demand:

```bash
docker compose exec mod-watcher python probe.py
```

It is strictly read-only — it authenticates over RCON and runs the `players`
command, but never sends `save`, `quit`, or `servermsg`, and never writes the
state file. It is safe to run on a populated server. Exit status is `0` when
nothing failed.

What it checks:

* **RCON packet alignment.** Build 42 *does* send an empty `RESPONSE_VALUE`
  before the `AUTH_RESPONSE`, which is exactly the off-by-one this check was
  written to catch — command output came back empty and a wrong password was
  silently accepted. `_authenticate()` now drains to the `AUTH_RESPONSE`, and the
  check exercises that function directly rather than counting packets.
* **Player count parsing.** That the real `players` output matches
  `PLAYER_COUNT_RE`. If it doesn't, `rcon_player_count()` returns `None`, which
  the watcher treats as "occupied" — so it would never restart on an empty
  server and would always wait out `MAX_RESTART_WAIT_SECONDS` instead.
* **Steam API reachability**, plus any configured mod IDs Steam has no entry for
  (delisted, private, or mistyped) — those are silently skipped by update checks.
* **State file writability**, the usual cause being a root-owned
  `./mod_watcher_state` mount versus the container's UID 1000.
* **Pending restarts** — whether the recorded baseline already differs from
  current Steam timestamps.

Run it once with the server empty and once with someone connected; the zero-player
and non-zero paths parse differently. Two optional flags:

| Flag | Purpose |
| :--- | :--- |
| `--test-bad-password` | Also confirm a wrong password is rejected. Off by default, since some RCON implementations throttle or ban on failed auth. |
| `--skip-steam` | RCON checks only. Skips the Steam API check **and the state-file checks**, so it proves nothing about the mount permissions above. |
| `--timeout N` | RCON socket timeout in seconds (default `10`). |

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
ports, small heap, no mods, no watcher — so you can test without touching the
live save. It shares `./server_files` to avoid re-downloading 7GB, so **do not run
it at the same time as the production stack**.

The overlay does not override `env_file`, so the test stack reads the same
`Build42/.env` as production and will not start without it.

`mod-watcher` is held back by `profiles: ["watcher"]`. Left enabled it would
collide with the production container on `container_name`, inherit the full
production Workshop list, and resolve `RCON_HOST: pz-server` to the **test**
server — which it can `quit` over RCON in the middle of a test. Append
`--profile watcher` to the `up` line below if you actually want to exercise it.

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

### "Permission Denied" errors / `the container user cannot write to its volumes`
`zomboid_data/` and `server_files/` are gitignored, so a fresh clone does not
contain them — and Docker creates a missing bind-mount path as `root`, while the
container runs as non-root `pzuser` (uid 1000).

`start.sh` checks this before SteamCMD runs and stops with the owner of each
unwritable path, rather than booting a server that silently has no `.ini` (no
admin password, no RCON, default player limit). The fix:
```bash
docker compose down
sudo chown -R 1000:1000 zomboid_data server_files
docker compose up -d
```

`mod-watcher` hits the same thing on `./mod_watcher_state`, and it is easier to
miss because the game server keeps running normally. The symptom in
`docker logs pz-mod-watcher` is a `PermissionError` on
`/state/mod_watcher_state.json.tmp`, or — since the watcher now refuses to start
rather than looping — a container stuck restarting with the owning uid printed.
The fix is the same:
```bash
docker compose stop mod-watcher
sudo mkdir -p mod_watcher_state
sudo chown -R 1000:1000 mod_watcher_state
docker compose up -d mod-watcher
```

> Before the pre-flight check existed this failed *silently*: `save_state()` threw
> every cycle, the error was logged as "will retry next interval", and the
> watcher went on polling forever without ever committing a baseline — so no mod
> update was ever detected. If you are reading old logs, a repeating
> "Baseline established for N mod(s)." line is that bug, not a healthy watcher.

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
Build42/
├── dockerfile               # Debian bookworm + SteamCMD + jq + rcon-cli
├── start.sh                 # entrypoint: update, validate, back up, launch, shutdown
├── healthcheck.sh           # three-stage health check
├── pzConfigConverter.py     # sandbox .cfg/.ini -> SandboxVars.lua (also runs on the host)
├── docker-compose.example.yml # tracked template -- copy to docker-compose.yml
├── docker-compose.yml       # your live stack, copied from the example (gitignored)
├── docker-compose.test.yml  # isolated test overlay
├── sandbox_config/          # optional sandbox source, mounted read-only at
│                            #   /config (gitignored; empty = game defaults)
├── mod_watcher/             # workshop update watcher (see below)
│   ├── dockerfile           # python:3.12-slim, unprivileged, no Docker socket
│   ├── requirements.txt     # requests, pinned
│   ├── mod_watcher.py       # poll Steam, restart server when mods change
│   ├── probe.py             # read-only RCON/Steam/state diagnostic
│   └── test_restart_logic.py # restart branches vs. a stub RCON server
├── mod_watcher_state/       # watcher's recorded mod timestamps
├── .env                     # secrets (gitignored)
├── .env.example             # template for .env
├── server_files/            # game install (SteamCMD, gitignored)
└── zomboid_data/            # worlds, configs, backups, .pz_buildid (gitignored)

.gitattributes               # forces LF so Windows checkouts cannot break the scripts
.gitignore                   # keeps secrets, local compose, the install and saves out of git
```
