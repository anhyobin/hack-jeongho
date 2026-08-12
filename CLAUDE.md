# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A reverse-engineering workspace for a **live third-party web game** — not an application to build. It contains (a) the recovered source of that game and (b) the Python toolchain that recovered it. There is no build system and no test suite. The primary deliverable is `GAME_STRUCTURE.md` (1,190 lines), a line-accurate analysis of the game.

The workspace is tracked in the **private** repo `anhyobin/hack-jeongho` (branch `main`). Keep it private — `recovered/` is derived from another author's code. The game binaries (`_dl/index.pck`, `_dl/index.js`, `_dl/extracted/`) are gitignored and must be re-downloaded to re-run the pipeline.

Target: **고라니 피하기**, a Godot 4.7.1 HTML5/WebAssembly export served at `https://d15csla760jzen.cloudfront.net/` — a 640x960 portrait Crossy-Road/Frogger-style endless arcade game. The origin is a single Python `http.server` process behind CloudFront that serves both the static export and the `/api/*` leaderboard.

## Commands

**Python 3.14+ is required** — `gdc_decompile.py` does `from compression import zstd`, which is stdlib only from 3.14.

All three analysis scripts use hardcoded relative paths, so the working directory matters:

```bash
# 1. unpack the GDPC container -> _dl/extracted/ (110 entries), manifest to stdout
cd _dl && python3 unpack.py > ../unpacked_manifest.txt

# 2. decompile the 8 binary-token scripts (writes *.decompiled.gd beside each input)
cd _dl/extracted/scripts && python3 ../../gdc_decompile.py *.gdc

# 3. dump project.binary settings + sprite/audio inventory
cd _dl && python3 inspect_assets.py

# leaderboard: mint a token, wait, submit once; prints age, rate and raw response
python3 tools/board_probe.py <wait_seconds> <score> [rows] [name] [char]

# leaderboard: mint N tokens up front, retry one target score at escalating ages
# (default ages 480,600,720 — stops at the first acceptance)
python3 tools/submit_target.py <score> <name> [char] [ages] [rows]
```

`tools/` holds byte-identical copies of the three `_dl/` scripts — a change to one needs the same change to the other, or drop one copy.

## The integrity invariant: leftover = 0

`gdc_decompile.py` prints `leftover=N` — bytes remaining after consuming exactly the declared counts of identifiers, constants, line maps and tokens. All 8 files report **0**, which is the evidence that the recovered source is token-for-token complete. If a decompiler change makes `leftover` nonzero, its output is not trustworthy.

`token_lines`/`token_columns` survive in the pack, so every `file.gd:LINE` citation in `GAME_STRUCTURE.md` **matches the original line numbers**. Preserve line numbering when touching `recovered/`, or those references silently rot.

## recovered/ is a restoration, not code to improve

`recovered/*.gd` is byte-identical to `_dl/extracted/scripts/*.decompiled.gd` and is the canonical copy. The dead code in it belongs to the original author, not to the decompiler: `Ranking.server_ok` is assigned three times and never read, `UI.font_s` is loaded and unused, `UI.show_game_over`'s `stage_i` parameter is ignored, `Row.train_half`'s default `410.0` is always overwritten with `415`. Leave them — they are evidence.

Comments are **unrecoverable** (the tokenizer never stores them). Every statement about developer intent is inference; `GAME_STRUCTURE.md` marks those 추정, and new claims should follow that convention.

## Game architecture (what takes several files to see)

