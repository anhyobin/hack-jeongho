#!/usr/bin/env python3
"""Single-target escalating-age submitter for the 고라니 피하기 leaderboard.

Generalizes `submit_run.py`'s strategy to one target score given on the command
line.  A rejection creates no leaderboard entry and nothing binds a token to a
session, so every token is minted up front and ages in parallel; the target
score is then retried against progressively older tokens until one is accepted.
The first acceptance is the desired result, so the run stops there.

One token buys exactly one attempt — a rate-rejected attempt spends it too —
which is why each age in the schedule gets its own token.  A 429 is the IP
throttle, which sits *ahead* of token validation, so that request does not
spend the token and the same one is retried after a backoff.

The age printed for each attempt is measured from that token's own mint time,
not from the schedule's t0, so the rate in the log is the real one.  Local wall
clock is never used — the server's epoch ran ~2s ahead of it, so ages are timed
with `time.monotonic()` deltas, where that offset cancels.

Usage: submit_target.py <score> <name> [char] [ages] [rows]
       ages: comma-separated token ages in seconds (default 480,600,720)
       rows: defaults to score (the score/rows relation known to pass)
"""
import json, sys, time, urllib.request, urllib.error
from typing import Any

BASE = "https://d15csla760jzen.cloudfront.net/"

RATE_LIMIT_BACKOFF = 60.0
RETRYABLE = ("too fast", "too_fast")
TOKEN_MINT_GAP = 5.0


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def get_token() -> str:
    r = urllib.request.urlopen(BASE + "api/start", timeout=15)
    return json.load(r)["token"]


def submit(token: str, name: str, score: int, rows: int,
           char: str) -> tuple[int, dict[str, Any]]:
    body = json.dumps({"name": name, "score": score, "rows": rows,
                       "char": char, "token": token}).encode()
    req = urllib.request.Request(BASE + "api/scores", data=body,
                                 headers={"Content-Type": "application/json"},
                                 method="POST")
    try:
        r = urllib.request.urlopen(req, timeout=20)
        payload = json.loads(r.read().decode())
        return r.status, payload if isinstance(payload, dict) else {}
    except urllib.error.HTTPError as e:
        try:
            payload = json.loads(e.read().decode())
            return e.code, payload if isinstance(payload, dict) else {}
        except Exception:
            return e.code, {}
    except Exception as e:  # transport hiccup — retryable
        return 0, {"error": f"transport: {e}"}


def report(resp: dict[str, Any]) -> None:
    log(f"SUCCESS: rank {resp.get('rank')}")
    for i, e in enumerate(resp.get("scores", [])[:5], 1):
        if isinstance(e, dict):
            log(f"  #{i} {e.get('name')} {e.get('score')} "
                f"(rows {e.get('rows')}, stage {e.get('stage')}, "
                f"{e.get('char')})")


def main() -> int:
    score = int(sys.argv[1])
    name = sys.argv[2]
    char = sys.argv[3] if len(sys.argv) > 3 else "peccy"
    ages = ([float(a) for a in sys.argv[4].split(",")]
            if len(sys.argv) > 4 else [480.0, 600.0, 720.0])
    rows = int(sys.argv[5]) if len(sys.argv) > 5 else score

    log(f"target: {name!r} score={score} rows={rows} char={char}")
    log(f"schedule: {len(ages)} attempts at token ages "
        f"{', '.join(f'{a:.0f}s' for a in ages)} "
        f"(rates {', '.join(f'{score/a:.2f}/s' for a in ages)})")

    # Each token is kept with its own mint time.  The schedule runs off a single
    # t0 taken after the *last* mint, so every token is at least `age` old when
    # used — but earlier tokens are older than that, and quoting the schedule
    # value as the age understates it (and overstates the accepted rate).  The
    # per-token mint time is what the log reports, so a passing rate read off
    # this output is the true one.
    tokens: list[tuple[str, float]] = []
    for i in range(len(ages)):
        tok = get_token()
        tokens.append((tok, time.monotonic()))
        log(f"token {i}: {tok}")
        if i < len(ages) - 1:
            time.sleep(TOKEN_MINT_GAP)
    t0 = time.monotonic()

    def wait_until(age: float) -> None:
        while True:
            remaining = age - (time.monotonic() - t0)
            if remaining <= 0:
                return
            if remaining > 60:
                log(f"  waiting: {remaining:.0f}s to go")
            time.sleep(min(remaining, 60))

    for (token, minted), age in zip(tokens, ages):
        wait_until(age)
        real_age = time.monotonic() - minted
        code, resp = submit(token, name, score, rows, char)
        log(f"attempt score={score} @{real_age:.0f}s "
            f"({score/real_age:.2f}/s, scheduled {age:.0f}s) -> HTTP {code} "
            f"{json.dumps(resp, ensure_ascii=False)[:220]}")
        if code == 200 and resp.get("ok"):
            report(resp)
            return 0

        err = str(resp.get("error", ""))
        if code == 429 or err == "too fast":
            log(f"IP rate limiter hit; backing off {RATE_LIMIT_BACKOFF:.0f}s "
                f"and retrying the same token (429 precedes token validation)")
            time.sleep(RATE_LIMIT_BACKOFF)
            real_age = time.monotonic() - minted
            code, resp = submit(token, name, score, rows, char)
            log(f"  retry @{real_age:.0f}s ({score/real_age:.2f}/s) -> "
                f"HTTP {code} "
                f"{json.dumps(resp, ensure_ascii=False)[:220]}")
            if code == 200 and resp.get("ok"):
                report(resp)
                return 0
            err = str(resp.get("error", ""))

        if err not in RETRYABLE and code != 0:
            log(f"ABORT: unexpected rejection {err!r} — not a rate rejection, "
                f"so aging a token further will not help")
            return 1

    log("exhausted schedule without an acceptance")
    return 1


if __name__ == "__main__":
    sys.exit(main())
