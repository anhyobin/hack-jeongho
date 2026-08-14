#!/usr/bin/env python3
"""`POST api/chunk`(프로토콜 v4)가 trace를 어떻게 보는지 재는 프로브.

08-14 22:04 배포로 월드 시드가 25행 단위 청크로 쪼개졌다. `api/start`는 청크 0·1만
주고, 그 뒤 시드는 플레이 중에 `POST api/chunk {token, i, ticks, char, trace}`로
받아온다(`ranking.gd:32-46`).

여기서 재려는 것은 하나다 — **서버가 trace를 검증하는가.** 체크포인트 탐색은 죽은
지점을 되감아 접두사를 갈아치우므로, 최종 trace가 청크 요청 때 보낸 trace의 연장이
아니다. 서버가 그 연속성을 요구하면 §8의 방법은 v4에서 성립하지 않는다.

**닉네임을 쓰지 않으므로 rep 낙인 위험이 없다.** 대신 토큰은 버릴 것을 쓴다.

    python3 tools/chunk_probe.py
"""
import json
import sys
import time
import urllib.error
import urllib.request

BASE = "https://d15csla760jzen.cloudfront.net/"


def godot_json(payload):
    """Godot의 `JSON.stringify`와 동일한 형태 — 키 정렬 + 공백 없음.

    서버가 바디 형태를 지문으로 검사한다(`docs/leaderboard-api.md` §6).
    """
    return json.dumps(payload, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False)


def req(path, method="GET", body=None):
    data = body.encode("utf-8") if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method)
    if data is not None:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def trace_to_row(n, first=91, gap=12):
    """전진 홉 n개로 n행에 닿는 trace. 간격 8틱이 엔진 최소값이므로 12는 여유가 있다."""
    return [[first + gap * i, 0] for i in range(n)]


def ask(token, i, trace, ticks, label):
    body = godot_json({"token": token, "i": i, "ticks": ticks,
                       "char": "peccy", "trace": trace})
    code, txt = req("api/chunk", "POST", body)
    print(f"  [{label}] i={i} trace={len(trace)}건 ticks={ticks} "
          f"-> {code} {txt[:200]}")
    return code, txt


def main():
    code, txt = req(f"api/start?cb={int(time.time())}")
    print(f"api/start -> {code} {txt[:200]}")
    start = json.loads(txt)
    token = start["token"]
    known = sorted(int(k) for k in start.get("chunks", {}))
    cr = int(start.get("chunk_rows", 25))
    print(f"버림 토큰 {token[:24]}… / 아는 청크 {known} / chunk_rows={cr}")

    # 1. 빈 trace로 청크 2를 요구한다. 시드가 나오면 서버는 trace를 검증하지 않는다.
    ask(token, 2, [], 0, "빈 trace")
    time.sleep(6)

    # 2. 청크 2의 시작(50행)에 닿는 정상 trace. 클라이언트가 실제로 보내는 형태다.
    tr = trace_to_row(50)
    ask(token, 2, tr, tr[-1][0] + 8, "50행 trace")
    time.sleep(6)

    # 3. 같은 청크를 다시 요구한다 — 재요구가 허용되는가(되감기가 이것에 걸린다).
    ask(token, 2, tr, tr[-1][0] + 8, "청크2 재요구")
    time.sleep(6)

    # 4. 훨씬 앞선 청크를 건너뛰어 요구한다 — 순서를 강제하는가.
    tr2 = trace_to_row(500)
    ask(token, 20, tr2, tr2[-1][0] + 8, "청크20 건너뛰기")


if __name__ == "__main__":
    sys.exit(main())
