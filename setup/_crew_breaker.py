#!/usr/bin/env python3
"""crew_proxy.breaker — per-key-alias circuit breaker."""

import json
import logging
import os
import threading

from _crew_config import (
    COOLDOWN, FAIL_N, STATE_FILE, log,
)

# ── circuit breaker (per key alias) ───────────────────────────────────────────────
class Breaker:
    """Per-alias consecutive-failure counter with a cooldown trip. Thread-safe."""

    def __init__(self):
        self._lock = threading.Lock()
        self._fails = {}      # alias -> consecutive failure count
        self._tripped = {}    # alias -> cooldown-expiry epoch
        self._load()

    def healthy(self, alias, now):
        exp = self._tripped.get(alias)
        if exp is None:
            return True
        if now >= exp:            # cooldown elapsed -> auto-recover
            self._tripped.pop(alias, None)
            self._fails[alias] = 0
            return True
        return False

    def pick(self, aliases, now):
        """Highest-priority healthy alias; None if every alias is tripped."""
        with self._lock:
            for a in aliases:
                if self.healthy(a, now):
                    return a
            return None

    def record_ok(self, alias):
        with self._lock:
            if self._fails.get(alias):
                self._fails[alias] = 0
            self._persist()

    def record_fail(self, alias, now, cooldown=None):
        """Increment; trip at FAIL_N. Returns True if this failure tripped the key.
        cooldown: seconds to park a tripped key (default None -> the single COOLDOWN
        constant, i.e. behavior identical to before tiered cooldown was added)."""
        cd = COOLDOWN if cooldown is None else cooldown
        with self._lock:
            n = self._fails.get(alias, 0) + 1
            self._fails[alias] = n
            tripped = False
            if n >= FAIL_N:
                self._tripped[alias] = now + cd
                tripped = True
                log.warning("key '%s' TRIPPED after %d fails; cooling down %.0fs", alias, n, cd)
            self._persist()
            return tripped

    def snapshot(self, aliases, now):
        """Per-alias {consec_fails, state, cooldown_left} for the dashboard. Read-only:
        does NOT mutate (unlike healthy(), which auto-recovers) so /api/status is side-effect free."""
        out = {}
        with self._lock:
            for a in aliases:
                exp = self._tripped.get(a)
                if exp is not None and now < exp:
                    out[a] = {"consec_fails": self._fails.get(a, 0), "state": "tripped",
                              "cooldown_left": round(exp - now)}
                else:
                    out[a] = {"consec_fails": self._fails.get(a, 0), "state": "healthy",
                              "cooldown_left": 0}
        return out

    # -- persistence (best effort; state survives restart) --
    def _persist(self):
        try:
            os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
            tmp = STATE_FILE + ".tmp"
            with open(tmp, "w") as f:
                json.dump({"fails": self._fails, "tripped": self._tripped}, f)
            os.replace(tmp, STATE_FILE)
        except OSError:
            pass

    def _load(self):
        try:
            with open(STATE_FILE) as f:
                d = json.load(f)
            self._fails = {str(k): int(v) for k, v in (d.get("fails") or {}).items()}
            self._tripped = {str(k): float(v) for k, v in (d.get("tripped") or {}).items()}
        except (FileNotFoundError, json.JSONDecodeError, ValueError):
            pass


BREAKER = Breaker()
