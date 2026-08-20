#!/usr/bin/env python3
"""Drive graceful_restart() against a stub RCON server.

The player-presence branches are impractical to test against a live server: the
forced-restart path needs MAX_RESTART_WAIT_SECONDS to elapse (an hour by
default) with someone actually logged in, and the "count unavailable" path needs
RCON to be broken in a specific way. This serves a scripted sequence of player
counts instead, so every branch runs deterministically in seconds against the
real mod_watcher code.

  docker compose run --rm --no-deps --entrypoint python mod-watcher test_restart_logic.py
"""
import socket, struct, threading, time, logging, sys
import mod_watcher as mw

RESPONSE_VALUE, AUTH_RESPONSE = 0, 2
PASSWORD = "stub"


class StubRcon:
    """Minimal Source RCON server serving a scripted player-count sequence."""

    def __init__(self, counts, close_on_quit=True):
        self.counts = list(counts)
        self.close_on_quit = close_on_quit
        self.commands = []
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        self._stop = False
        threading.Thread(target=self._serve, daemon=True).start()

    def _pkt(self, pid, ptype, body):
        b = body.encode()
        return struct.pack("<iii", 10 + len(b), pid, ptype) + b + b"\x00\x00"

    def _next_count(self):
        # Last value repeats forever, so "3 players indefinitely" is expressible.
        return self.counts[0] if len(self.counts) == 1 else self.counts.pop(0)

    def _serve(self):
        while not self._stop:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        try:
            with conn:
                while True:
                    hdr = conn.recv(4)
                    if not hdr:
                        return
                    body = conn.recv(struct.unpack("<i", hdr)[0])
                    pid, ptype = struct.unpack("<ii", body[:8])
                    payload = body[8:-2].decode(errors="replace")

                    if ptype == mw.SERVERDATA_AUTH:
                        ok = payload == PASSWORD
                        # Two packets, exactly as a real server replies. A client
                        # that reads only one desyncs -- the bug this catches.
                        conn.sendall(self._pkt(pid, RESPONSE_VALUE, ""))
                        conn.sendall(self._pkt(pid if ok else -1, AUTH_RESPONSE, ""))
                        continue

                    self.commands.append(payload)
                    if payload == "players":
                        n = self._next_count()
                        if not isinstance(n, int):
                            # Garbage the parser cannot read, to exercise the
                            # "count unavailable" branch.
                            reply = f"Players connected ({n}): \n"
                        elif n == 0:
                            reply = "Players connected (0): \n"
                        else:
                            reply = (f"Players connected ({n}): \n"
                                     + "\n".join(f"-p{i}" for i in range(n)))
                    elif payload == "quit":
                        conn.sendall(self._pkt(pid, RESPONSE_VALUE, "quitting"))
                        if self.close_on_quit:
                            self._stop = True
                            self.sock.close()
                        return
                    else:
                        reply = "OK"
                    conn.sendall(self._pkt(pid, RESPONSE_VALUE, reply))
        except OSError:
            pass


def run(name, counts, expect, **over):
    stub = StubRcon(counts)
    cfg = {
        "rcon_host": "127.0.0.1", "rcon_port": stub.port, "rcon_password": PASSWORD,
        "max_restart_wait": 6, "empty_check_interval": 1,
        "empty_restart_grace": 0, "forced_restart_warning": 2, "shutdown_timeout": 10,
    }
    cfg.update(over)

    print(f"\n=== {name} ===")
    t0 = time.time()
    ok = mw.graceful_restart(cfg, ["testmod"])
    took = time.time() - t0

    sent = stub.commands
    defers = sum(1 for c in sent if c == "players") - 1
    got = {
        "returned": ok,
        "saved": "save" in sent,
        "quit": "quit" in sent,
        "warned": any(c.startswith("servermsg") and "Restarting in" in c for c in sent),
        "polls": sent.count("players"),
    }
    bad = {k: (v, expect[k]) for k, v in got.items() if k in expect and v != expect[k]}
    print(f"  took {took:.1f}s  polls={got['polls']}  {got}")
    if bad:
        print(f"  FAIL {bad}")
        return False
    print("  PASS")
    return True


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="    | %(message)s")
    results = [
        run("A. server already empty -> restart immediately",
            [0], {"returned": True, "saved": True, "quit": True, "warned": False}),
        run("B. 3 players, then empties -> defers, then restarts",
            [3, 3, 0], {"returned": True, "saved": True, "quit": True, "warned": False}),
        run("C. stays occupied past the cap -> warns, restarts anyway",
            [4], {"returned": True, "saved": True, "quit": True, "warned": True}),
        run("D. player count unreadable -> treated as occupied, still forced",
            ["?"], {"returned": True, "saved": True, "quit": True, "warned": True}),
    ]
    print(f"\n{sum(results)}/{len(results)} passed")
    sys.exit(0 if all(results) else 1)
