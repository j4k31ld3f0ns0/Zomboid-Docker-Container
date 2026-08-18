#!/bin/bash
# Staged health check for the Project Zomboid server.
#
#   Stage 1  no game process yet         -> still installing / booting
#   Stage 2  process up, RCON port shut  -> loading world and mods
#   Stage 3  RCON answers "players"      -> healthy
#
# Two kinds of failure are deliberately kept apart:
#
#   booting()   exit 1, NOT counted. The server has never finished starting, so
#               there is nothing to restart back into. Docker's start_period
#               keeps the container in "starting" while this happens.
#   degraded()  exit 1, counted. The server was answering RCON and has stopped.
#               After HEALTH_FAIL_THRESHOLD consecutive failures this signals
#               PID 1, which runs the normal save-and-quit path, and the
#               restart policy brings the container back.
#
# The "has been ready at least once" marker is what makes a slow first boot
# (SteamCMD pulling ~7GB, then 60+ workshop mods) safe: it cannot trigger a
# restart loop. start.sh clears the marker on every boot.

set -uo pipefail

STATE_DIR="/tmp/pz"
READY_MARK="$STATE_DIR/ready"
FAIL_COUNT="$STATE_DIR/health_fails"
THRESHOLD="${HEALTH_FAIL_THRESHOLD:-6}"
RCON_PORT="${CFG_RCONPort:-27015}"
RCON_PASS="${CFG_RCONPassword:-}"
# How long the server may show zero CPU and zero disk activity, while still not
# ready, before its startup is treated as wedged rather than slow.
STARTUP_STALL_LIMIT="${STARTUP_STALL_LIMIT:-300}"
# Minimum CPU ticks per second that counts as real work. A crashed-but-resident
# JVM is not idle: PZ logs "Server Terminated." after a fatal script error and
# then sits there, background threads still burning ~0.5 ticks/s. A server
# genuinely downloading mods or loading a world burns 50-100x that, so anything
# under a few percent of one core is noise rather than progress. Testing for
# "any change at all" would never fire.
STARTUP_MIN_TICKS_PER_SEC="${STARTUP_MIN_TICKS_PER_SEC:-5}"
# Same idea for disk. A crashed JVM keeps dribbling bytes out (log flushes, JVM
# internals) -- measured at ~56 bytes/sec -- so "did write_bytes increase at all"
# is never false and would keep the check from ever firing. A server downloading
# mods or writing a world moves megabytes per second, so this separates cleanly.
STARTUP_MIN_BYTES_PER_SEC="${STARTUP_MIN_BYTES_PER_SEC:-10240}"
BOOT_PROGRESS="$STATE_DIR/boot_progress"
# Latch: once the startup is judged wedged it stays judged, so the restart
# threshold is reached in a few checks rather than a few stall windows. Cleared
# again if a later window shows real work, so a transient stall self-heals.
BOOT_WEDGED="$STATE_DIR/boot_wedged"

mkdir -p "$STATE_DIR"

# Same counters start.sh watches during shutdown. Kept local to this script so
# the health check stays self-contained and runnable on its own.
read_cpu_ticks() {
    local rest
    rest="$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null)" || return 1
    [ -n "$rest" ] || return 1
    set -- $rest
    echo $(( ${12:-0} + ${13:-0} ))
}

read_write_bytes() {
    awk '/^write_bytes:/ {print $2; exit}' "/proc/$1/io" 2>/dev/null
}

