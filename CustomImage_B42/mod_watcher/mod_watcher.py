import json
import logging
import os
import re
import socket
import struct
import sys
import time

import requests

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("mod_watcher")

STEAM_API_URL = "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"

SERVERDATA_AUTH = 3
SERVERDATA_EXECCOMMAND = 2

# PZ reports the player list as "Players connected (2):" followed by "-Name" lines.
PLAYER_COUNT_RE = re.compile(r"connected\s*\((\d+)\)", re.IGNORECASE)


def load_config():
    items_raw = os.environ.get("WORKSHOP_ITEMS", "")
    mod_ids = [m.strip() for m in items_raw.split(";") if m.strip()]
    return {
        "mod_ids": mod_ids,
        "poll_interval": int(os.environ.get("POLL_INTERVAL_SECONDS", "600")),
        "rcon_host": os.environ.get("RCON_HOST", "pz-server"),
        "rcon_port": int(os.environ.get("RCON_PORT", "27015")),
        "rcon_password": os.environ["RCON_PASSWORD"],
        "state_file": os.environ.get("STATE_FILE", "/state/mod_watcher_state.json"),
        "max_restart_wait": int(os.environ.get("MAX_RESTART_WAIT_SECONDS", "3600")),
        "empty_check_interval": int(os.environ.get("EMPTY_CHECK_INTERVAL_SECONDS", "60")),
        "empty_restart_grace": int(os.environ.get("EMPTY_RESTART_GRACE_SECONDS", "10")),
        "forced_restart_warning": int(os.environ.get("FORCED_RESTART_WARNING_SECONDS", "300")),
        "shutdown_timeout": int(os.environ.get("SHUTDOWN_TIMEOUT_SECONDS", "120")),
    }


def _recvall(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("RCON connection closed unexpectedly")
        buf += chunk
    return buf


def _send_packet(sock, pkt_id, pkt_type, body):
    payload = struct.pack("<ii", pkt_id, pkt_type) + body.encode("utf-8") + b"\x00\x00"
    sock.sendall(struct.pack("<i", len(payload)) + payload)


def _read_packet(sock):
    length = struct.unpack("<i", _recvall(sock, 4))[0]
    data = _recvall(sock, length)
    pkt_id, pkt_type = struct.unpack("<ii", data[:8])
    body = data[8:-2].decode("utf-8", errors="replace")
    return pkt_id, pkt_type, body


def rcon_command(host, port, password, command, timeout=10):
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)

        _send_packet(sock, 1, SERVERDATA_AUTH, password)
        auth_id, _, _ = _read_packet(sock)
        if auth_id == -1:
            raise PermissionError("RCON authentication failed (bad password)")

        _send_packet(sock, 2, SERVERDATA_EXECCOMMAND, command)
        _, _, body = _read_packet(sock)
        return body


def rcon_port_open(host, port, timeout=5):
    """True if something is listening on the RCON port.

    Used to confirm the server actually went down after a 'quit' - the listener
    stays closed for the whole steamcmd update on the way back up.
    """
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def send_servermsg(cfg, message):
    # Strip quotes so the message can't break out of the command's own quoting.
    safe = message.replace('"', "")
    try:
        rcon_command(cfg["rcon_host"], cfg["rcon_port"], cfg["rcon_password"], f'servermsg "{safe}"')
    except Exception:
        log.exception("Failed to send server message: %s", safe)


def rcon_player_count(cfg):
    """Number of connected players, or None if it couldn't be determined."""
    try:
        body = rcon_command(cfg["rcon_host"], cfg["rcon_port"], cfg["rcon_password"], "players")
    except Exception:
        log.exception("Failed to query player list over RCON")
        return None

    match = PLAYER_COUNT_RE.search(body)
    if match:
        return int(match.group(1))

    named = [ln for ln in body.splitlines() if ln.strip().startswith("-")]
    if named:
        return len(named)

    log.warning("Could not parse player count from RCON response: %r", body)
    return None


def fetch_mod_timestamps(mod_ids):
    payload = {"itemcount": len(mod_ids)}
    for i, mod_id in enumerate(mod_ids):
        payload[f"publishedfileids[{i}]"] = mod_id

    resp = requests.post(STEAM_API_URL, data=payload, timeout=15)
    resp.raise_for_status()
    details = resp.json()["response"].get("publishedfiledetails", [])

    timestamps = {}
    for entry in details:
        if entry.get("result") != 1:
            log.warning(
                "Steam API returned non-OK result for mod %s: %s",
                entry.get("publishedfileid"), entry.get("result"),
            )
            continue
        timestamps[entry["publishedfileid"]] = entry["time_updated"]
    return timestamps


