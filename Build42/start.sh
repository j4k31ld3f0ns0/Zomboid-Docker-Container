#!/bin/bash

# Define directories
INSTALL_DIR="/home/pzuser/server"
DATA_DIR="/home/pzuser/Zomboid"
SERVER_NAME="${SERVER_NAME:-servertest}"
CONFIG_FILE="$DATA_DIR/Server/${SERVER_NAME}.ini"
PIPE="/home/pzuser/zomboid.in"
APPMANIFEST="$INSTALL_DIR/steamapps/appmanifest_380870.acf"
BUILDID_STATE="$DATA_DIR/.pz_buildid"
BACKUP_DIR="$DATA_DIR/backups"
PZ_BACKUP_KEEP="${PZ_BACKUP_KEEP:-5}"

# Every file the server needs to actually launch. The old check looked only for
# start-server.sh, which a truncated download can easily satisfy on its own.
REQUIRED_FILES="start-server.sh ProjectZomboid64 ProjectZomboid64.json java/projectzomboid.jar jre64/bin/java"

# "buildid"  "24775771"  ->  24775771. Empty if the manifest is absent.
read_buildid() {
    [ -f "$APPMANIFEST" ] || return 0
    awk -F\" '/^[[:space:]]*"buildid"/ {print $4; exit}' "$APPMANIFEST"
}

install_is_complete() {
    for f in $REQUIRED_FILES; do
        if [ ! -s "$INSTALL_DIR/$f" ]; then
            echo "    missing or empty: $f"
            return 1
        fi
    done
    return 0
}

world_exists() {
    [ -d "$DATA_DIR/Saves" ] && [ -n "$(ls -A "$DATA_DIR/Saves" 2>/dev/null)" ]
}

# Can the container user actually create and write files here? The mkdir is part
# of the test, not setup: creating a subdirectory is the first thing that fails
# when Docker has created the bind-mount path as root.
dir_is_writable() {
    mkdir -p "$1" 2>/dev/null || return 1
    probe="$1/.pz_write_test"
    touch "$probe" 2>/dev/null || return 1
    rm -f "$probe"
    return 0
}

# Snapshot Saves (the world) and Server (ini / sandbox / spawn config).
backup_world() {
    from="$1"
    to="$2"
    out="$BACKUP_DIR/pre-update-${from}-to-${to}-$(date +%Y%m%d-%H%M%S).tar.gz"

    mkdir -p "$BACKUP_DIR" || return 1
    echo "--- Backing up world before first launch on build $to ---"
    echo "    $out"

    if ! tar -czf "$out" -C "$DATA_DIR" Saves Server; then
        echo "ERROR: backup failed."
        rm -f "$out"
        return 1
    fi
    echo "    done ($(du -h "$out" | cut -f1))"

    # Keep only the newest PZ_BACKUP_KEEP archives so disk use stays bounded.
    ls -1t "$BACKUP_DIR"/pre-update-*.tar.gz 2>/dev/null | tail -n "+$((PZ_BACKUP_KEEP + 1))" | while read -r old; do
        echo "    pruning $(basename "$old")"
        rm -f "$old"
    done
    return 0
}

# 1. Setup Pipe
rm -f "$PIPE"
mkfifo "$PIPE"
chmod 600 "$PIPE"

# 1b. Reset health-check state.
# /tmp survives a "docker restart", so a stale "ready" marker from the previous
# run would make healthcheck.sh treat this boot as a degraded server and kick
# off a restart loop. Clear it before the server starts.
rm -rf /tmp/pz
mkdir -p /tmp/pz

# 2. Setup Directories & Ensure Permissions
# Force creation and ensure the container user owns them.
# NOTE: this chown is a no-op in normal operation and must not be mistaken for
# the safety net -- start.sh is PID 1 running as pzuser, and only root may chown
# a root-owned directory. It is kept only for the case where the image is run
# with "--user root". What actually protects the boot is the check below.
mkdir -p "$INSTALL_DIR" "$DATA_DIR" 2>/dev/null
chown -R pzuser:pzuser "$INSTALL_DIR" "$DATA_DIR" 2>/dev/null || true

# 2b. Refuse to boot into unwritable volumes.
# ./zomboid_data and ./server_files are gitignored, so a fresh clone does not
# contain them -- and Docker creates a missing bind-mount path as ROOT while this
# container deliberately runs as a non-root user. Every write then fails.
#
# Without this check the boot continues anyway: the .ini is never created, so the
# server comes up with default max players, no admin password, no RCON, and a
# health check that can never pass. A container that stops with an actionable
# message beats a server that is silently misconfigured.
unwritable=""
for d in "$DATA_DIR" "$INSTALL_DIR"; do
    dir_is_writable "$d" || unwritable="$unwritable $d"
