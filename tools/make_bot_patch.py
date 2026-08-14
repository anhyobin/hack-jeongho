#!/usr/bin/env python3
"""디컴파일 원본에 자동 조종을 심어 `patch/game.gd` / `patch/main.gd`를 만든다.

손으로 옮겨 적지 않고 **디컴파일 결과를 그대로 읽어** 정해진 한 줄씩만 끼워 넣는다.
원본 라인이 한 줄도 바뀌지 않는다는 것이 이 스크립트의 존재 이유다 —
서버가 시드로 trace를 재현하므로 시뮬레이션 코드가 달라지면 제출이 거부된다.

    python3 tools/make_bot_patch.py
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "_dl", "extracted", "scripts")
OUT = os.path.join(ROOT, "patch")

# (파일, 이 줄 '앞'/'뒤'에 끼울 것, 또는 이 줄을 치환) — 앵커는 정확히 1회만 나타나야 한다
INSERTS = {
    "game": [
        ("after", "\t_apply_stage_visuals(stage_idx, true)\n", "\t_bot_setup()\n"),
        ("before", "\t_consume_input()\n", "\t_bot_decide()\n"),
        ("after", "\tmain.on_game_over(score(), rows_crossed(), stage_idx, cause)\n",
         "\t_bot_after_death()\n"),
        # 프레임당 틱 상한을 main이 정하게 바꾼다. 원본 상한(8틱)이면 12,000틱 접두사
        # 재생에 200초가 걸려 체크포인트 탐색이 성립하지 않는다(`bot_search.part.gd`).
        # **시뮬레이션 의미는 바뀌지 않는다** — 같은 FIXED_DT, 같은 순서, 같은 rng 소모.
        # `bot_tick_ok`가 조건의 맨 앞에 오는 것이 중요하다: 사망 틱(state != "play")
        # 직후에도 한 번 더 불려서 하네스가 그 자리에서 다음 주행을 띄울 수 있다.
        ("replace",
         "\twhile _sim_acc >= FIXED_DT and state == \"play\" and guard < MAX_TICKS_PER_FRAME:\n",
         "\twhile main != null and main.bot_tick_ok(self, guard)"
         " and _sim_acc >= FIXED_DT and state == \"play\":\n"),
    ],
    "main": [
        ("after_first", "\tranking.start_run()\n", "\t_bot_autostart()\n"),
        ("after", "\tui.show_game_over(score, rows, int(ranking.data[\"best\"]), is_new_best, cause, stage_idx)\n",
         "\t_bot_after_over(cause)\n"),
    ],
}

# 원본 뒤에 이어 붙이는 패치 조각들 (순서대로)
PARTS = {
    "game": ["bot_game.part.gd"],
    "main": ["bot_main.part.gd", "bot_search.part.gd"],
}


def apply(name: str) -> None:
    src = open(os.path.join(SRC, f"{name}.decompiled.gd"), encoding="utf-8").read()
    part = "".join(open(os.path.join(OUT, p), encoding="utf-8").read()
                   for p in PARTS[name])
    lines = src.splitlines(keepends=True)

    n_ins = 0
    for mode, anchor, ins in INSERTS[name]:
        hits = [i for i, ln in enumerate(lines) if ln == anchor]
        if not hits or (mode != "after_first" and len(hits) != 1):
            sys.exit(f"{name}: 앵커 {anchor!r} 가 {len(hits)}회 — 1회여야 한다")
        i = hits[0]
        if mode == "replace":
            lines[i] = ins
        else:
            lines.insert(i if mode == "before" else i + 1, ins)
            n_ins += 1

    out = "".join(lines) + part
    dest = os.path.join(OUT, f"{name}.gd")
    open(dest, "w", encoding="utf-8").write(out)
    orig_n = len(src.splitlines())
    print(f"  patch/{name}.gd  원본 {orig_n}줄 + 삽입 {n_ins}줄 "
          f"+ 봇 {len(part.splitlines())}줄 = {len(out.splitlines())}줄 "
          f"({'+'.join(PARTS[name])})")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for n in ("game", "main"):
        apply(n)
