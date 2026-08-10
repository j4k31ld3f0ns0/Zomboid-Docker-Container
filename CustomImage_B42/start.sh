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

echo "--- Starting Project Zomboid Server ---"
cd "$INSTALL_DIR" || exit
PZ_JVM_MEMORY="${PZ_JVM_MEMORY:-4g}"

# 5. Start Server in Background with Pipe Input
tail -f "$PIPE" | ./start-server.sh \
    -servername "$SERVER_NAME" \
    -adminpassword "${ADMIN_PASSWORD:-12345}" \
    -Xmx$PZ_JVM_MEMORY \
    -Xms$PZ_JVM_MEMORY &

# Capture the Server PID
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

# 6. Define Shutdown Function
shutdown_server() {
    echo "--- Caught Signal: Sending 'quit' to server... ---"
    echo "quit" > "$PIPE"
    
    echo "--- Waiting for server (PID $SERVER_PID) to save and exit... ---"
    wait "$SERVER_PID"
    echo "--- Server exited cleanly. ---"
    exit 0
}

# 7. Register Trap
trap 'shutdown_server' SIGTERM SIGINT

# 8. Wait Loop
while kill -0 "$SERVER_PID" >/dev/null 2>&1; do
    wait "$SERVER_PID"
done