done

if [ -n "$unwritable" ]; then
    echo "ERROR: the container user cannot write to its volumes."
    echo "           container user: $(id -un 2>/dev/null || id -u) (uid $(id -u), gid $(id -g))"
    for d in $unwritable; do
        echo "           not writable  : $d -- owned by $(stat -c '%U:%G (uid %u)' "$d" 2>/dev/null || echo 'unknown')"
    done
    echo "       Docker creates a missing bind-mount path as root, and this image"
    echo "       deliberately runs as a non-root user, so a directory that did not"
    echo "       exist before the first \"docker compose up\" is unusable."
    echo "       Fix on the host, from the folder holding docker-compose.yml:"
    echo "           sudo chown -R $(id -u):$(id -g) ./zomboid_data ./server_files"
    echo "       Then bring the stack back up: docker compose up -d"
    echo "       Backing off 30s so the restart policy does not spin."
    sleep 30
    exit 1
fi

echo "--- Checking for Project Zomboid Updates ---"

MAX_RETRIES=3
RETRY_COUNT=0
DOWNLOAD_SUCCESS=false

BUILD_BEFORE="$(read_buildid)"
LAST_KNOWN="$(cat "$BUILDID_STATE" 2>/dev/null)"
echo "    installed build : ${BUILD_BEFORE:-<none>}"
echo "    world last ran on: ${LAST_KNOWN:-<none>}"

# 3. SteamCMD Update with Retry Logic and explicit paths
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    # Corrected path: using the symlink we created in the Dockerfile
    /usr/bin/steamcmd \
        +@sSteamCmdForcePlatformType linux \
        +force_install_dir "$INSTALL_DIR" \
        +login anonymous \
        +app_update 380870 validate \
        +quit
    STEAM_RC=$?

    # SteamCMD's exit code is advisory only -- some builds return non-zero on a
    # perfectly good install -- so it is logged, while install_is_complete is
    # what actually decides. That is still strictly better than discarding it.
    [ "$STEAM_RC" -ne 0 ] && echo "WARNING: SteamCMD exited with status $STEAM_RC."

    if install_is_complete; then
        DOWNLOAD_SUCCESS=true
        break
    fi

    echo "WARNING: install incomplete. Retrying in 10 seconds... ($(($RETRY_COUNT + 1))/$MAX_RETRIES)"
    # Clean up potential corrupt steamapps folder before retry
    rm -rf "$INSTALL_DIR/steamapps"
    sleep 10
    RETRY_COUNT=$(($RETRY_COUNT + 1))
done

