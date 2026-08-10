Project Zomboid Dedicated Server (Docker)

This is a custom Docker setup for hosting a Project Zomboid Dedicated Server. 
It features:
Security: Runs as a non-root user (pzuser).
Graceful Shutdown: Uses a signal trap to save the world before stopping.
Auto-Config: Injects server settings via Environment Variables (CFG_...).
Mod Support: Easy Steam Workshop integration.
🚀 Quick Start
1. Prerequisite Checklist
Docker installed.
Docker Compose installed.
At least 10GB RAM available (8GB for Java Heap + 2GB for OS overhead).
2. Create Required Folders & Set Permissions (CRITICAL)Because the container runs as a secure non-root user (UID 1000), it cannot create folders on your host machine if they are owned by root. You must create them manually and set ownership before running.

Run these commands in the directory where your docker-compose.yml lives:# 1. Create the data directories
``mkdir -p zomboid_data server_files``

# 2. Set ownership to UID 1000 (standard Linux user)
# If you skip this, the server will crash with "Permission Denied" errors.
``sudo chown -R 1000:1000 zomboid_data server_files``
3. Launch the Serverdocker compose up -d
First Run: It will take 5-10 minutes to download the game files via SteamCMD.Check Progress: docker logs -f project-zomboid-server⚙️ ConfigurationYou do not need to edit the .ini files manually. You can control server settings directly from docker-compose.yml using the CFG_ prefix.Common Environment VariablesVariableDescriptionDefaultSERVER_NAMEName of the save file/config entry.servertestADMIN_PASSWORDPassword for the default admin account.ChangeThis...PZ_JVM_MEMORYJava Heap Size (Format: 4g, 8g).4gGame Settings (CFG_ Injection)Any environment variable starting with CFG_ is automatically stripped and written to servertest.ini on startup.Examples:CFG_Public=false (Sets server to private)CFG_Password=secret (Sets a join password)CFG_PVP=true (Enables PVP)CFG_MaxPlayers=32🛠️ Adding Mods (Steam Workshop)To add mods, you need to edit the docker-compose.yml environment section. You must provide both the Workshop ID (for downloading) and the Mod ID (for loading).environment:
  # 1. List of Workshop IDs (Numbers) separated by semicolon
  - CFG_WorkshopItems=2611652230;2611652231

  # 2. List of Mod IDs (Names) separated by semicolon
  - CFG_Mods=ModManager;AnotherModName
Apply Changes: Run docker compose up -d (No rebuild needed).🎮 Management CommandsStopping the Server (Safely)This container has a "Trap" script. When you ask it to stop, it will trigger a /quit command inside the game to save the world properly.# Triggers 'Save & Quit' inside the container
docker compose down
Note: Wait 10-20 seconds for the save to complete.Viewing Logs (Real-time)docker logs -f project-zomboid-server
(Press Ctrl+C to exit the log viewer)RCON / Console AccessThe server exposes RCON on port 27015.Recommended: Use a client like rcon-cli or Arrcon.Quick Command (Docker): You can inject commands via the internal pipe:# Example: Kick a user named Spiffo
docker exec project-zomboid-server sh -c 'echo "kickuser Spiffo" > /home/pzuser/zomboid.in'
⚠️ Troubleshooting1. "Permission Denied" in logsCause: You likely ran docker compose up before creating the folders, so Docker created them as root.Fix: Stop the container, fix ownership, and restart.docker compose down
sudo chown -R 1000:1000 zomboid_data server_files
docker compose up -d
2. Server "Restarting (127)"Cause: The start.sh script has Windows Line Endings (CRLF).Fix: Rebuild the container (The Dockerfile includes a fix for this, but requires a rebuild).docker compose up -d --build
3. "SteamCMD: Command not found"Cause: Path issue in the container.Fix: Ensure your start.sh points to /usr/games/steamcmd/steamcmd.sh (absolute path).