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

# (파일, 이 줄 '앞'에 끼울 것 / 뒤에 끼울 것) — 앵커는 정확히 1회만 나타나야 한다
INSERTS = {
    "game": [
        ("after", "\t_apply_stage_visuals(stage_idx, true)\n", "\t_bot_setup()\n"),
        ("before", "\t_consume_input()\n", "\t_bot_decide()\n"),
        ("after", "\tmain.on_game_over(score(), rows_crossed(), stage_idx, cause)\n",
         "\t_bot_after_death()\n"),
    ],
    "main": [
        ("after_first", "\tranking.start_run()\n", "\t_bot_autostart()\n"),
        ("after", "\tui.show_game_over(score, rows, int(ranking.data[\"best\"]), is_new_best, cause, stage_idx)\n",
         "\t_bot_after_over(cause)\n"),
    ],
}


def apply(name: str) -> None:
    src = open(os.path.join(SRC, f"{name}.decompiled.gd"), encoding="utf-8").read()
    part = open(os.path.join(OUT, f"bot_{name}.part.gd"), encoding="utf-8").read()
    lines = src.splitlines(keepends=True)

    for mode, anchor, ins in INSERTS[name]:
        hits = [i for i, ln in enumerate(lines) if ln == anchor]
        if not hits or (mode != "after_first" and len(hits) != 1):
            sys.exit(f"{name}: 앵커 {anchor!r} 가 {len(hits)}회 — 1회여야 한다")
        i = hits[0]
        lines.insert(i if mode == "before" else i + 1, ins)

    out = "".join(lines) + part
    dest = os.path.join(OUT, f"{name}.gd")
    open(dest, "w", encoding="utf-8").write(out)
    orig_n = len(src.splitlines())
    print(f"  patch/{name}.gd  원본 {orig_n}줄 + 삽입 {len(INSERTS[name])}줄 "
          f"+ 봇 {len(part.splitlines())}줄 = {len(out.splitlines())}줄")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for n in ("game", "main"):
        apply(n)