if [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo "ERROR: Failed to download Project Zomboid after $MAX_RETRIES attempts."
    echo "Please check your disk space and volume permissions."
    exit 1
fi

# 3b. Back up the world before a new build gets to open it.
# The save is only at risk once the NEW binary touches it, so this window --
# after the download, before the launch -- is a genuine pre-update backup.
# The comparison uses the build recorded next to the save rather than the one
# from the Steam manifest, so wiping server_files cannot lose the history.
BUILD_AFTER="$(read_buildid)"
echo "--- Build after update: ${BUILD_AFTER:-<unknown>} ---"

if [ -z "$LAST_KNOWN" ]; then
    echo "--- No previous build recorded for this world; no backup needed. ---"
elif [ -z "$BUILD_AFTER" ]; then
    echo "WARNING: could not read buildid from the manifest; skipping backup check."
elif [ "$BUILD_AFTER" != "$LAST_KNOWN" ]; then
    echo "--- BUILD CHANGED: $LAST_KNOWN -> $BUILD_AFTER ---"
    if world_exists; then
        if ! backup_world "$LAST_KNOWN" "$BUILD_AFTER"; then
            echo "ERROR: refusing to launch build $BUILD_AFTER against an un-backed-up world."
            exit 1
        fi
    else
        echo "--- No existing world to back up. ---"
    fi
else
    echo "--- Build unchanged. ---"
fi

[ -n "$BUILD_AFTER" ] && echo "$BUILD_AFTER" > "$BUILDID_STATE"

# 3c. Runtime pre-flight.
# PZ's own start-server.sh tests the bundled JRE and, if it fails, prints
# "Only 64bit is supported" and exits 0 -- which looks like a clean shutdown to
# the restart policy and gives a silent crash loop. Test it here instead so a
# runtime that has outgrown this image's base is a loud, fatal error.
echo "--- Runtime pre-flight ---"
if JAVA_VERSION="$("$INSTALL_DIR/jre64/bin/java" -version 2>&1)"; then
    echo "$JAVA_VERSION" | sed 's/^/    /'
else
    echo "$JAVA_VERSION" | sed 's/^/    /'
    echo "ERROR: the bundled JRE at $INSTALL_DIR/jre64/bin/java will not run."
    echo "       A Project Zomboid update has most likely shipped a newer runtime"
    echo "       than this image's base can support (currently $(ldd --version | head -1))."
    echo "       Fix: rebuild the image on a newer base, e.g. FROM debian:trixie-slim."
    exit 1
fi

# 4. Inject Config
echo "--- Configuration: Applying 'CFG_' Environment Variables ---"
mkdir -p "$(dirname "$CONFIG_FILE")"
[ ! -f "$CONFIG_FILE" ] && touch "$CONFIG_FILE"

env | grep '^CFG_' | while read -r line ; do
    key_val=${line#CFG_}
    key=$(echo "$key_val" | cut -d'=' -f1)
    val=$(echo "$key_val" | cut -d'=' -f2-)

    escaped_val="${val//&/\\&}"
    
    if grep -q "^$key=" "$CONFIG_FILE"; then
        sed -i "s|^$key=.*|$key=$escaped_val|" "$CONFIG_FILE"
    else
        echo "$key=$val" >> "$CONFIG_FILE"
    fi
done

# 4b. Sandbox settings: install <SERVER_NAME>_SandboxVars.lua from a mounted file.
# PZ keeps its configuration in two halves: the .ini above, and the sandbox file
# that actually defines the world (zombie counts, loot, time). The sandbox half
# lives in the gitignored zomboid_data mount, so without this it exists only as a
# file someone made by hand -- nothing about it survives a fresh clone.
#
# PZ_SANDBOX_SOURCE names a file mounted into the container: either a
# single-player sandbox .cfg/.ini, which is converted, or an already-formed
# SandboxVars.lua, which is validated and copied. Unset means "do nothing".
SANDBOX_FILE="$DATA_DIR/Server/${SERVER_NAME}_SandboxVars.lua"
# Hash of the source as of the last successful install. Same reasoning as
# MANAGED_ARGS_FILE below: the destination is a persisted bind mount, so without
# a marker this would have to either clobber the file on every boot -- throwing
# away sandbox changes made through the in-game admin panel -- or never update it.
SANDBOX_STATE="$DATA_DIR/.pz_sandbox_source.sha256"
CONVERTER="/home/pzuser/pzConfigConverter.py"

install_sandbox_config() {
    src="$1"

    # Two different situations, deliberately given different exit codes:
    #   1 = nothing was provided  -> boot on the defaults, that is a valid choice
    #   2 = something was provided and it is unusable -> refuse to boot, because
    #       the alternative is a server silently running the wrong settings.
    if [ ! -e "$src" ]; then
        echo "    no sandbox source at $src."
        return 1
    fi
    if [ -d "$src" ]; then
        echo "    $src is a directory, so no sandbox source was provided."
        echo "    (Docker creates a missing bind-mount path as an empty directory."
        echo "     If you meant to supply a file, remove that stray directory on"
        echo "     the host first, then put the file there.)"
        return 1
    fi
    if [ ! -f "$src" ]; then
        echo "WARNING: $src is not a regular file."
        return 2
    fi
    if [ ! -r "$src" ]; then
        echo "WARNING: $src is not readable by $(id -un 2>/dev/null || id -u) (uid $(id -u))."
        return 2
    fi

    want="$(sha256sum "$src" | cut -d' ' -f1)"
    have="$(cat "$SANDBOX_STATE" 2>/dev/null)"

    # The -f test is what makes a SERVER_NAME rename re-apply: the source has not
    # changed, but the file it belongs in is a different one now.
    if [ "$want" = "$have" ] && [ -f "$SANDBOX_FILE" ] && [ "$PZ_SANDBOX_FORCE" != "true" ]; then
        echo "    source unchanged since the last install; leaving the live file alone."
        echo "    (set PZ_SANDBOX_FORCE=true to re-apply it anyway)"
        return 0
    fi

    tmp_file="$(mktemp)" || return 2

    # Decided by content, not by extension: the mount can be named anything, and
    # a .cfg that is already Lua is a likelier mistake than a .lua that is not.
    if grep -qE '^[[:space:]]*SandboxVars[[:space:]]*=' "$src"; then
        echo "    source is already Lua; validating and copying it verbatim."
        if converter_out="$(python3 "$CONVERTER" --check "$src" 2>&1)"; then
            cp "$src" "$tmp_file" || { rm -f "$tmp_file"; return 2; }
        else
            echo "$converter_out" | sed 's/^/    /'
            rm -f "$tmp_file"
            return 2
        fi
    else
        echo "    source is a .cfg/.ini preset; converting it to Lua."
        if ! converter_out="$(python3 "$CONVERTER" "$src" --output "$tmp_file" 2>&1)"; then
            echo "$converter_out" | sed 's/^/    /'
            rm -f "$tmp_file"
            return 2
        fi
    fi
    [ -n "$converter_out" ] && echo "$converter_out" | sed 's/^/    /'

    # One rollback slot, not a history: backup_world above already archives the
    # whole Server/ directory whenever the game build changes.
    if [ -f "$SANDBOX_FILE" ]; then
        if cp "$SANDBOX_FILE" "${SANDBOX_FILE}.bak"; then
            echo "    previous version saved as $(basename "$SANDBOX_FILE").bak"
        else
            echo "WARNING: could not write ${SANDBOX_FILE}.bak; continuing anyway."
        fi
    fi

    if ! mv "$tmp_file" "$SANDBOX_FILE"; then
        echo "WARNING: could not write $SANDBOX_FILE."
        rm -f "$tmp_file"
        return 2
    fi
    chmod 644 "$SANDBOX_FILE" 2>/dev/null || true   # mktemp makes it 0600

    # Written only after the move lands, so the marker can never claim to
    # describe a file that was not actually installed.
    printf '%s' "$want" > "$SANDBOX_STATE"
    echo "    installed $(basename "$SANDBOX_FILE")"
    return 0
}

if [ -n "$PZ_SANDBOX_SOURCE" ]; then
    echo "--- Configuration: Applying sandbox settings from PZ_SANDBOX_SOURCE ---"
    echo "    source      : $PZ_SANDBOX_SOURCE"
    echo "    destination : $SANDBOX_FILE"

    # Absence and breakage are not the same thing. Providing no source is how you
    # ask for stock settings, so that boots. A source that is present but cannot
    # be used is a mistake, and booting anyway would run the server on settings
    # nobody chose -- for a brand new world those are baked in at generation.
    install_sandbox_config "$PZ_SANDBOX_SOURCE"
    case $? in
        0) ;;
        1)  if [ -f "$SANDBOX_FILE" ]; then
                echo "WARNING: no sandbox source provided; starting on the existing"
                echo "         $(basename "$SANDBOX_FILE")."
            else
                echo "WARNING: no sandbox source provided; starting on the game's"
                echo "         default sandbox settings. Drop a .cfg or a"
                echo "         SandboxVars.lua into sandbox_config/ to change that."
            fi
            ;;
        *)  echo "ERROR: PZ_SANDBOX_SOURCE names a file that cannot be used."
            echo "       Refusing to start: the server would silently run different"
            echo "       sandbox settings than the ones asked for. The reason is"
            echo "       printed above."
            echo "       Fix the file, or remove it to start on the game's defaults."
            echo "       Backing off 30s so the restart policy does not spin."
            sleep 30
            exit 1
            ;;
    esac
