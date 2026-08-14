#!/usr/bin/env python3
"""로컬에서 게임을 서비스하고 `/api/*`만 실서버로 중계하는 프록시.

`Ranking.base_url()`은 `location.origin`에서 API 주소를 유도한다(ranking.gd:18-23).
따라서 게임을 `http://127.0.0.1:PORT/`에서 열면 API 호출도 이 프록시로 오고,
브라우저 입장에서는 같은 출처이므로 CORS 문제가 없다. 그 결과 **실제 클라이언트가
만든 토큰·trace·ticks를 그대로 유지한 채** 제출 바디만 조정할 수 있다.

Emscripten이 초기화 시점에 `fetch`/`XMLHttpRequest` 참조를 캡처하므로 페이지 로드 후
자바스크립트로 훅을 거는 방법은 통하지 않는다 — 그래서 이 프록시가 필요하다.

환경변수로 POST 바디를 조정한다(지정하지 않은 항목은 원본 유지).

    OVERRIDE_NAME   닉네임
    OVERRIDE_SCORE  점수 (정수, 또는 `x2`처럼 rows 배수)
    OVERRIDE_ROWS   rows

연습용 스위치. 자동 조종을 다듬는 동안 실서버를 건드리지 않기 위한 것이다 —
`api/start`에는 IP 단위 발급 제한("too many starts")이 있고 제출에는 빈도 제한이 있다.

    MOCK_START=1    `api/start`를 실서버로 보내지 않고 매번 다른 시드로 응답한다
    BLOCK_POST=1    POST를 중계하지 않고 로컬에서 거부한다

**오버라이드가 하나도 없으면 POST 바디를 바이트 그대로 중계한다.** 서버가 바디 형태를 지문으로
검사하므로(`docs/leaderboard-api.md` §6) 손대지 않는 것이 항상 안전하다. 오버라이드를 쓸 때만
Godot의 `JSON.stringify`와 동일하게 **키 정렬 + 공백 없음**으로 재직렬화한다.

08-14 패치 이후 `score`·`rows` 오버라이드는 서버 재현 검증에 막힌다(§8.1). 남은 용도는
`OVERRIDE_NAME` 정도다.

사용법:
    PORT=8777 OVERRIDE_NAME=사랑해요정호님 OVERRIDE_SCORE=x2 python3 tools/local_proxy.py
"""
import json, os, sys, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "_local")
UPSTREAM = "https://d15csla760jzen.cloudfront.net/"
PORT = int(os.environ.get("PORT", "8777"))

MIME = {".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm",
        ".pck": "application/octet-stream", ".png": "image/png"}


_mock_n = 0


def godot_json(payload):
    return json.dumps(payload, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False)


def log(msg):
    print(msg, flush=True)


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):  # noqa: A002 - 기본 접근 로그를 끈다
        pass

    def _common_headers(self):
        # Godot 웹 빌드가 기대하는 헤더 (실서버도 같은 값을 보낸다)
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")

    def _upstream(self, path, method, body=None):
        req = urllib.request.Request(UPSTREAM + path.lstrip("/"), data=body,
                                     method=method)
        if body is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/api/start" and os.environ.get("MOCK_START"):
            global _mock_n
            _mock_n += 1
            seed = 1000000000000000 + _mock_n * 7919 + PORT * 104729
            data = godot_json({"token": "MOCK.%d" % _mock_n,
                               "seed": str(seed)}).encode("utf-8")
            log(f"  GET  /api/start -> 모의 seed={seed}")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-cache")
            self._common_headers()
            self.end_headers()
            self.wfile.write(data)
            return
        if path.startswith("/api/"):
            code, data = self._upstream(self.path, "GET")
            log(f"  GET  {self.path} -> {code} {data[:120].decode('utf-8','replace')}")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-cache")
            self._common_headers()
            self.end_headers()
            self.wfile.write(data)
            return

        name = "index.html" if path == "/" else path.lstrip("/")
        full = os.path.join(ROOT, name)
        if not os.path.isfile(full):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        with open(full, "rb") as f:
            data = f.read()
        ext = os.path.splitext(name)[1]
        self.send_response(200)
        self.send_header("Content-Type", MIME.get(ext, "application/octet-stream"))
        self.send_header("Content-Length", str(len(data)))
        self._common_headers()
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(n)
        if self.path.split("?")[0] == "/api/scores":
            log(f"  바디({len(raw)}B): {raw[:180].decode('utf-8','replace')}")
        # 오버라이드가 하나도 없으면 재직렬화하지 않는다 — 서버가 바디 형태를 지문으로
        # 검사하므로(§6) 손대지 않는 것이 항상 안전하다.
        if self.path.split("?")[0] == "/api/scores" and any(
                os.environ.get(k) for k in
                ("OVERRIDE_NAME", "OVERRIDE_ROWS", "OVERRIDE_SCORE", "OVERRIDE_TRACE")):
            try:
                d = json.loads(raw.decode("utf-8"))
                orig = dict(d)
                if os.environ.get("OVERRIDE_NAME"):
                    d["name"] = os.environ["OVERRIDE_NAME"]
                if os.environ.get("OVERRIDE_ROWS"):
                    d["rows"] = int(os.environ["OVERRIDE_ROWS"])
                # trace/ticks 합성: 전진 홉 N개를 최소 간격(8틱) 이상으로 배치하고
                # ticks를 마지막 홉 + 8로 맞춘다 — 실제 클라이언트가 만드는 형태와 동일.
                tn = os.environ.get("OVERRIDE_TRACE")
                if tn:
                    n = int(tn)
                    gap = int(os.environ.get("OVERRIDE_GAP", "12"))
                    d["trace"] = [[91 + gap * i, 0] for i in range(n)]
                    d["ticks"] = d["trace"][-1][0] + 8 if n else 8
                sc = os.environ.get("OVERRIDE_SCORE")
                if sc:
                    d["score"] = int(d["rows"]) * int(sc[1:]) if sc.startswith("x") \
                        else int(sc)
                raw = godot_json(d).encode("utf-8")
                log(f"  원본 score={orig.get('score')} rows={orig.get('rows')} "
                    f"ticks={orig.get('ticks')} trace={len(orig.get('trace', []))}건 "
                    f"name={orig.get('name')}")
                log(f"  전송 score={d.get('score')} rows={d.get('rows')} "
                    f"name={d.get('name')}")
            except Exception as e:
                log(f"  바디 파싱 실패: {e}")
        if os.environ.get("BLOCK_POST"):
            data = b'{"ok":false,"error":"blocked-locally"}'
            log(f"  POST {self.path} -> 로컬에서 차단 (중계하지 않음)")
            self.send_response(403)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self._common_headers()
            self.end_headers()
            self.wfile.write(data)
            return
        code, data = self._upstream(self.path, "POST", raw)
        log(f"  POST {self.path} -> {code} {data[:200].decode('utf-8','replace')}")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self._common_headers()
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    if not os.path.isdir(ROOT):
        sys.exit(f"클라이언트 사본이 없다: {ROOT}")
    log(f"게임: http://127.0.0.1:{PORT}/   (API는 {UPSTREAM}로 중계)")
    log(f"오버라이드: name={os.environ.get('OVERRIDE_NAME')} "
        f"score={os.environ.get('OVERRIDE_SCORE')} rows={os.environ.get('OVERRIDE_ROWS')}")
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
