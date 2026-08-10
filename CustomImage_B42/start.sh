#!/bin/bash

# Define directories
INSTALL_DIR="/home/pzuser/server"
DATA_DIR="/home/pzuser/Zomboid"
SERVER_NAME="${SERVER_NAME:-servertest}"
CONFIG_FILE="$DATA_DIR/Server/${SERVER_NAME}.ini"
PIPE="/home/pzuser/zomboid.in"

# 1. Setup Pipe
rm -f "$PIPE"
mkfifo "$PIPE"
chmod 600 "$PIPE"

# 2. Setup Directories & Ensure Permissions
# Force creation and ensure the container user owns them
mkdir -p "$INSTALL_DIR" "$DATA_DIR"
chown -R pzuser:pzuser "$INSTALL_DIR" "$DATA_DIR" 2>/dev/null || true

echo "--- Checking for Project Zomboid Updates ---"

MAX_RETRIES=3
RETRY_COUNT=0
DOWNLOAD_SUCCESS=false

# 3. SteamCMD Update with Retry Logic and explicit paths
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    # Corrected path: using the symlink we created in the Dockerfile
    /usr/bin/steamcmd \
        +@sSteamCmdForcePlatformType linux \
        +force_install_dir "$INSTALL_DIR" \
        +login anonymous \
        +app_update 380870 validate \
        +quit
    
    # Check if the start script actually exists after download
    if [ -f "$INSTALL_DIR/start-server.sh" ]; then
        DOWNLOAD_SUCCESS=true
        break
    else
        echo "WARNING: Download failed or incomplete. Retrying in 10 seconds... ($(($RETRY_COUNT + 1))/$MAX_RETRIES)"
        # Clean up potential corrupt steamapps folder before retry
        rm -rf "$INSTALL_DIR/steamapps"
        sleep 10
        RETRY_COUNT=$(($RETRY_COUNT + 1))
    fi
done

if [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo "ERROR: Failed to download Project Zomboid after $MAX_RETRIES attempts."
    echo "Please check your disk space and volume permissions."
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
PZ_JVM_MEMORY="${PZ_JVM_MEMORY:-4g}"

if [ -f "$JVM_CONFIG_FILE" ]; then
    echo "--- Configuration: Applying PZ_JVM_MEMORY and PZ_JVM_EXTRA_ARGS to ProjectZomboid64.json ---"

    # Build a JSON array from the space-separated PZ_JVM_EXTRA_ARGS env var (if any)
    extra_args_json="[]"
    if [ -n "$PZ_JVM_EXTRA_ARGS" ]; then
        extra_args_json=$(printf '%s\n' $PZ_JVM_EXTRA_ARGS | jq -R . | jq -s .)
    fi

    tmp_file=$(mktemp)
    jq --arg mem "$PZ_JVM_MEMORY" --argjson extra "$extra_args_json" '
        .vmArgs = ((.vmArgs // []) | map(select((startswith("-Xmx") or startswith("-Xms")) | not)))
                  + ["-Xmx\($mem)", "-Xms\($mem)"]
                  + $extra
    ' "$JVM_CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$JVM_CONFIG_FILE"
else
    echo "WARNING: $JVM_CONFIG_FILE not found; skipping JVM memory/args injection."
fi

echo "--- Starting Project Zomboid Server ---"
cd "$INSTALL_DIR" || exit

# 6. Start Server in Background with Pipe Input
tail -f "$PIPE" | ./start-server.sh \
    -servername "$SERVER_NAME" \
    -adminpassword "${ADMIN_PASSWORD:-12345}" &

# Capture the Server PID
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

# 7. Define Shutdown Function
shutdown_server() {
    echo "--- Caught Signal: Sending 'quit' to server... ---"
    echo "quit" > "$PIPE"

    echo "--- Waiting for server (PID $SERVER_PID) to save and exit... ---"
    wait "$SERVER_PID"
    echo "--- Server exited cleanly. ---"
    exit 0
}

# 8. Register Trap
trap 'shutdown_server' SIGTERM SIGINT

# 9. Wait Loop
while kill -0 "$SERVER_PID" >/dev/null 2>&1; do
    wait "$SERVER_PID"
done

# Reached when the server process ends on its own rather than via SIGTERM - most
# often an RCON "quit" sent by the mod-watcher to apply a Workshop update.
# Exiting here stops the container, and the "restart: unless-stopped" policy
# starts it again, which re-runs the steamcmd update above.
echo "--- Server process exited; container will restart via Docker restart policy. ---"
exit 0