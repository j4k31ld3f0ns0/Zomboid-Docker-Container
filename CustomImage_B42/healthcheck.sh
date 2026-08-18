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

mkdir -p "$STATE_DIR"

booting() {
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
    rm -f "$FAIL_COUNT"
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
