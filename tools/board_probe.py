#!/usr/bin/env python3
"""Probe the 고라니 피하기 leaderboard API: token -> wait -> submit.

Usage: board_probe.py <wait_seconds> <score> [rows] [name] [char]
"""
import json, sys, time, urllib.request, urllib.error

BASE = "https://d15csla760jzen.cloudfront.net/"


def get_token():
    """Return (token, local_monotonic_time_at_issue, server_date_header)."""
    r = urllib.request.urlopen(BASE + "api/start", timeout=15)
    payload = json.load(r)
    return payload["token"], time.monotonic(), r.headers.get("date")


def submit(token, name, score, rows, char="hedgehog"):
    body = json.dumps({"name": name, "score": score, "rows": rows,
                       "char": char, "token": token}).encode()
    req = urllib.request.Request(BASE + "api/scores", data=body,
                                 headers={"Content-Type": "application/json"},
                                 method="POST")
    try:
        r = urllib.request.urlopen(req, timeout=20)
        return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


if __name__ == "__main__":
    wait = float(sys.argv[1])
    score = int(sys.argv[2])
    rows = int(sys.argv[3]) if len(sys.argv) > 3 else score
    name = sys.argv[4] if len(sys.argv) > 4 else "probe"
    char = sys.argv[5] if len(sys.argv) > 5 else "hedgehog"
    tok, m0, sdate = get_token()
    time.sleep(wait)
    age = time.monotonic() - m0
    code, resp = submit(tok, name, score, rows, char)
    print(f"age={age:.1f}s score={score} rows={rows} rate={score/age:.2f}/s "
          f"-> HTTP {code} {resp[:400]}")