fi

# 5. Configure JVM Memory & Extra Args via ProjectZomboid64.json
# pzexe takes JVM args ONLY from ProjectZomboid64.json. Anything passed on the
# command line is forwarded to the game's own arg parser, which rejects it with
# 'unknown option "-Xmx..."' -- so command-line -Xmx/-Xms flags silently do
# nothing and the server runs on the json's stock 8g. SteamCMD's "validate"
# rewrites this file on every boot, so it must be re-patched here each time
# rather than edited by hand.
JVM_CONFIG_FILE="$INSTALL_DIR/ProjectZomboid64.json"
# Records the exact args injected on the previous boot so they can be removed
# before re-injecting. ./server_files is a persisted bind mount, so without this
# PZ_JVM_EXTRA_ARGS accumulates duplicates and args dropped from compose linger.
MANAGED_ARGS_FILE="$INSTALL_DIR/.pz_managed_vmargs.json"
PZ_JVM_MEMORY="${PZ_JVM_MEMORY:-4g}"

# Fatal rather than skippable, both here and on a jq failure below. Continuing
# means booting on the stock 8g heap with no sign anything went wrong, and
# install_is_complete() already requires this file -- so if it is missing after a
# successful SteamCMD run, the install is broken rather than merely unpatched.
if [ ! -f "$JVM_CONFIG_FILE" ]; then
    echo "ERROR: $JVM_CONFIG_FILE not found after a successful update."
    echo "       The heap size can only be set here, so continuing would run the"
    echo "       server on the launcher's stock heap. This means a broken install."
    echo "       Backing off 30s so the restart policy does not spin."
    sleep 30
    exit 1
