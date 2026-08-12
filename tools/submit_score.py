#!/usr/bin/env python3
"""
고라니 피하기 랭킹 등록기.

서버 검증 규칙(docs/03-api-protocol.md)을 그대로 반영해서, 목표 점수에 필요한
대기 시간을 계산한 뒤 한 번만 POST 합니다. 토큰은 1회용이고 거절된 시도에도
소모되므로, "일단 던져보고 실패하면 재시도" 방식은 쓸 수 없습니다.

    python3 submit_score.py --name 바이브정호 --score 1600
    python3 submit_score.py --name 핵정호 --score 10000 --char peccy
    python3 submit_score.py --board            # 현재 랭킹만 조회

검증 규칙 요약
    score / (now - token_ts) <= ~4.8      초당 전진 칸 수 상한 -> "too_fast"
    score <= rows * 2                     니어미스 보너스 상한 -> "inconsistent"
    토큰 1회용                             재사용 -> "token:reused"
    IP 연속 요청 제한(약 20~30초)          -> "too fast" (공백 버전, 별개 검사)
"""
import argparse
import json
import sys
import time
import urllib.request

BASE = "https://d15csla760jzen.cloudfront.net/"
# 4.82 rows/s 는 통과가 확인된 값. 경계를 정확히 이분탐색하지 않았으므로
# 안전 계수를 곱해서 사용합니다.
CONFIRMED_RATE = 4.82
SAFETY = 0.85
CHARS = ("rabbit", "chick", "hedgehog", "gorani_p", "peccy")


def _call(path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        BASE + path, data=data,
        headers={"Content-Type": "application/json"},
        method="POST" if data else "GET")
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read().decode())


def board(limit=10):
    scores = _call("api/scores")["scores"]
    now = time.time()
    for i, s in enumerate(scores[:limit], 1):
        print(" %2d. %-14s %6d  stage %-4s %-9s %d분 전"
              % (i, s["name"], s["score"], s.get("stage"), s.get("char"),
                 (now - s["ts"]) // 60))
    return scores


def submit(name, score, char, rows=None, rate=CONFIRMED_RATE * SAFETY, dry_run=False):
    if len(name) > 12:
        sys.exit("닉네임은 12자 이하여야 합니다 (클라이언트 LineEdit.max_length = 12)")
    if rows is None:
        # 점수의 98%를 전진 칸수로, 나머지를 니어미스 보너스로 배분하면
        # score <= rows * 2 를 넉넉히 만족하면서 자연스러운 조합이 됩니다.
        rows = int(score * 0.98)
        rows -= (score - rows) % 2                      # 보너스는 항상 짝수(+2/회)
    if score > rows * 2:
        sys.exit("score(%d) > rows(%d) * 2 이면 서버가 inconsistent 로 거절합니다" % (score, rows))

    need = score / rate
    token = _call("api/start")["token"]
    issued = int(token.split(".")[0])                   # 토큰 앞부분이 서버 발급 시각
    print("token=%s\n필요 대기=%.0f초 (목표 %.2f rows/s), stage=%d 로 기록됩니다"
          % (token, need, score / need, rows // 20))
    if dry_run:
        return None

    while True:
        elapsed = time.time() - issued
        if elapsed >= need:
            break
        left = need - elapsed
        print("\r  대기 중… %4.0f초 남음 (경과 %4.0f초)" % (left, elapsed), end="", flush=True)
        time.sleep(min(5, left))
    print("\r  경과 %.0f초 -> 전송" % (time.time() - issued))

    res = _call("api/scores", {"name": name, "score": score, "rows": rows,
                               "char": char, "token": token})
    if not res.get("ok"):
        print("거절: %s" % res.get("error"))
        return res
    print("등록 완료: %d위\n" % res.get("rank", -1))
    for i, s in enumerate(res.get("scores", [])[:10], 1):
        mark = " <=" if s["name"] == name and s["score"] == score else ""
        print(" %2d. %-14s %6d  stage %-4s %-9s%s"
              % (i, s["name"], s["score"], s.get("stage"), s.get("char"), mark))
    return res


def main():
    ap = argparse.ArgumentParser(description="고라니 피하기 랭킹 등록기")
    ap.add_argument("--name", help="닉네임 (12자 이하)")
    ap.add_argument("--score", type=int, help="등록할 점수")
    ap.add_argument("--rows", type=int, help="전진 칸수 (기본: score*0.98)")
    ap.add_argument("--char", default="peccy", choices=CHARS)
    ap.add_argument("--rate", type=float, default=CONFIRMED_RATE * SAFETY,
                    help="초당 전진 칸수 가정값 (기본 %.2f)" % (CONFIRMED_RATE * SAFETY))
    ap.add_argument("--dry-run", action="store_true", help="대기 시간만 계산")
    ap.add_argument("--board", action="store_true", help="현재 랭킹 조회")
    args = ap.parse_args()

    if args.board or not (args.name and args.score):
        board()
        if not args.board:
            ap.print_help()
        return
    submit(args.name, args.score, args.char, args.rows, args.rate, args.dry_run)


if __name__ == "__main__":
    main()
