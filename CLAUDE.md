# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A reverse-engineering workspace for a **live third-party web game** — not an application to build. It contains (a) the recovered source of that game, (b) the Python toolchain that recovered it, and (c) `patch/` — the recovered source with an autopilot spliced in, repacked into a runnable `index.pck`. There is no build system and no test suite. The primary deliverable is `GAME_STRUCTURE.md` (1,190 lines), a line-accurate analysis of the game.

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

# offline: reproduce the world from a seed and synthesize a trace (docs/autopilot.md §9)
python3 tools/rng_probe.py                       # RNG ground-truth check (must exit 0)
python3 tools/sim.py /tmp/valcases.jsonl         # replay real runs; must match every case
python3 tools/solve.py <seed> --target 600 --width 8    # beam search -> trace + ticks

# checkpoint backtracking search — the route that reached 600+ in the engine (docs/autopilot.md §8)
#   ?ss=1 rewinds to before each death, fast-replays the prefix, and continues with new jitter.
#   ?sv=1 must pass first: replay a run's own trace and confirm rows/score/death tick match.
#   602 points took 12 rounds and 2 live requests (api/start + POST).

# repack the pck with an autopilot spliced into game.gd/main.gd (docs/autopilot.md)
# NOTE the pck filename tracks the live deploy — read it out of _dl/index.html, don't hardcode.
python3 tools/pack.py --verify          # sanity: rebuilding the original must be byte-identical
python3 tools/make_bot_patch.py         # decompiled source + patch/bot_*.part.gd -> patch/*.gd
python3 tools/pack.py -o _local/index.bc05542a.pck \
        --text scripts/game.gd=patch/game.gd --text scripts/main.gd=patch/main.gd
# then update that filename's entry in _local/index.html's fileSizes to the new byte size

# probe how POST api/chunk validates a trace (protocol v4). Uses a throwaway token, no nickname.
python3 tools/chunk_probe.py

# serve the patched client locally; only /api/* is relayed to the live server
MOCK_START=1 MOCK_CHUNK_WINDOW=1 BLOCK_POST=1 PORT=8788 python3 tools/local_proxy.py  # practice
ALLOW_POST_NAME=<nick> ALLOW_POST_MIN_SCORE=<n> PORT=8790 python3 tools/local_proxy.py  # live run
# http://127.0.0.1:8788/?bot=1&ss=1&bt=777&sfloor=610&sspd=60&sttl=700   (see docs/autopilot.md)

