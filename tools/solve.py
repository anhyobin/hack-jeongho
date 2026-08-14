#!/usr/bin/env python3
"""오프라인 백트래킹 탐색 — 주행하지 않고 **계산으로** 안전 경로를 만든다.

`tools/sim.py`의 재현이 실제 클라이언트와 틱 단위로 일치하므로(`sim.py`를
정답지에 돌려 확인한다), 월드는 시드만의 함수다. 그러면 경로 찾기는 확률이
아니라 탐색이다 — 죽으면 마지막 체크포인트로 되감아 **다른 분기**를 시도한다.

핵심 설계 두 가지:

1. **판정은 시뮬레이터 자신에게 맡긴다.** 후보 행동마다 상태를 복제해 실제로
   굴려 보고 살아남는지 본다. 별도의 위험 예측식을 쓰지 않으므로 예측식과
   본 시뮬레이션이 어긋날 여지가 없다.
2. **확장 단위는 행이다.** `k틱 대기 후 이동`(k는 0~254틱, 6틱 격자)을 한 번에 다
   펼친다. 대기를 확장 **안**에 넣지 않으면 빔이 "같은 자리에서 2~3틱씩 다르게
   기다린 상태"로 가득 차 다양성이 붕괴한다(`expand_row` 주석 참고).

두 시드에서 600점을 합성해 검증했고, 그중 하나는 **엔진이 직접 채점해** 600점을
확인했다 (`docs/wt-notes/wt-rng.md` §8·§8.1).

    python3 tools/solve.py <시드> [--target 600] [--width 8] [--out 경로.json]
    python3 tools/solve.py 1000000919842726 --target 600 --out /tmp/t.json

찾으면 `{"seed","score","rows","ticks","trace"}`를 stdout(과 --out)에 낸다.
그 `trace`/`ticks`가 그대로 제출값이다 — 다만 **제출 전에 엔진으로 한 번 확인해라**
(§8.1의 `brep` 훅). 서버는 자기 재현으로 rows·score를 다시 계산한다.
"""
import argparse
import copy
import json
import sys
import time

import sim

# 방향 코드는 game.gd의 DIRS와 같은 순서다 (0 전진, 1 후진, 2 좌, 3 우)
FWD = (0, 1)
BACK = (0, -1)
LEFT = (-1, 0)
RIGHT = (1, 0)

# 대기 후보. 홉 하나가 9틱이므로 그보다 잘게 쪼갤 이유가 없고, 스크롤 사망까지의
# 여유(약 15초 = 900틱)를 다 쓰기 전에 여러 번 재시도할 수 있게 계단으로 둔다.
WAITS = (3, 6, 10, 16, 24, 40, 70, 120)


def alive(g: sim.Game) -> bool:
    return g.state == "play"


def advance(g: sim.Game, n: int) -> None:
    for _ in range(n):
        if not alive(g):
            return
        g.sim_tick()


def do_move(g: sim.Game, d: tuple) -> bool:
    """try_move 후 착지까지 굴린다. 실제로 움직였으면 True.

    ★ 막힌 곳으로의 이동은 `player.bump()`뿐이고 **시계만 1틱 흐른다.** 그건
    `("wait", 1)`과 같으므로 후보로 두면 안 된다. 두면 "가장 싼 행동"이 되어
    빔·DFS가 영원히 제자리에서 부딪친다 — 8행의 4·5열이 막힌 국면에서 4열에
    선 채로 전진만 반복하는 실측 정체가 정확히 이것이었다.
    """
    before_row = g.player.row
    before_x = g.player.x
    g.try_move(d)
    g.sim_tick()                     # 이 틱에서 _consume_input이 입력을 먹는다
    if not alive(g):
        return True                  # 죽었으면 어차피 버려진다
    if g.player.row == before_row and g.player.x == before_x and not g.player.hopping:
        return False                 # bump — 상태가 안 바뀌었다
    advance(g, sim.HOP_TICKS)         # 착지 (hop_end_tick = 적용틱 + 8)
    return True