# True when the server process is alive but has done no measurable work for
# STARTUP_STALL_LIMIT. A failed startup can leave the process resident -- PZ
# logs "Server Terminated." after a fatal script error but the JVM does not
# always exit -- and without this the container would sit in "starting" for the
# whole 45m start_period, then stay unhealthy forever, because never-ready
# failures deliberately do not count toward a restart.
startup_is_wedged() {
    local pid launcher now cpu io prev prev_cpu prev_io prev_since elapsed
    pid="$(cat "$STATE_DIR/server.pid" 2>/dev/null)"
    [ -n "$pid" ] || return 1
    launcher="$(pgrep -P "$pid" 2>/dev/null | head -1)"
    [ -n "$launcher" ] || return 1

    now="$(date +%s)"
    cpu="$(read_cpu_ticks "$launcher")" || return 1
    io="$(read_write_bytes "$launcher")"
    io="${io:-0}"

    prev="$(cat "$BOOT_PROGRESS" 2>/dev/null)"
    if [ -z "$prev" ]; then
        echo "$cpu $io $now" > "$BOOT_PROGRESS"
        return 1
    fi
    read -r prev_cpu prev_io prev_since <<< "$prev"

    # A malformed marker must reset the window, not silently disable the check:
    # unset fields would make elapsed compute as 0 and nothing would ever fire.
    if ! [ "${prev_cpu:-x}" -ge 0 ] 2>/dev/null || ! [ "${prev_since:-x}" -gt 0 ] 2>/dev/null; then
        echo "$cpu $io $now" > "$BOOT_PROGRESS"
        return 1
    fi

    elapsed=$(( now - prev_since ))
    [ "$elapsed" -ge "$STARTUP_STALL_LIMIT" ] || return 1

    # The window has elapsed, so start a fresh one either way.
    echo "$cpu $io $now" > "$BOOT_PROGRESS"

    # Both signals are rates, not "did it change". Either one clearing its
    # threshold means the server is genuinely working.
    if [ "$(( io - ${prev_io:-0} ))" -ge "$(( STARTUP_MIN_BYTES_PER_SEC * elapsed ))" ] ||
       [ "$(( cpu - prev_cpu ))" -ge "$(( STARTUP_MIN_TICKS_PER_SEC * elapsed ))" ]; then
        rm -f "$BOOT_WEDGED"
        return 1
    fi
    return 0
}

booting() {
    # Downloading, loading mods and generating a world all burn CPU and disk, so
    # a genuinely slow boot keeps making progress. A wedged one does not.
    startup_is_wedged && touch "$BOOT_WEDGED"

    if [ -f "$BOOT_WEDGED" ]; then
        degraded "startup wedged - no meaningful CPU or disk progress for ${STARTUP_STALL_LIMIT}s while still not ready ($1)"
    fi

    echo "starting: $1"
    exit 1
}

degraded() {
    local n
    n=$(( $(cat "$FAIL_COUNT" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$FAIL_COUNT"
    echo "unhealthy ($n/$THRESHOLD): $1"
    if [ "$n" -ge "$THRESHOLD" ]; then
        echo "restart: $n consecutive failures, signalling PID 1 to save and exit"
        kill -TERM 1
    fi
    exit 1
}

fail() {
    if [ -f "$READY_MARK" ]; then degraded "$1"; else booting "$1"; fi
}

healthy() {
    rm -f "$FAIL_COUNT" "$BOOT_PROGRESS" "$BOOT_WEDGED"
    touch "$READY_MARK"
    echo "healthy: $1"
    exit 0
}

# --- Stage 1: is the game server process alive? ---
# Deliberately a PID file rather than a process-name match. B42 replaced the
# "java ... zombie.network.GameServer" process with a native ./ProjectZomboid64
# launcher that loads libjvm.so in-process, so the old pgrep pattern matched
# nothing and the container could never report healthy. start.sh records the
# PID it launched; kill -0 cannot break when the launcher is renamed again.
SERVER_PID="$(cat "$STATE_DIR/server.pid" 2>/dev/null)"

[ -n "$SERVER_PID" ] || fail "server not launched yet (installing or updating)"

kill -0 "$SERVER_PID" 2>/dev/null || fail "server process $SERVER_PID is gone"

# RCON off means we can only prove the process exists. Say so rather than
# silently downgrading to a weaker check.
if [ -z "$RCON_PASS" ]; then
    healthy "process alive (RCON disabled: CFG_RCONPassword is empty)"
fi

# --- Stage 2: only talk to RCON once it is actually listening. ---
timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$RCON_PORT" 2>/dev/null \
    || fail "RCON port $RCON_PORT not accepting connections yet"

# --- Stage 3: ask for the player list. ---
# A successful round-trip is the real signal: it proves the game loop is still
# servicing commands, not just that the JVM has not exited. The reply is only
# checked for being non-empty so a wording change in a future build cannot
# wedge the container in "unhealthy".
out=$(timeout 10 /usr/local/bin/rcon -a "127.0.0.1:$RCON_PORT" -p "$RCON_PASS" players 2>&1) \
    || fail "RCON query failed: ${out//$'\n'/ }"

[ -n "${out//[[:space:]]/}" ] || fail "empty reply to RCON 'players'"

healthy "${out%%$'\n'*}"