fi

echo "--- Setting JVM heap to $PZ_JVM_MEMORY in ProjectZomboid64.json ---"

# Build a JSON array from the space-separated PZ_JVM_EXTRA_ARGS env var (if any)
extra_args_json="[]"
if [ -n "$PZ_JVM_EXTRA_ARGS" ]; then
    extra_args_json=$(printf '%s\n' $PZ_JVM_EXTRA_ARGS | jq -R . | jq -s .)
fi

prev_managed_json="[]"
if [ -f "$MANAGED_ARGS_FILE" ] && jq -e . "$MANAGED_ARGS_FILE" >/dev/null 2>&1; then
    prev_managed_json=$(cat "$MANAGED_ARGS_FILE")
fi

# -Xmx/-Xms are stripped by prefix; everything else we added is stripped by
# exact match against $prev. The "map(. as $a | ...)" binding is required -
# inside the pipe of index(), "." would refer to $prev, not the element.
# The closing reduce is an order-preserving dedupe: it collapses duplicates
# left by a missing/corrupt marker, and cleans up installs that already
# accumulated them before this logic existed. Exact-duplicate JVM args are
# always redundant, and keeping the first occurrence preserves stock order.
tmp_file=$(mktemp)
if jq --arg mem "$PZ_JVM_MEMORY" \
      --argjson extra "$extra_args_json" \
      --argjson prev "$prev_managed_json" '
    .vmArgs = ((.vmArgs // [])
                | map(select((startswith("-Xmx") or startswith("-Xms")) | not))
                | map(. as $a | select(($prev | index($a)) == null)))
              + ["-Xmx\($mem)", "-Xms\($mem)"]
              + $extra
    | .vmArgs |= reduce .[] as $a ([]; if index($a) == null then . + [$a] else . end)
' "$JVM_CONFIG_FILE" > "$tmp_file" && [ -s "$tmp_file" ]; then
    mv "$tmp_file" "$JVM_CONFIG_FILE"
    # Written only after the rewrite lands, so the marker never claims to
    # describe args that aren't actually in the file.
    printf '%s' "$extra_args_json" > "$MANAGED_ARGS_FILE"
else
    rm -f "$tmp_file"
    echo "ERROR: could not set the heap size in $JVM_CONFIG_FILE."
    echo "       The launcher's config format may have changed in this build."
    echo "       Backing off 30s so the restart policy does not spin."
    sleep 30
    exit 1
fi

echo "--- Starting Project Zomboid Server ---"
cd "$INSTALL_DIR" || exit

# 5. Start Server in Background with Pipe Input
tail -f "$PIPE" | ./start-server.sh \
    -servername "$SERVER_NAME" \
    -adminpassword "${ADMIN_PASSWORD:-12345}" &

# Capture the Server PID. healthcheck.sh reads this file instead of matching on
# a process name: B42 replaced the "java ... zombie.network.GameServer" process
# with a native ./ProjectZomboid64 launcher that loads libjvm.so in-process,
# which silently broke the old pgrep check. A PID cannot go stale that way.
SERVER_PID=$!
echo "$SERVER_PID" > /tmp/pz/server.pid
LAUNCH_TS=$(date +%s)
echo "Server PID: $SERVER_PID"

# 6. Define Shutdown Function
# Bounded on purpose: an unbounded "wait" on a hung JVM means Docker has to
# SIGKILL us at the end of stop_grace_period, which is exactly the unclean
# shutdown this trap exists to avoid. Keep SHUTDOWN_TIMEOUT under the
# stop_grace_period set in docker-compose.yml.
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-150}"
# How long with no CPU and no disk activity before we call the server wedged.
STALL_LIMIT="${STALL_LIMIT:-30}"