def apply_action(g: sim.Game, act: tuple) -> bool:
    if act[0] == "wait":
        advance(g, act[1])
        return True
    return do_move(g, act[1])


def cam_slack(g: sim.Game) -> float:
    """스크롤 사망까지 남은 행 수. `568 + (cam_row - row) * 64 > 1000`이 사망이다."""
    return 6.75 - (g.cam_row - g.player.row)


def candidates(g: sim.Game) -> list:
    """이 지점에서 시도해 볼 행동을 좋아 보이는 순서로 낸다."""
    acts: list = [("move", FWD)]
    # 전진이 막혀 있거나 위험할 때 옆으로 비키는 것이 자주 유일한 답이다
    acts.append(("move", LEFT))
    acts.append(("move", RIGHT))
    for k in WAITS:
        acts.append(("wait", k))
    # 후퇴는 스크롤 여유를 깎으므로 마지막이다. 여유가 없으면 아예 두지 않는다
    if cam_slack(g) > 4.0:
        acts.append(("move", BACK))
    return acts


def rollout(g: sim.Game, depth: int) -> tuple:
    """무입력이 아니라 **탐욕 전진**으로 depth홉 굴려 본 결과를 점수화한다.

    반환값이 클수록 좋다: (살아남은 홉 수, 도달 행, 스크롤 여유).
    """
    gg = g
    hops = 0
    for _ in range(depth):
        if not alive(gg):
            break
        moved = False
        for act in (("move", FWD), ("move", LEFT), ("move", RIGHT)):
            trial = copy.deepcopy(gg)
            apply_action(trial, act)
            if alive(trial) and trial.player.row >= gg.player.row:
                gg = trial
                moved = True
                hops += 1
                break
        if not moved:
            trial = copy.deepcopy(gg)
            advance(trial, 10)
            if not alive(trial):
                break
            gg = trial
    return (hops, gg.max_row, cam_slack(gg) if alive(gg) else -99.0)


def try_action(g: sim.Game, act: tuple):
    """행동을 적용한 결과 상태. 죽거나 스크롤 여유가 없으면 None."""
    nxt = copy.deepcopy(g)
    if not apply_action(nxt, act):
        return None                  # bump — 후보가 아니다
    if not alive(nxt) or cam_slack(nxt) <= 0.0:
        return None
    return nxt


def score_action(g: sim.Game, act: tuple, depth: int):
    """행동을 실제로 적용해 보고 (평가값, 결과상태)를 낸다."""
    nxt = try_action(g, act)
    if nxt is None:
        return None
    r = rollout(copy.deepcopy(nxt), depth)
    # 전진을 강하게 선호하되, 앞이 막힌 국면에서는 미래(rollout)가 결정한다
    value = (r[0] * 1000 + r[1] * 10 + min(r[2], 6.0)
             + (5 if act[0] == "move" and act[1] == FWD else 0))
    return (value, nxt)


# 행 단위 확장에서 쓰는 대기 격자. 차량이 가장 빠를 때(약 350px/s)도 6틱은 35px이라
# 히트박스(약 74px)보다 촘촘하고, 254틱(4.2초)이면 어떤 차선의 간격도 한 번은 비운다.
WAIT_GRID = tuple(range(0, 260, 6))


def expand_row(g: sim.Game) -> list:
    """`k틱 대기 후 이동` 조합을 전부 낸다 — 한 번의 확장이 타이밍 공간을 다 덮는다.

    ★ 행동 하나씩 확장하는 빔은 **다양성이 붕괴한다.** 24칸이 전부 "같은 자리에서
    2~3틱씩 다르게 기다린 상태"로 채워져 시간이 한 단계에 2틱씩만 흐르고, 차량
    간격을 기다려 낼 만큼 앞을 못 본다(실측: 시드 1000000919874402에서 7행에
    영구 정체). 대기를 **확장 안으로** 넣으면 그 함정이 사라진다.

    대기는 상태를 하나만 두고 증분으로 진행하므로 격자 전체가 254틱어치 비용이다.
    """
    out = []
    cur = copy.deepcopy(g)
    prev = 0
    for k in WAIT_GRID:
        if k > prev:
            advance(cur, k - prev)
            prev = k
            if not alive(cur) or cam_slack(cur) <= 0.0:
                break          # 더 기다리면 스크롤에 죽는다
        for d in (FWD, LEFT, RIGHT):
            s = copy.deepcopy(cur)
            if not do_move(s, d):
                continue             # bump — wait와 같으므로 후보가 아니다
            if alive(s) and cam_slack(s) > 0.0:
                out.append(s)
    return out