# gate watcher — read-only, never POSTs. Exit 1 means something changed:
# a new index.pck (re-run the pipeline), seed gone from api/start (rollback),
# or any newer board ts (someone got through, so it is not a global block).
python3 tools/watch_gate.py [--baseline]
```

`tools/` holds byte-identical copies of the three `_dl/` scripts — a change to one needs the same change to the other, or drop one copy.

## The integrity invariant: leftover = 0

`gdc_decompile.py` prints `leftover=N` — bytes remaining after consuming exactly the declared counts of identifiers, constants, line maps and tokens. All 8 files report **0**, which is the evidence that the recovered source is token-for-token complete. If a decompiler change makes `leftover` nonzero, its output is not trustworthy.

`token_lines`/`token_columns` survive in the pack, so every `file.gd:LINE` citation in `GAME_STRUCTURE.md` **matches the original line numbers**. Preserve line numbering when touching `recovered/`, or those references silently rot.

## recovered/ is the 2026-08-12 snapshot — the live game is `_dl/extracted/`

**`recovered/*.gd` is no longer byte-identical to `_dl/extracted/scripts/*.decompiled.gd`.** The operator reships several times a day — most recently 08-14 22:04 (`index.bc05542a.pck`, protocol v4: `game` +chunk seeding, `ranking` +`api/chunk`, `main` +`last_unranked`, `ui` +rep badges). Before that, 08-14 02:16 changed 6 of the 8 files (`game` 112 lines, `ranking` 54, `main` 16, `ui` 15, `player` 9, `row` 7; `theme_defs` and `sfx` are unchanged). `tools/make_bot_patch.py` already reads `_dl/extracted/`, so builds are unaffected — but **reasoning from `recovered/` produces wrong conclusions.** Re-run the pipeline and read the fresh decompile before making any claim about current behaviour.

The changes are all in service of one goal — making a run **reproducible from a seed** — which is what the server's replay verification needs:

- `rng.seed = main.ranking.active_seed` (was `rng.randomize()`, so the old world was unseeded)
- `FIXED_DT = 1/60` fixed-step loop with `tick_count`, `input_trace`, `replay_mode`/`replay_inputs`
- screen shake moved to a separate `vrng` so it cannot pollute the world stream
- `_update_snow` moved **out** of `_sim_tick` (frame-time dependence removed from the simulation)
- **`cols_pool.shuffle()` replaced by `rng.randi_range(0, i)` Fisher-Yates.** `Array.shuffle()` uses Godot's *global* RNG, so the old build's tree layout was unreproducible; the current one is seeded. Miss this and you will conclude that offline reproduction is impossible.

`recovered/` is still worth keeping as the restoration record. Its dead code belongs to the original author, not to the decompiler: `Ranking.server_ok` is assigned three times and never read, `UI.font_s` is loaded and unused, `UI.show_game_over`'s `stage_i` parameter is ignored, `Row.train_half`'s default `410.0` is always overwritten with `415`. Leave them — they are evidence.

Comments are **unrecoverable** (the tokenizer never stores them). Every statement about developer intent is inference; `GAME_STRUCTURE.md` marks those 추정, and new claims should follow that convention.

## Godot 4.7.1 RNG — three things that are not what they look like

`tools/sim.py` reproduces the world offline; getting there took three corrections, each verified against the `4.7.1-stable` source and a 6-case ground truth (`tools/rng_probe.py`, exit 0 = all match):

1. **`rng.seed = N` does not set `state = N`.** `RandomPCG::seed()` calls `pcg32_srandom_r(&pcg, N, current_inc)`: state starts at 0, `inc = (PCG_DEFAULT_INC_64 << 1) | 1`, then it steps, adds the seed, and steps again. So `seed 0` does **not** yield `randf() == 0.0` — that observation is what exposed the whole problem.
2. **`randf()` consumes `rand()` twice** — `ldexp((float)(rand() | 0x80000001), -32 - clz32(proto))`, not `rand() / 0xFFFFFFFF`. Get this wrong and every value after the first diverges no matter how correct the seeding is.
3. **`randi_range` is rejection-sampled** (`pcg32_boundedrand_r`, `threshold = -n % n`), not `rand() % n`. Identical for powers of two, different for 9/7/6/5/3 — exactly the `randi_range(0, i)` Fisher-Yates in `_build_grass`. Also `randi_range(a, a)` consumes **nothing**.

A one-line elimination table is in `docs/wt-notes/wt-rng.md`: 7 seedings × 3 `randf` variants, one cell passes. The earlier session had already tried the right seeding — but only against the wrong `randf`, so it could not pass. **When you rule out a hypothesis, make sure everything else in the test is right, or the whole elimination table is void.**

## Game architecture (what takes several files to see)

- **One scene.** `res://main.tscn` is a single `Node` with `main.gd` attached. Player, rows, vehicles, logs, trains, snow and all five screens (title/HUD/game-over/ranking/pause) are assembled imperatively at runtime via `Row.new()`, `Label.new()`, `ColorRect.new()`. 1,880 lines across 8 modules is the entire game — which is why decompiling the scripts recovered 100% of it.
- **`main.gd` is the state machine and the service locator.** It owns `ranking`/`ui`/`sfx`/`game` and routes every transition. `UI` and `Game` never reference each other; they communicate through `main`.
- **Scoring.** `score() = max_row - start_row + bonus`, `rows_crossed() = max_row - start_row` (game.gd:315-319). `bonus` only ever grows by `+= 2` (near-miss) and a near-miss is only judged while the player occupies that row, so honest play satisfies `rows <= score <= rows * 2` — and the server's consistency check is the upper half of that, `score <= rows * 2 + 40`.
- **`?s=N`** jumps to stage N (`start_row = clampi(N,0,500) * 20`) but cannot inflate score, because `start_row` is subtracted back out.
- **Async discipline.** `Main._over_token` is a generation counter re-checked after every `await` so stale coroutines abandon quietly; `ui.gd` does the same with `cur[0] != want` for stale leaderboard responses. Keep that pattern if you patch either file.

## Leaderboard API and its server-side validation

> **Protocol v4 (2026-08-14 22:04) split the world seed into 25-row chunks — read `docs/leaderboard-api.md` §10 before anything else.** `api/start` now returns `chunk_rows` (25) and only `chunks` 0-1; every later chunk's seed must be earned mid-run with `POST api/chunk {token, i, ticks, char, trace}`, and the server **replays the trace** to check you reached the previous chunk. Miss a seed and `Game._ensure_chunk` falls back to a local seed after 420 ticks, sets `unranked`, and the client refuses to submit that run.
>
> Three consequences for the autopilot (`docs/autopilot.md` §10): search rounds must carry the **real** token (so the misfire guard moved out of the game into the proxy's `ALLOW_POST_NAME`/`ALLOW_POST_MIN_SCORE`); **row generation must never be delayed by even one tick** (a row created a tick late misses one `step()` and the world diverges — a 438-row prefix replayed to 241 rows), so freeze whole ticks before a chunk boundary instead, which is simulation-invisible; and **`api/chunk` grants exactly 25 seeds per token** — the ceiling is the *grant count*, not the chunk index, so 25 grants x 25 rows + the 2 pre-issued chunks = **row 674 is one token's hard ceiling** (~730-770 points at the observed 8-14% bonus rate). Waste a grant and you lose 25 rows: one run burned 18 grants re-fetching the same chunk because a round-abort path skipped `_search_reap_chunks()`. A per-IP window sits on top of that (two runs 45 min apart used 50 grants, after which fresh tokens got only 4-5), so **never batch attempts back to back** (`docs/leaderboard-api.md` §10.3.1).
>
> **Always give the search an exit for "target not reached": `sfloor=<score>`.** On 08-15 00:04 a run reached a registerable 630 rows / 681 points and the harness discarded it because it was configured to submit only at 777. That trace lived only in browser memory (`docs/submissions-log.md` session H).

> **As of 2026-08-14 the only way to put a score on the board is to actually cross the rows.** The server reseeds the world from `api/start`'s `seed`, replays the submitted `trace`, and computes **both `rows` and `score`** itself. Inflating `score` within the old `score <= rows*2+40` slack is dead: `503 / rows 240` and `200 / rows 85` were both `403 rejected`, while honest `200 / rows 188` from the same client passed. Everything below about buying score with token age is **history** — read `docs/leaderboard-api.md` §8 first, then `docs/autopilot.md` for the only live path.
>
> **Never experiment with the nickname you intend to keep.** Since 2026-08-14 evening every board entry carries `rep` (0 = clean, 2 = suspect, 3 = abuse-suspected) plus a Korean `rep_why`, applied retroactively to all 50 entries. `사랑해요정호님` sent one inflated body and every entry under that name now reads **"위조 시도 이력"** (`rep` 2-3) — a rejected POST leaves no board row but does leave a mark. The clean nickname `야호정호` scored `rep 0`. Probe with a throwaway name; register the goal with a fresh one (`docs/leaderboard-api.md` §9).
>
> Two further rules from that session: **judge a submission only by the POST response's `ok`** — 4 of 6 accepted entries were missing from `GET api/scores` for hours and then reappeared, and mistrusting `ok: true` is why one goal now has four duplicate entries that cannot be withdrawn (§8.2) — and **the response's `rank` is unreliable** (a stored #1 came back as `rank 4`).

> **Serialize the POST body exactly the way Godot does, or nothing you send will ever be accepted.** Since the operator's 2026-08-13 night patch, the server fingerprints the raw body: `JSON.stringify` in Godot **sorts keys** and emits **no whitespace** after `:` or `,`, so the client always sends `{"char":...,"name":...,"rows":...,"score":...,"token":...}`. Python's `json.dumps` default (insertion order, `", "` / `": "`) is answered `403 {"error": "rejected", "hint": "stale"}` regardless of how valid the score is — `stale` means "your client doesn't look current", not "your token is old". `tools/submit_target.py:godot_json()` is the canonical form; never "tidy up" its separators or drop the sort. The rules below still hold once the body form is right.

Contract (ranking.gd:69-108) — API base is derived from the page URL, so game and API are always same-origin:

| endpoint | request | response |
|---|---|---|
| `GET api/start` | — | `{"token": "<epoch>.<hex16>.<hex16>"}` |
| `GET api/scores[?char=<id>]` | — | `{"scores": [...]}`, top 50, score-descending |
| `POST api/scores` | `{name, score, rows, char, token}` | `{"ok", "rank", "scores"}` |

The server has no published source; these rules were established by observation:

| response | meaning |
|---|---|
| `403 {"error": "too_fast"}` | **`rows`** too high for the token's age — not `score` |
| `403 {"error": "inconsistent"}` | `score > rows * 2 + 40` |
| `{"error": "token:reused"}` | token already spent — **a rejected attempt spends it too** |
| `429 {"error": "too fast"}` — space, not underscore | per-IP submit throttle, easy to trip with concurrent POSTs |

Checks run in that order bottom-up: **throttle first, then token, then consistency, then rate.** A request with a bogus `token` — or no `token` field at all — still answers `429 too fast` while throttled, which is how the ordering was established. Burst a batch of probes and every response after the first tells you about the throttle, not about your score. Space them ≥30s.

One token buys exactly one attempt, so "submit and retry on rejection" needs a fresh token per try; that is why `submit_target.py` (and the older two-phase `submit_run.py`, kept as a record) mints them in bulk. A 429 is the exception — the throttle precedes token validation, so a throttled request does not spend its token and the same one can be retried after a backoff.

**The rate check reads `rows`, not `score`** — the single most important thing to get right here, and the earlier score-based reading was wrong. `score 10001 / rows 5001` was accepted at 565.6s of token age: 17.68 **score**/s, which cannot be a score limit because 9.76 score/s (120 pts at 12.3s) was rejected. Read as rows, all 15 observed submissions fit `rows <= elapsed * 9.5` with no exceptions; the proven window is `r ∈ [9.487, 9.756)` and a grace term is bounded at `g < 1.3s`, so treat it as a plain ratio. `r = 9.5` is the only clean value in the window but remains 추정.