- **One scene.** `res://main.tscn` is a single `Node` with `main.gd` attached. Player, rows, vehicles, logs, trains, snow and all five screens (title/HUD/game-over/ranking/pause) are assembled imperatively at runtime via `Row.new()`, `Label.new()`, `ColorRect.new()`. 1,880 lines across 8 modules is the entire game — which is why decompiling the scripts recovered 100% of it.
- **`main.gd` is the state machine and the service locator.** It owns `ranking`/`ui`/`sfx`/`game` and routes every transition. `UI` and `Game` never reference each other; they communicate through `main`.
- **Scoring.** `score() = max_row - start_row + bonus`, `rows_crossed() = max_row - start_row` (game.gd:315-319). `bonus` only ever grows by `+= 2` (near-miss), so `score >= rows` holds on honest play — the invariant the server checks.
- **`?s=N`** jumps to stage N (`start_row = clampi(N,0,500) * 20`) but cannot inflate score, because `start_row` is subtracted back out.
- **Async discipline.** `Main._over_token` is a generation counter re-checked after every `await` so stale coroutines abandon quietly; `ui.gd` does the same with `cur[0] != want` for stale leaderboard responses. Keep that pattern if you patch either file.

## Leaderboard API and its server-side validation

Contract (ranking.gd:69-108) — API base is derived from the page URL, so game and API are always same-origin:

| endpoint | request | response |
|---|---|---|
| `GET api/start` | — | `{"token": "<epoch>.<hex16>.<hex16>"}` |
| `GET api/scores[?char=<id>]` | — | `{"scores": [...]}`, top 50, score-descending |
| `POST api/scores` | `{name, score, rows, char, token}` | `{"ok", "rank", "scores"}` |

The server has no published source; these rules were established by observation:

| response | meaning |
|---|---|
| `403 {"error": "too_fast"}` | `score` too high for the token's age |
| `403 {"error": "inconsistent"}` | `score > rows * 2` (2.0x passed, 10x rejected) |
| `{"error": "token:reused"}` | token already spent — **a rejected attempt spends it too** |
| `429 {"error": "too fast"}` — space, not underscore | per-IP submit throttle, easy to trip with concurrent POSTs |

Checks run in that order bottom-up: **throttle first, then token, then consistency, then rate.** A request with a bogus `token` — or no `token` field at all — still answers `429 too fast` while throttled, which is how the ordering was established. Burst a batch of probes and every response after the first tells you about the throttle, not about your score. Space them ≥30s.

One token buys exactly one attempt, so "submit and retry on rejection" needs a fresh token per try; that is why `submit_target.py` (and the older two-phase `submit_run.py`, kept as a record) mints them in bulk. A 429 is the exception — the throttle precedes token validation, so a throttled request does not spend its token and the same one can be retried after a backoff.

Measured boundary: 100 pts at 12.5s of token age (8.0/s), 1004 pts at 150s (6.69/s) and 3000 pts at 490s (6.12/s) were **accepted**; 120 pts at 12.3s (9.75/s) was **rejected**. Fitting `score <= (elapsed + g) * r` to those points forces `g < 6.4s`, so the rule is near a plain ratio with `r` roughly in 6.4–9.75 pts/s. Treating 6.4/s as the safe rate is validated: 3000 pts landed on the **first** attempt at a scheduled 480s, 11s over what 6.4/s demands. Tokens are known good to 490s of age; no absolute score cap exists below 3000. When quoting a rate from a scheduler log, check the age against the token's own mint time — a bulk-minting scheduler whose `t0` is the *last* mint understates the age of every earlier token.

Entries carrying `"admin_insert": true` (observed on `호호호 2500`) were inserted by the server operator outside the POST path — exclude them when reasoning about what validation accepts.

Two facts make the boundary cheap to search: a rejection **creates no leaderboard entry**, and nothing binds a token to a browser session — tokens can be minted in bulk up front and aged in parallel. So escalating token age against a fixed target score costs only wall-clock, and the first acceptance is the desired result. Submit with `score == rows` unless you have a reason not to; `score <= rows * 2` is the measured allowance, and the server stores `stage = floor(rows/20)` (0-based, not the 1-based number the in-game banner shows). Space POSTs ≥60s apart to stay clear of the 429 limiter.

## Working against the live target

Every request here hits a service someone else runs — a single-threaded Python process, with `/api/*` set to `no-cache` so nothing is absorbed by the CDN edge. Keep request volume low and serialized. There is **no delete endpoint**: a submitted score cannot be withdrawn, so treat each POST as permanent and submit the minimum needed.
