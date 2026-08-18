#!/usr/bin/env python3
"""Read-only diagnostic for the assumptions mod_watcher makes about the server.

    docker compose exec mod-watcher python probe.py

Every check is non-destructive. It authenticates over RCON and issues the
read-only "players" command; it never sends save/quit/servermsg, and never
writes the state file. Exit status is 0 when nothing failed, 1 otherwise.

The two things most worth confirming here are that the RCON packet stream is
aligned (mod_watcher reads exactly one packet per request) and that the real
"players" output actually matches PLAYER_COUNT_RE - if it doesn't, the watcher
silently treats the server as permanently occupied and never restarts on empty.
"""

import argparse
import os
import socket
import sys

import mod_watcher as mw

PASS, WARN, FAIL = "[ OK ]", "[WARN]", "[FAIL]"

_counts = {"fail": 0, "warn": 0}


def report(status, message, detail=None):
    print(f"{status} {message}")
    if detail:
        for line in str(detail).splitlines():
            print(f"       {line}")
    if status == FAIL:
        _counts["fail"] += 1
    elif status == WARN:
        _counts["warn"] += 1


def section(title):
    print(f"\n--- {title} ---")


def drain_packets(sock, first_timeout, idle_timeout):
    """Read packets until the server goes quiet. Returns (packets, error)."""
    packets = []
    sock.settimeout(first_timeout)
    while True:
        try:
            packets.append(mw._read_packet(sock))
        except (socket.timeout, TimeoutError):
            return packets, None
        except Exception as exc:
            return packets, exc
        sock.settimeout(idle_timeout)


def describe(packets):
    return "\n".join(
        f"packet {i}: id={pid} type={ptype} body={body!r}"
        for i, (pid, ptype, body) in enumerate(packets)
    )


def check_config():
    section("Configuration")
    try:
        cfg = mw.load_config()
    except KeyError as exc:
        report(FAIL, f"Missing required environment variable: {exc}")
        return None

    report(PASS, f"RCON target is {cfg['rcon_host']}:{cfg['rcon_port']}")
    if cfg["mod_ids"]:
        report(PASS, f"WORKSHOP_ITEMS lists {len(cfg['mod_ids'])} mod(s)")
    else:
        report(FAIL, "WORKSHOP_ITEMS is empty; the watcher would exit at startup")
    return cfg


def check_port(cfg):
    section("RCON reachability")
    if mw.rcon_port_open(cfg["rcon_host"], cfg["rcon_port"]):
        report(PASS, "RCON port is accepting connections")
        return True
    report(FAIL, "Nothing is listening on the RCON port", "Is pz-server up, and is CFG_RCONPort set?")
    return False


def check_handshake(cfg, timeout):
    """Confirm the packet stream stays aligned with mod_watcher's one-read-per-request model."""
    section("RCON packet alignment")
    try:
        with socket.create_connection((cfg["rcon_host"], cfg["rcon_port"]), timeout=timeout) as sock:
            mw._send_packet(sock, 1, mw.SERVERDATA_AUTH, cfg["rcon_password"])
            auth_packets, auth_err = drain_packets(sock, timeout, 2.0)

            if auth_err:
                report(FAIL, "Error while reading the auth response", auth_err)
                return None
            if not auth_packets:
                report(FAIL, "Server sent no auth response at all")
                return None

            print(describe(auth_packets))

            if any(pid == -1 for pid, _, _ in auth_packets):
                report(FAIL, "Server rejected the password (auth id -1)", "Check RCON_PASSWORD vs CFG_RCONPassword.")
                return None

            if len(auth_packets) == 1:
                report(PASS, "Auth returns exactly 1 packet, matching mod_watcher's single read")
            else:
                report(
                    FAIL,
                    f"Auth returns {len(auth_packets)} packets but mod_watcher reads only 1",
                    "The stream is off by one from here on: rcon_command() would return the\n"
                    "leftover auth packet as the command body, and a wrong password would go\n"
                    "undetected. rcon_command() needs to drain until the AUTH_RESPONSE.",
                )

            # Same question for a command response, on the now-authenticated socket.
            mw._send_packet(sock, 2, mw.SERVERDATA_EXECCOMMAND, "players")
            cmd_packets, cmd_err = drain_packets(sock, timeout, 2.0)

            if cmd_err:
                report(WARN, "Error while draining the command response", cmd_err)
            if not cmd_packets:
                report(FAIL, "Server sent no response to 'players'")
                return None

            print(describe(cmd_packets))
            if len(cmd_packets) == 1:
                report(PASS, "'players' returns exactly 1 packet")
            else:
                report(
                    WARN,
                    f"'players' returned {len(cmd_packets)} packets; mod_watcher would read only the first",
                    "Likely a body over the ~4KB packet limit. Fine at low player counts,\n"
                    "but the count could be truncated on a busy server.",
                )
            return "".join(body for _, _, body in cmd_packets)
    except OSError as exc:
        report(FAIL, "Could not complete the RCON handshake", exc)
        return None