def state_key(g: sim.Game) -> tuple:
    """완전히 같은 국면을 걸러내기 위한 열쇠. wait 3+3과 wait 6은 같은 상태가 된다."""
    return (g.tick_count, g.player.row, round(g.player.x, 3),
            round(g.cam_row, 6), g.max_row, g.bonus,
            g.player.riding is not None)


def solve_beam(seed: int, target: int, width: int, start_row: int = 0,
               time_limit: float = 0.0, verbose: bool = True) -> dict:
    """빔 탐색 — 체크포인트를 **동시에 여러 개** 살려 둔다.

    깊이 우선 되감기(`solve_dfs`)는 막힌 행에서 프런티어의 12^k 부분나무를 다
    뒤지느라 위로 올라가지 못한다(실측: 359행에서 6분 넘게 정체). 빔은 매 단계
    상위 `width`개를 남기므로 죽은 갈래가 자연히 도태되고 정체가 없다.
    """
    root = sim.Game(seed, start_row)
    beam = [root]
    best = root
    t0 = time.time()
    steps = 0
    expansions = 0
    last_report = 0.0

    while beam:
        if best.score() >= target:
            break
        if time_limit and time.time() - t0 > time_limit:
            break
        nxt = []
        for g in beam:
            kids = expand_row(g)
            expansions += len(kids)
            nxt.extend(kids)
        if not nxt:
            break                      # 빔 전멸 — 이 시드에서 더 갈 길이 없다
        # 전진을 최우선으로, 그다음 점수·스크롤 여유. 같은 국면은 하나만 남긴다.
        nxt.sort(key=lambda s: (-s.max_row, -s.score(), -cam_slack(s), s.tick_count))
        beam, seen = [], set()
        for s in nxt:
            k = state_key(s)
            if k in seen:
                continue
            seen.add(k)
            beam.append(s)
            if len(beam) >= width:
                break
        cur = max(beam, key=lambda s: s.score())
        if cur.score() > best.score():
            best = cur
        steps += 1
        if verbose and time.time() - last_report > 3.0:
            last_report = time.time()
            print(f"  단계 {steps:5d}  최고행 {best.max_row:4d}  점수 {best.score():4d}  "
                  f"틱 {best.tick_count:6d}  빔 {len(beam):3d}  확장 {expansions:8d}  "
                  f"{time.time() - t0:5.1f}s", file=sys.stderr)

    g = best
    return {"seed": seed, "score": g.score(), "rows": g.rows_crossed(),
            "ticks": g.tick_count, "trace": g.input_trace, "bonus": g.bonus,
            "cause": g.cause, "nodes": expansions, "best_row": g.max_row,
            "secs": round(time.time() - t0, 1), "steps": steps,
            "reached": g.score() >= target}


