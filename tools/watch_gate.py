#!/usr/bin/env python3
"""제출 관문이 다시 열리는 순간을 잡기 위한 감시자 (읽기 전용).

2026-08-14 새벽 현재 `POST api/scores`는 어떤 요청도 받지 않는다
(`403 rejected / hint: stale`). 원인은 서버가 `api/start`에서 `seed`를 발급하기
시작했는데 배포된 클라이언트가 그것을 되돌려줄 코드를 갖고 있지 않다는 것이다 —
자세한 근거는 `docs/leaderboard-api.md` §6.

따라서 다시 등록이 가능해지는 신호는 셋 중 하나다.

1. **새 클라이언트 배포** — `index.pck`의 크기/`last-modified`가 바뀐다.
   그때 다시 내려받아 디컴파일하면 새 프로토콜을 소스에서 그대로 읽을 수 있다.
2. **서버 롤백** — `api/start` 응답에서 `seed`가 사라진다.
3. **남이 등록에 성공** — 보드에 22:35:06(마지막 항목)보다 새로운 `ts`가 생긴다.
   누구든 통과했다면 전역 차단이 아니라는 뜻이므로 즉시 재시도 가치가 있다.

**이 스크립트는 POST를 절대 보내지 않는다.** 남의 단일 스레드 서버가 대상이므로
요청은 실행당 3건(HEAD 1 + GET 2)으로 묶었고, 30분 간격 이상으로 돌릴 것을 전제한다.

사용법:
    python3 tools/watch_gate.py            # 1회 점검, 변화가 있으면 종료코드 1
    python3 tools/watch_gate.py --baseline # 현재 상태를 기준선으로 저장
상태 파일: tools/.gate_baseline.json
"""
import json, os, sys, time, urllib.request, urllib.error

BASE = "https://d15csla760jzen.cloudfront.net/"
STATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".gate_baseline.json")


def head(path):
    req = urllib.request.Request(BASE + path, method="HEAD")
    with urllib.request.urlopen(req, timeout=15) as r:
        return {"length": r.headers.get("content-length"),
                "modified": r.headers.get("last-modified")}


def get_json(path):
    try:
        with urllib.request.urlopen(BASE + path, timeout=15) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode())
        except Exception:
            return {"_http": e.code}


def snapshot():
    pck = head("index.pck")
    start = get_json("api/start")
    board = get_json("api/scores")
    raw = board.get("scores") if isinstance(board, dict) else None
    scores = [e for e in raw if isinstance(e, dict)] if isinstance(raw, list) else []
    newest = max((e.get("ts") or 0) for e in scores) if scores else 0
    return {
        "pck_length": pck["length"],
        "pck_modified": pck["modified"],
        "start_has_seed": "seed" in start,
        "start_keys": sorted(start.keys()),
        "board_newest_ts": newest,
        "board_top": scores[0].get("score") if scores else None,
        "checked_at": int(time.time()),
    }


def main():
    snap = snapshot()
    ts = time.strftime("%m-%d %H:%M:%S", time.localtime(snap["checked_at"]))

    if "--baseline" in sys.argv or not os.path.exists(STATE):
        with open(STATE, "w") as f:
            json.dump(snap, f, indent=2)
        print(f"[{ts}] 기준선 저장: pck {snap['pck_length']}B / "
              f"{snap['pck_modified']} | start keys {snap['start_keys']} | "
              f"보드 최신 ts {snap['board_newest_ts']} | 최고 {snap['board_top']}")
        return 0

    with open(STATE) as f:
        base = json.load(f)

    changes = []
    if snap["pck_length"] != base["pck_length"] or \
       snap["pck_modified"] != base["pck_modified"]:
        changes.append(
            f"**새 클라이언트 배포** index.pck {base['pck_length']}B/"
            f"{base['pck_modified']} -> {snap['pck_length']}B/{snap['pck_modified']} "
            f"— 즉시 재다운로드 후 gdc_decompile.py로 ranking.gd 확인")
    if snap["start_has_seed"] != base["start_has_seed"]:
        changes.append(
            f"**api/start 응답 변화** keys {base['start_keys']} -> {snap['start_keys']}"
            f" — seed 제거는 롤백 신호")
    if snap["board_newest_ts"] > base["board_newest_ts"]:
        when = time.strftime("%m-%d %H:%M:%S",
                             time.localtime(snap["board_newest_ts"]))
        changes.append(
            f"**누군가 등록에 성공** 보드 최신 ts {when} "
            f"(기준선보다 새로움) — 전역 차단이 아니므로 즉시 재시도")

    if not changes:
        frozen = int(snap["checked_at"] - snap["board_newest_ts"]) // 60
        print(f"[{ts}] 변화 없음 — 관문 여전히 닫힘 "
              f"(보드 정지 {frozen}분, 최고 {snap['board_top']})")
        return 0

    print(f"[{ts}] === 변화 감지 {len(changes)}건 ===")
    for c in changes:
        print(f"  - {c}")
    with open(STATE, "w") as f:
        json.dump(snap, f, indent=2)
    return 1


if __name__ == "__main__":
    sys.exit(main())