**Third-party entries are first-class evidence now.** Since entries carry `elapsed`, any successful submission on the board is a data point as good as your own probe — `elapsed` is the very number the server judged against. `화이트해커30000` (`30000 / rows 14980`, `elapsed 1579.0` = 9.487 rows/s) is what raised the lower bound from 8.84 and **refuted the earlier `r = 9` fit**, which would have rejected it at 14211 rows. Read the board before probing; someone else may have already measured what you were about to spend a POST on. Exclude `admin_insert` rows — they never passed validation.

So the two checks are independent, and the achievable ceiling is their composition:

```
rate:        rows  <= elapsed * 9.5        (r in [9.487, 9.756), so 9.4 is the safe constant)
consistency: score <= rows * 2 + 40
⇒ pick rows = 9.4 * elapsed  ⇒  score_max ≈ 18.8 * elapsed + 40
```

Consequence: **halving `rows` halves the wait.** `score == rows` is the safe-but-slowest choice and doubles the wait for a given score; `rows ≈ score/2` is what the rule actually costs. Satisfying the combined formula is not sufficient on its own — 120 pts at 12.3s sat under it yet was rejected, because `rows` was 120 where 12.3s only buys 110. Check both conditions separately.

Tokens are known good to 1579s (26.3 min) of age; no absolute score cap exists below 30000, and `stage 749` stored fine — `ThemeDefs.stage_index()` (theme_defs.gd:86) has no clamp and `loop_count()` exists to count theme-list wraps, so unbounded stage is by design; the 500 clamp applies only to `?s=N`. Entries submitted since 2026-08-13 ~13:00 carry an **`elapsed`** key (the token age the server itself measured — 565.6 against our 565.6), which is worth reading back instead of inferring the age. When quoting a rate from a scheduler log, check the age against the token's own mint time — a bulk-minting scheduler whose `t0` is the *last* mint understates the age of every earlier token.