# Cumulative CPU ticks for a pid. /proc/<pid>/stat's comm field can contain
# spaces, so everything up to the closing paren is stripped first; utime and
# stime are then the 12th and 13th remaining values.
read_cpu_ticks() {
    rest="$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null)" || return 1
    [ -n "$rest" ] || return 1
    set -- $rest
    echo $(( ${12:-0} + ${13:-0} ))
}

read_write_bytes() {
    awk '/^write_bytes:/ {print $2; exit}' "/proc/$1/io" 2>/dev/null
}

shutdown_server() {
    trap '' SIGTERM SIGINT   # ignore repeat signals while saving

    echo "--- Caught Signal: Sending 'quit' to server... ---"
    echo "quit" > "$PIPE"

    # The launcher is SERVER_PID's child. Found by parentage, not by name, so a
    # future rename cannot break it -- same reason healthcheck.sh uses a pid file.
    LAUNCHER_PID="$(pgrep -P "$SERVER_PID" 2>/dev/null | head -1)"

    echo "--- Waiting up to ${SHUTDOWN_TIMEOUT}s for server (PID $SERVER_PID) to save and exit... ---"
    waited=0
    stalled=0
    last_progress=""

    while kill -0 "$SERVER_PID" 2>/dev/null && [ "$waited" -lt "$SHUTDOWN_TIMEOUT" ]; do
        sleep 2
        waited=$((waited + 2))

        # A wedged server and a server writing a large save look identical from
        # the outside, and RCON goes quiet either way -- so don't infer "hung"
        # from silence, watch for actual work. While CPU time or bytes written
        # keep advancing the server gets the full timeout; once both go flat it
        # is wedged and there is nothing to wait for.
        [ -n "$LAUNCHER_PID" ] || continue

        progress="$(read_cpu_ticks "$LAUNCHER_PID"):$(read_write_bytes "$LAUNCHER_PID")"
        if [ "$progress" != "$last_progress" ]; then
            last_progress="$progress"
            stalled=0
            continue
        fi

        stalled=$((stalled + 2))
        if [ "$stalled" -ge "$STALL_LIMIT" ]; then
            echo "--- No CPU or disk activity for ${stalled}s: server is wedged, not saving. ---"
            break
        fi
    done

    if kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "--- Server did not exit after ${waited}s; forcing termination. ---"
        # Kill the launcher too: SERVER_PID is only the start-server.sh wrapper,
        # and killing it alone leaves the actual game process running.
        [ -n "$LAUNCHER_PID" ] && kill -KILL "$LAUNCHER_PID" 2>/dev/null
        kill -KILL "$SERVER_PID" 2>/dev/null
        exit 1
    fi

    echo "--- Server exited cleanly after ${waited}s. ---"
    exit 0
}

# 8. Register Trap
trap 'shutdown_server' SIGTERM SIGINT

# 9. Wait Loop
# Polls instead of using "wait". The server runs as the tail end of a pipeline
# ("tail -f $PIPE | ./start-server.sh"), and bash's wait on a pipeline member
# blocks until the ENTIRE job finishes. The tail feeding the command FIFO never
# exits, so wait blocks forever even once the game process is gone -- PID 1 sits
# in do_wait and the container never stops, so "restart: unless-stopped" never
# fires. That is exactly what happened when mod-watcher shut the server down over
# RCON: the game saved and exited cleanly, and nothing noticed.
# sleep is interruptible, so the SIGTERM trap below still fires promptly.
while kill -0 "$SERVER_PID" 2>/dev/null; do
    sleep 5
done

# Only reached when the server exits on its own; the shutdown trap exits
# directly. start-server.sh returns 0 even when it refuses to launch, so a fast
# exit here is the signature of a broken install or runtime. Back off before
# exiting so "restart: unless-stopped" cannot spin on it.
RAN_FOR=$(( $(date +%s) - LAUNCH_TS ))
rm -f /tmp/pz/server.pid

if [ "$RAN_FOR" -lt "${MIN_RUNTIME_SECONDS:-60}" ]; then
    echo "ERROR: server exited after ${RAN_FOR}s, before it could finish starting."
    echo "       This usually means a broken install or a runtime this image"
    echo "       cannot run. Check the lines above for the launcher's own error."
    echo "       Backing off 30s so the restart policy does not spin."
    sleep 30
    exit 1
fi

echo "--- Server process exited on its own after ${RAN_FOR}s. ---"
exit 1