def check_player_parsing(cfg, raw_body):
    """The parse that decides whether a restart is ever allowed to happen."""
    section("Player count parsing")
    if raw_body is not None:
        print(f"raw 'players' body: {raw_body!r}")

    body = mw.rcon_command(cfg["rcon_host"], cfg["rcon_port"], cfg["rcon_password"], "players")

    if mw.PLAYER_COUNT_RE.search(body):
        report(PASS, f"PLAYER_COUNT_RE matched -> {mw.PLAYER_COUNT_RE.search(body).group(1)} player(s)")
    elif [ln for ln in body.splitlines() if ln.strip().startswith("-")]:
        report(WARN, "PLAYER_COUNT_RE did not match; fell back to counting '-Name' lines",
               "Works, but the regex should be updated to match the real B42 wording.")
    else:
        report(FAIL, "Neither the regex nor the '-Name' fallback matched",
               "rcon_player_count() returns None, which wait_for_empty_server() treats as\n"
               "'occupied' - so the watcher would never restart on an empty server and would\n"
               "always fall through to the forced-restart path after MAX_RESTART_WAIT_SECONDS.")

    count = mw.rcon_player_count(cfg)
    if count is None:
        report(FAIL, "rcon_player_count() returned None")
    else:
        report(PASS, f"rcon_player_count() returned {count}")
        if count == 0:
            print("       Note: re-run this with someone connected to exercise the non-empty path.")


def check_bad_password(cfg, timeout):
    section("Wrong-password rejection")
    try:
        mw.rcon_command(cfg["rcon_host"], cfg["rcon_port"], cfg["rcon_password"] + "_wrong",
                        "players", timeout=timeout)
    except PermissionError:
        report(PASS, "A bad password raises PermissionError as expected")
        return
    except OSError as exc:
        report(WARN, "Server closed the connection instead of replying with auth id -1", exc)
        return
    report(FAIL, "A bad password was accepted",
           "graceful_restart() relies on PermissionError to abort; without it a password\n"
           "mismatch looks like a successful restart. Usually a symptom of the packet\n"
           "misalignment reported above.")


def check_steam(cfg):
    section("Steam Workshop API")
    try:
        timestamps = mw.fetch_mod_timestamps(cfg["mod_ids"])
    except Exception as exc:
        report(FAIL, "Could not query the Steam API", exc)
        return None

    report(PASS, f"Steam returned timestamps for {len(timestamps)}/{len(cfg['mod_ids'])} mod(s)")
    missing = [m for m in cfg["mod_ids"] if m not in timestamps]
    if missing:
        report(WARN, f"{len(missing)} configured mod(s) had no usable Steam entry",
               "These are skipped by the update check (delisted, private, or a bad ID):\n"
               + ", ".join(missing))
    return timestamps


def check_state(cfg, timestamps):
    section("State file")
    path = cfg["state_file"]
    directory = os.path.dirname(path)

    write_test = os.path.join(directory, ".probe_write_test")
    try:
        os.makedirs(directory, exist_ok=True)
        with open(write_test, "w") as handle:
            handle.write("probe")
        os.unlink(write_test)
        report(PASS, f"{directory} is writable")
    except OSError as exc:
        report(FAIL, f"{directory} is not writable by this container",
               f"{exc}\nsave_state() would throw every cycle and the baseline would never\n"
               "persist. Usually a root-owned ./mod_watcher_state bind mount vs UID 1000.")
        return

    try:
        state = mw.load_state(path)
    except Exception as exc:
        report(FAIL, "Existing state file could not be parsed", exc)
        return

    if not state:
        report(WARN, "No baseline recorded yet",
               "Normal on a first run: the next poll records a baseline without restarting.")
        return

    report(PASS, f"Baseline holds {len(state)} mod(s)")

    if timestamps:
        untracked = [m for m in timestamps if str(state.get(m)) != str(timestamps[m])]
        if untracked:
            report(WARN, f"{len(untracked)} mod(s) differ from the recorded baseline",
                   "The next poll will treat these as updates and start a restart cycle:\n"
                   + ", ".join(untracked))
        else:
            report(PASS, "Baseline matches current Steam timestamps; no restart pending")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--timeout", type=float, default=10.0, help="RCON socket timeout (default: 10)")
    parser.add_argument("--test-bad-password", action="store_true",
                        help="Also verify a wrong password is rejected. Off by default because "
                             "some RCON implementations throttle or ban on failed auth.")
    parser.add_argument("--skip-steam", action="store_true",
                        help="Skip the Steam API and state checks (RCON only)")
    args = parser.parse_args()

    cfg = check_config()
    if cfg is None:
        return 1

    raw_body = None
    if check_port(cfg):
        raw_body = check_handshake(cfg, args.timeout)
        try:
            check_player_parsing(cfg, raw_body)
        except Exception as exc:
            report(FAIL, "Player count check raised", exc)
        if args.test_bad_password:
            check_bad_password(cfg, args.timeout)

    if not args.skip_steam:
        timestamps = check_steam(cfg)
        check_state(cfg, timestamps)

    section("Summary")
    if _counts["fail"]:
        report_line = f"{_counts['fail']} failure(s), {_counts['warn']} warning(s)"
        print(f"{FAIL} {report_line}")
        return 1
    if _counts["warn"]:
        print(f"{WARN} No failures, {_counts['warn']} warning(s)")
        return 0
    print(f"{PASS} All checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
