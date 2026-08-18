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
# Force creation and ensure the container user owns them
mkdir -p "$INSTALL_DIR" "$DATA_DIR"
chown -R pzuser:pzuser "$INSTALL_DIR" "$DATA_DIR" 2>/dev/null || true

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

# 5. Configure JVM Memory & Extra Args via ProjectZomboid64.json
JVM_CONFIG_FILE="$INSTALL_DIR/ProjectZomboid64.json"
# Records the exact args injected on the previous boot so they can be removed
# before re-injecting. ./server_files is a persisted bind mount, so without this
# PZ_JVM_EXTRA_ARGS accumulates duplicates and args dropped from compose linger.
MANAGED_ARGS_FILE="$INSTALL_DIR/.pz_managed_vmargs.json"
PZ_JVM_MEMORY="${PZ_JVM_MEMORY:-4g}"

if [ -f "$JVM_CONFIG_FILE" ]; then
    echo "--- Configuration: Applying PZ_JVM_MEMORY and PZ_JVM_EXTRA_ARGS to ProjectZomboid64.json ---"

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
    ' "$JVM_CONFIG_FILE" > "$tmp_file"; then
        mv "$tmp_file" "$JVM_CONFIG_FILE"
        # Written only after the rewrite lands, so the marker never claims to
        # describe args that aren't actually in the file.
        printf '%s' "$extra_args_json" > "$MANAGED_ARGS_FILE"
    else
        echo "WARNING: Failed to rewrite $JVM_CONFIG_FILE; leaving it unchanged."
        rm -f "$tmp_file"
    fi
else
    echo "WARNING: $JVM_CONFIG_FILE not found; skipping JVM memory/args injection."
fi

echo "--- Starting Project Zomboid Server ---"
cd "$INSTALL_DIR" || exit

# 4b. Apply the heap size where the launcher actually reads it.
# pzexe takes JVM args ONLY from ProjectZomboid64.json. Anything passed on the
# command line is forwarded to the game's own arg parser, which rejects it with
# 'unknown option "-Xmx..."' -- so the old -Xmx/-Xms flags below were silently
# doing nothing and the server ran on the json's stock 8g. SteamCMD's "validate"
# rewrites this file on every boot, so it must be re-patched here each time
# rather than edited by hand.
LAUNCHER_JSON="$INSTALL_DIR/ProjectZomboid64.json"
echo "--- Setting JVM heap to $PZ_JVM_MEMORY in ProjectZomboid64.json ---"
TMP_JSON="$(mktemp)"
if jq --arg mem "$PZ_JVM_MEMORY" '
        .vmArgs = ((.vmArgs // [])
            | map(select((startswith("-Xmx") or startswith("-Xms")) | not))
            + ["-Xmx" + $mem, "-Xms" + $mem])
    ' "$LAUNCHER_JSON" > "$TMP_JSON" && [ -s "$TMP_JSON" ]; then
    cat "$TMP_JSON" > "$LAUNCHER_JSON"
    rm -f "$TMP_JSON"
else
    rm -f "$TMP_JSON"
    echo "ERROR: could not set the heap size in $LAUNCHER_JSON."
    echo "       The launcher's config format may have changed in this build."
    exit 1
fi

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
while kill -0 "$SERVER_PID" >/dev/null 2>&1; do
    wait "$SERVER_PID"
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