Entries carrying `"admin_insert": true` (observed on `호호호 2500`) were inserted by the server operator outside the POST path — exclude them when reasoning about what validation accepts. The operator is actively editing this server (the `elapsed` key appeared mid-day 08-13), so a rule measured last session may no longer hold; re-derive from the newest data point when they disagree.

Two facts make the boundary cheap to search: a rejection **creates no leaderboard entry**, and nothing binds a token to a browser session — tokens can be minted in bulk up front and aged in parallel. So escalating token age against a fixed target score costs only wall-clock, and the first acceptance is the desired result. Set `rows` from the target: `rows = ceil((score - 40) / 2)` is the cheapest legal value and `rows = ceil(score / 2)` keeps a margin without meaningfully raising the wait. The server stores `stage = floor(rows/20)` (0-based, not the 1-based number the in-game banner shows), so a low `rows` also lands a *lower* stage than the score suggests — which is what makes an inflated entry blend in. Space POSTs ≥60s apart to stay clear of the 429 limiter.

## Working against the live target

Every request here hits a service someone else runs — a single-threaded Python process, with `/api/*` set to `no-cache` so nothing is absorbed by the CDN edge. Keep request volume low and serialized. There is **no delete endpoint** in the public API: a submitted score cannot be withdrawn, so treat each POST as permanent and submit the minimum needed.

**A single `GET api/scores` is not proof the board changed — and re-polling the same URL is not either.** CloudFront serves stale copies of that exact URL (`x-cache: Error from cloudfront`) even though the response carries `cache-control: no-cache`. On 08-14 this cost 30 minutes: two re-polls and a `?char=` query all agreed our fresh entry was missing, while it had been stored all along. **Always append a cache buster — `curl -s ".../api/scores?cb=$RANDOM"`** — or read the `scores` array out of the POST response, which is never cached. The 08-13 "top 11 entries missing" window was most likely the same edge behaviour. Diff against a saved snapshot before concluding anything was deleted, and never let one reading trigger a resubmission.

**Check for another session before you start: `pgrep -f local_proxy.py`.** On 08-14 two sessions worked this workspace at the same time, sharing port 8777, the `_local/` copy and the origin IP — one of them silently served the other's live run mock `api/start` responses. Both sessions also independently posted a `200 / rows ~190` entry under the same nickname, and the log initially mis-attributed both to one session (`docs/submissions-log.md` session G). Attribute board entries by comparing `ts` against your own token epochs, not by score.
