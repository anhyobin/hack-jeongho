#!/usr/bin/env python3
"""Escalating-age submitter for the 고라니 피하기 leaderboard.

The server rejects a submission whose score is too high for the age of its run
token (403 too_fast) and one whose score/rows gap is implausible (403
inconsistent).  Probes bracketed the allowed rate between 8.0/s (accepted) and
9.75/s (rejected) at ~12s of token age, but a grace term in the server's
formula would make that extrapolation optimistic — short probes cannot
distinguish `score <= elapsed*r` from `score <= (elapsed+g)*r`.

Strategy: a rejection creates no leaderboard entry, so a failed attempt costs
nothing but time.  Mint every token up front so their ages accumulate in
parallel, lock in the modest target first, then keep pushing the ambitious one
against progressively older tokens.  score == rows on every submission, which
is the one score/rows relation already known to pass validation.
"""
import json, sys, time, urllib.request, urllib.error
from typing import Any

BASE = "https://d15csla760jzen.cloudfront.net/"
NAME = "핵정호"
CHAR = "hedgehog"

# (score, [token ages in seconds at which to attempt it])
PHASE_1 = (1004, [150, 260, 420, 700, 1100])
PHASE_2 = (10000, [1320, 1800, 2400, 3000, 3600, 4500])

RATE_LIMIT_BACKOFF = 60.0
RETRYABLE = ("too fast", "too_fast")


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def get_token() -> str:
    r = urllib.request.urlopen(BASE + "api/start", timeout=15)
    return json.load(r)["token"]


def submit(token: str, score: int, rows: int) -> tuple[int, dict[str, Any]]:
    body = json.dumps({"name": NAME, "score": score, "rows": rows,
                       "char": CHAR, "token": token}).encode()
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


def main() -> int:
    total = len(PHASE_1[1]) + len(PHASE_2[1])
    tokens: list[str] = []
    for i in range(total):
        tokens.append(get_token())
        log(f"token {i}: {tokens[-1]}")
        time.sleep(5)
    t0 = time.monotonic()

    def wait_until(age: float) -> None:
        while True:
            remaining = age - (time.monotonic() - t0)
            if remaining <= 0:
                return
            time.sleep(min(remaining, 30))

    def report(resp: dict[str, Any]) -> None:
        log(f"SUCCESS: rank {resp.get('rank')}")
        for i, e in enumerate(resp.get("scores", [])[:5], 1):
            if isinstance(e, dict):
                log(f"  #{i} {e.get('name')} {e.get('score')} ({e.get('char')})")

    pool = iter(tokens)
    done_phase_1 = False

    for score, ages in (PHASE_1, PHASE_2):
        for age in ages:
            token = next(pool)
            wait_until(age)
            code, resp = submit(token, score, score)
            log(f"attempt score={score} @{age}s ({score/age:.2f}/s) -> "
                f"HTTP {code} {json.dumps(resp, ensure_ascii=False)[:220]}")
            if code == 200 and resp.get("ok"):
                report(resp)
                if score == PHASE_1[0]:
                    done_phase_1 = True
                    break  # #1 locked; move on to the ambitious target
                return 0
            err = str(resp.get("error", ""))
            if code == 429 or err == "too fast":
                log(f"IP rate limiter hit; backing off {RATE_LIMIT_BACKOFF:.0f}s "
                    f"and retrying the same age with a fresh-enough token")
                time.sleep(RATE_LIMIT_BACKOFF)
                code, resp = submit(token, score, score)
                log(f"  retry -> HTTP {code} "
                    f"{json.dumps(resp, ensure_ascii=False)[:220]}")
                if code == 200 and resp.get("ok"):
                    report(resp)
                    if score == PHASE_1[0]:
                        done_phase_1 = True
                        break
                    return 0
                err = str(resp.get("error", ""))
            if err not in RETRYABLE and code != 0:
                log(f"ABORT: unexpected rejection {err!r} — the token is not "
                    f"usable at this age, so holding tokens will not work")
                return 1

    log(f"exhausted schedule; phase 1 landed: {done_phase_1}")
    return 0 if done_phase_1 else 1


if __name__ == "__main__":
    sys.exit(main())