def solve_dfs(seed: int, target: int, depth: int, max_nodes: int,
              start_row: int = 0, verbose: bool = True) -> dict:
    g = sim.Game(seed, start_row)
    # 체크포인트 스택: (상태, 남은 후보 행동, 그 지점의 max_row)
    stack = []
    nodes = 0
    t0 = time.time()
    best_row = 0
    last_report = 0.0

    while True:
        if not alive(g) or nodes >= max_nodes:
            # 되감기
            while stack and not stack[-1][1]:
                stack.pop()
            if not stack or nodes >= max_nodes:
                break
            g_ck, alts, _ = stack[-1]
            act = alts.pop(0)
            g = copy.deepcopy(g_ck)
            apply_action(g, act)
            nodes += 1
            continue

        if g.score() >= target:
            break

        acts = candidates(g)

        # ★ 흔한 국면(앞이 비어 있다)에서 후보 12개를 전부 굴리면 결정 하나에
        # deepcopy가 150번 넘게 든다. 전진이 되고 그 다음 홉도 되면 더 볼 것이
        # 없으므로 즉시 확정하고, 나머지 후보는 **평가하지 않은 채** 되감기용으로만
        # 남긴다. 막힌 국면에서만 전체 평가로 내려간다.
        fast = try_action(g, acts[0])
        nodes += 1
        if fast is not None and rollout(copy.deepcopy(fast), 1)[0] >= 1:
            chosen, rest = fast, acts[1:]
        else:
            scored = []
            for act in acts:
                s = score_action(g, act, depth)
                nodes += 1
                if s is not None:
                    scored.append((s[0], act, s[1]))
            scored.sort(key=lambda t: -t[0])
            if not scored:
                # 살 길이 없다 → 되감기
                g.state = "dead"
                g.cause = g.cause or "search:dead-end"
                continue
            chosen, rest = scored[0][2], [a for _, a, _ in scored[1:]]

        # 최선을 택하고 나머지는 되감기용으로 남긴다
        stack.append((copy.deepcopy(g), rest, g.max_row))
        if len(stack) > 400:
            stack.pop(0)              # 스택이 무한히 자라지 않게 오래된 것부터 버린다
        g = chosen

        if g.max_row > best_row:
            best_row = g.max_row
        if verbose and time.time() - last_report > 3.0:
            last_report = time.time()
            print(f"  행 {g.player.row:4d}  최고 {best_row:4d}  점수 {g.score():4d}  "
                  f"틱 {g.tick_count:6d}  노드 {nodes:7d}  스택 {len(stack):3d}  "
                  f"{time.time() - t0:5.1f}s", file=sys.stderr)

    return {"seed": seed, "score": g.score(), "rows": g.rows_crossed(),
            "ticks": g.tick_count, "trace": g.input_trace,
            "bonus": g.bonus, "cause": g.cause, "nodes": nodes,
            "best_row": best_row, "secs": round(time.time() - t0, 1),
            "reached": g.score() >= target}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("seed", type=int)
    ap.add_argument("--target", type=int, default=600)
    ap.add_argument("--mode", choices=("beam", "dfs"), default="beam")
    ap.add_argument("--width", type=int, default=8, help="빔 너비 (8로 두 시드 검증)")
    ap.add_argument("--time-limit", type=float, default=0.0, help="초, 0이면 무제한")
    ap.add_argument("--depth", type=int, default=3, help="dfs의 rollout 홉 수")
    ap.add_argument("--max-nodes", type=int, default=2_000_000)
    ap.add_argument("--start-row", type=int, default=0)
    ap.add_argument("--out", default="")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    if a.mode == "beam":
        res = solve_beam(a.seed, a.target, a.width, a.start_row, a.time_limit,
                         verbose=not a.quiet)
    else:
        res = solve_dfs(a.seed, a.target, a.depth, a.max_nodes, a.start_row,
                        verbose=not a.quiet)

    # 스스로 검산한다 — 만든 trace를 replay()에 다시 먹여 같은 값이 나와야 한다
    chk = sim.replay(a.seed, res["trace"], res["ticks"], a.start_row)
    res["verify"] = {"rows": chk["rows"], "score": chk["score"],
                     "ticks": chk["ticks"], "consumed": chk["consumed"],
                     "ok": (chk["rows"] == res["rows"] and chk["score"] == res["score"]
                            and chk["consumed"] == len(res["trace"]))}

    print(json.dumps({k: v for k, v in res.items() if k != "trace"},
                     ensure_ascii=False, indent=2))
    print(f"trace {len(res['trace'])}개 (첫 5: {res['trace'][:5]})")
    if a.out:
        with open(a.out, "w", encoding="utf-8") as fh:
            json.dump(res, fh, ensure_ascii=False)
        print(f"-> {a.out}")
    sys.exit(0 if res["reached"] and res["verify"]["ok"] else 1)


if __name__ == "__main__":
    main()