def load_state(path):
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return {}


def save_state(path, state):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, path)


def wait_for_empty_server(cfg):
    """Block until nobody is connected. True if it emptied, False if we hit the cap.

    An unreadable player count counts as "occupied" so we never kick people off a
    server we can't actually see into.
    """
    deadline = time.monotonic() + cfg["max_restart_wait"]

    while True:
        count = rcon_player_count(cfg)
        if count == 0:
            return True
        if count is None:
            log.warning("Player count unavailable; treating the server as occupied.")
        else:
            log.info("%d player(s) still connected; deferring restart.", count)

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(cfg["empty_check_interval"], remaining))


def wait_for_shutdown(cfg):
    deadline = time.monotonic() + cfg["shutdown_timeout"]

    while time.monotonic() < deadline:
        if not rcon_port_open(cfg["rcon_host"], cfg["rcon_port"]):
            log.info("RCON port closed - shutdown confirmed. Docker will restart the container.")
            return True
        time.sleep(5)

    log.error(
        "Server still listening on RCON after %ds; shutdown not confirmed.",
        cfg["shutdown_timeout"],
    )
    return False


def graceful_restart(cfg, changed_ids):
    """Warn players, wait for an empty server, then save and quit.

    Returns True only once the server is confirmed down. Docker's restart policy
    on the pz-server container does the actual restart, which re-runs steamcmd
    and picks up the updated Workshop content - so this needs no Docker access.
    """
    if not rcon_port_open(cfg["rcon_host"], cfg["rcon_port"]):
        log.error("Server RCON is unreachable; skipping restart and retrying next cycle.")
        return False

    log.info("Beginning restart sequence for updated mod(s): %s", ", ".join(changed_ids))
    send_servermsg(
        cfg,
        f"Workshop mod update detected ({len(changed_ids)} mod(s)). "
        "The server will restart once it is empty.",
    )

    if wait_for_empty_server(cfg):
        log.info("Server is empty; restarting after a %ds grace period.", cfg["empty_restart_grace"])
        send_servermsg(cfg, "Server is empty - restarting now to apply mod updates.")
        time.sleep(cfg["empty_restart_grace"])
    else:
        warning = cfg["forced_restart_warning"]
        log.info("Max wait reached with players online; forcing restart in %ds.", warning)
        send_servermsg(
            cfg,
            f"Restarting in {max(1, warning // 60)} minute(s) to apply mod updates. "
            "Please get somewhere safe and log out.",
        )
        time.sleep(warning)

    log.info("Sending 'save' over RCON.")
    try:
        rcon_command(cfg["rcon_host"], cfg["rcon_port"], cfg["rcon_password"], "save")
    except Exception:
        log.exception("RCON 'save' failed; continuing to 'quit' (PZ's quit saves as well)")

    log.info("Sending 'quit' over RCON.")
    try:
        rcon_command(cfg["rcon_host"], cfg["rcon_port"], cfg["rcon_password"], "quit")
    except PermissionError:
        log.exception("RCON authentication failed; cannot shut the server down")
        return False
    except OSError:
        # Expected: the server often dies before it manages to write a reply.
        log.info("RCON connection dropped during 'quit' - confirming via port check.")
    except Exception:
        log.exception("Unexpected error sending 'quit'")
        return False

    return wait_for_shutdown(cfg)


def main():
    cfg = load_config()
    if not cfg["mod_ids"]:
        log.error("WORKSHOP_ITEMS is empty; nothing to watch. Exiting.")
        sys.exit(1)

    state = load_state(cfg["state_file"])
    first_run = not state

    while True:
        try:
            current = fetch_mod_timestamps(cfg["mod_ids"])
            if first_run:
                log.info("Baseline established for %d mod(s).", len(current))
                save_state(cfg["state_file"], current)
                state = current
                first_run = False
            else:
                changed = [mid for mid, ts in current.items() if str(state.get(mid)) != str(ts)]
                if changed:
                    log.info("Detected update for mod(s): %s", ", ".join(changed))
                    if graceful_restart(cfg, changed):
                        # Commit only once the shutdown is confirmed, so a failed
                        # attempt is retried next cycle rather than silently lost.
                        state = current
                        save_state(cfg["state_file"], state)
                    else:
                        log.error("Restart could not be confirmed; retrying next cycle.")
                else:
                    log.info("No mod updates detected (%d mod(s) checked).", len(current))
        except Exception:
            log.exception("Error during mod check cycle; will retry next interval")

        time.sleep(cfg["poll_interval"])


if __name__ == "__main__":
    main()
