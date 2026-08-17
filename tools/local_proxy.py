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

    MOCK_START=1    `api/start`와 `api/chunk`를 실서버로 보내지 않고 로컬에서 응답한다
    BLOCK_POST=1    `POST api/scores`를 중계하지 않고 로컬에서 거부한다
                    (**`api/chunk`는 막지 않는다** — 프로토콜 v4에서 이것을 막으면
                     월드를 서버에서 못 받아 주행이 통째로 `unranked`가 된다)

제출 허용 조건. 프로토콜 v4에서는 탐색 주행도 실토큰을 들고 돌아야 하므로
(청크 시드를 `want_chunk`가 실토큰으로만 받아온다) "탐색 중에는 active_token이
TEST라서 제출이 구조적으로 불가능하다"는 옛 가드가 사라졌다. 그 자리를 게임 밖에서
메운다 — **조건에 맞지 않는 `POST api/scores`는 중계 자체를 하지 않는다.**

    ALLOW_POST_NAME=<닉네임>   이 닉네임이 아니면 중계하지 않는다
    ALLOW_POST_MIN_SCORE=<수>  이 점수 미만이면 중계하지 않는다

**오버라이드가 하나도 없으면 POST 바디를 바이트 그대로 중계한다.** 서버가 바디 형태를 지문으로
검사하므로(`docs/leaderboard-api.md` §6) 손대지 않는 것이 항상 안전하다. 오버라이드를 쓸 때만
Godot의 `JSON.stringify`와 동일하게 **키 정렬 + 공백 없음**으로 재직렬화한다.

08-14 패치 이후 `score`·`rows` 오버라이드는 서버 재현 검증에 막힌다(§8.1). 남은 용도는
`OVERRIDE_NAME` 정도다.

사용법:
    PORT=8777 OVERRIDE_NAME=사랑해요정호님 OVERRIDE_SCORE=x2 python3 tools/local_proxy.py
"""
import json, os, sys, time, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "_local")
UPSTREAM = "https://d15csla760jzen.cloudfront.net/"
PORT = int(os.environ.get("PORT", "8777"))

MIME = {".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm",
        ".pck": "application/octet-stream", ".png": "image/png"}


_mock_n = 0
MOCK_CHUNK_DELAY = float(os.environ.get("MOCK_CHUNK_DELAY", "0.15"))
# 모의 토큰의 나이(초). `Ranking.TOKEN_STALE_SEC`(600) 미만이어야 한다 — 넘으면
# 클라이언트가 스스로 재발급한다.
MOCK_TOKEN_AGE = float(os.environ.get("MOCK_TOKEN_AGE", "0"))


def godot_json(payload):
    return json.dumps(payload, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False)


_t0 = time.time()


def log(msg):
    """★ 타임스탬프를 반드시 남긴다.

    08-15에 `api/chunk` 요청이 177건 나갔는데, 게임 쪽 로그로는 대기 진입이 1회였다.
    간격을 몰라서 원인을 특정할 수 없었다 — 6초 간격이면 회차가 많았던 것이고,
    100ms 간격이면 게이트를 새는 경로가 따로 있는 것이다. 그 구분이 전부다.
    """
    print("[%8.3f] %s" % (time.time() - _t0, msg), flush=True)


def mock_world_seed(n):
    return 1000000000000000 + n * 7919 + PORT * 104729


def mock_chunk_seed(n, i):
    """모의 청크 시드 — (모의 주행 번호, 청크 번호)만의 함수라서 재현된다.

    실서버는 25행마다 새 시드를 주고 `Game._ensure_chunk`가 그 자리에서
    `rng.seed`를 갈아 낀다(`game.gd`). 청크마다 독립된 시드라는 성질만 같으면
    연습 월드도 실서버 월드와 같은 구조를 갖는다.
    """
    h = (mock_world_seed(n) * 1000003 + i * 2654435761) & 0xFFFFFFFFFFFFF
    return h | 1


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):  # noqa: A002 - 기본 접근 로그를 끈다
        pass

    def _common_headers(self):
        # Godot 웹 빌드가 기대하는 헤더 (실서버도 같은 값을 보낸다)
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")

    def _json(self, code, payload):
        data = payload if isinstance(payload, bytes) else \
            godot_json(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self._common_headers()
        self.end_headers()
        self.wfile.write(data)

    # 브라우저가 보낸 헤더 중 실서버로 그대로 넘길 것.
    #
    # ★ 넘기지 않으면 요청 겉모습이 `User-Agent: Python-urllib/3.x`가 된다. 요청 **내용**은
    #   진짜 게임이 만든 것인데 겉모습만 스크립트인 상태이고, 서버가 그것을 보기 시작하면
    #   같은 바디가 거부된다. 08-15 오후에 오전과 **완전히 같은 (청크, 도달 행)** 요청이
    #   전부 거부되고 제3자는 정상 등록한 것이 이 가설의 출발점이다.
    #
    #   `Origin`·`Referer`는 **위조하지 않는다.** 브라우저가 보내는 값(`127.0.0.1:PORT`)을
    #   그대로 넘길 뿐이고, 서버가 그것으로 막는다면 그건 운영자의 의도적인 통제이므로
    #   따른다. 아래 목록은 전부 "이 클라이언트가 실제로 무엇인가"를 사실대로 말하는 헤더다.
    FWD_HEADERS = ("user-agent", "accept", "accept-language", "origin", "referer",
                   "sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest",
                   "sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform")

    def _upstream(self, path, method, body=None):
        req = urllib.request.Request(UPSTREAM + path.lstrip("/"), data=body,
                                     method=method)
        if body is not None:
            req.add_header("Content-Type", "application/json")
        for k in self.FWD_HEADERS:
            v = self.headers.get(k)
            if v:
                req.add_header(k, v)
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
            seed = mock_world_seed(_mock_n)
            # 토큰의 첫 필드는 발급 epoch이고 클라이언트·하네스가 나이를 그것으로
            # 계산한다. **v5부터 1시간 전으로 발급하면 안 된다** —
            # `Ranking.token_stale()`이 600초를 넘은 토큰을 낡았다고 보고
            # `Main._process`/`begin_game`이 그 자리에서 재발급해 버린다.
            # 기본은 갓 발급(0초)이라 실서버와 같은 페이싱을 연습에서 그대로 겪는다.
            # 빨리 돌려 보고 싶으면 URL에 `space=0`을 주거나 MOCK_TOKEN_AGE를 올린다
            # (600 미만으로).
            token = "%d.mock%04d.0000000000000000" % (
                int(time.time()) - int(MOCK_TOKEN_AGE), _mock_n)
            # 실서버는 청크 0·1만 미리 준다(실측). 그 뒤는 `api/chunk`로 받아온다.
            chunks = {str(i): str(mock_chunk_seed(_mock_n, i)) for i in (0, 1)}
            log(f"  GET  /api/start -> 모의 seed={seed} chunks=0,1")
            self._json(200, {"token": token, "seed": str(seed),
                             "chunk_rows": 25, "chunks": chunks})
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

    def _mock_chunk(self, raw):
        """`POST api/chunk`의 모의 응답.

        실서버는 trace를 재현해 그 청크에 실제로 닿았는지 본다(청크 0·1은 무조건
        발급, 청크 2 이상은 합성 trace로는 `403 rejected` — 실측).

        `MOCK_CHUNK_WINDOW=1`이면 실측한 **행수 창**까지 흉내낸다. 서버는 자기가
        발급한 청크(0..i-1 = 행 0..i*25-1)까지만 월드를 만들 수 있으므로, trace가
        도달한 행 R에 대해 재현이 필요한 `R + 10~19`행이 그 범위를 넘으면 거부한다.
        그래서 창은 대략 `[(i-1)*25, (i-1)*25 + 14]`다. 창을 흉내내면 실서버에 가기
        전에 하네스가 요청 시점을 맞추는지 연습에서 확인할 수 있다.
        """
        try:
            d = json.loads(raw.decode("utf-8"))
            ci = int(d.get("i", 0))
            tok = str(d.get("token", ""))
            n = int(tok.split(".")[1][4:]) if ".mock" in tok else 1
        except Exception as e:
            log(f"  POST /api/chunk 파싱 실패: {e}")
            self._json(400, {"ok": False, "error": "bad-body"})
            return
        # 토큰 1개가 보증하는 청크 상한을 모의한다(벽 상황 재현용).
        #
        # ⚠ 옛 주석은 "실서버는 청크 26까지 주고 27을 거부한다 — 발급 25건이 상한(추정)"
        #   이었다. **08-17에 폐기됐다**: 700점 주행이 청크 27을 받았고(chunks 2~27, 26건),
        #   그날 `api/chunk` 190건에 실제 403이 0건이었다. 상한이 있다면 그보다 깊다.
        #   그리고 그 시절의 "거부" 판정 일부는 요청이 나가지도 않은 유령이었다
        #   (`docs/autopilot.md` §13.1). 이 값은 이제 **실측 상한이 아니라 시험용 손잡이**다.
        cmax = os.environ.get("MOCK_CHUNK_MAX")
        if cmax and ci > int(cmax):
            log(f"  POST /api/chunk i={ci} -> 청크 상한({cmax}) 초과라 거부")
            self._json(403, {"ok": False, "error": "rejected"})
            return
        if os.environ.get("MOCK_CHUNK_WINDOW") and ci >= 2:
            r = mx = 0
            for e in d.get("trace", []):
                c = int(e[1])
                r += 1 if c == 0 else (-1 if c == 1 else 0)
                mx = max(mx, r)
            # 아래끝은 배포된 클라이언트가 **생성이 막혀** 직접 요청하는 지점에 맞춘다
            # (`i*25 - 19 ~ -10` = 아래끝+6~15). 08-15 00:27 실측에서 아래끝+2가
            # 거부됐으므로 서버의 아래끝은 그보다 깊다.
            lo, hi = (ci - 1) * 25 + 6, ci * 25 - 1
            if not (lo <= mx <= hi):
                log(f"  POST /api/chunk i={ci} {mx}행 -> 창 [{lo},{hi}] 밖이라 거부")
                self._json(403, {"ok": False, "error": "rejected"})
                return
        if MOCK_CHUNK_DELAY > 0:
            time.sleep(MOCK_CHUNK_DELAY)   # 왕복 지연을 흉내낸다
        seed = mock_chunk_seed(n, ci)
        log(f"  POST /api/chunk i={ci} ticks={d.get('ticks')} "
            f"trace={len(d.get('trace', []))}건 -> 모의 seed={seed}")
        self._json(200, {"ok": True, "i": ci, "seed": str(seed)})

    def _post_allowed(self, raw):
        """`POST api/scores`를 중계할지 판정한다. 조건이 없으면 항상 허용한다."""
        want_name = os.environ.get("ALLOW_POST_NAME")
        want_min = os.environ.get("ALLOW_POST_MIN_SCORE")
        if not want_name and not want_min:
            return True, ""
        try:
            d = json.loads(raw.decode("utf-8"))
        except Exception as e:
            return False, f"바디를 못 읽었다: {e}"
        if want_name and str(d.get("name", "")) != want_name:
            return False, f"닉네임이 {d.get('name')!r} — 허용은 {want_name!r}"
        if want_min and int(d.get("score", 0)) < int(want_min):
            return False, f"점수가 {d.get('score')} — 허용은 {want_min} 이상"
        return True, ""

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(n)
        path0 = self.path.split("?")[0]

        # `api/chunk`는 월드를 받아오는 경로다. BLOCK_POST가 이것까지 막으면 주행이
        # 통째로 `unranked`가 되어 연습이 실서버와 다른 것을 재게 된다.
        if path0 == "/api/chunk":
            if os.environ.get("MOCK_START"):
                self._mock_chunk(raw)
                return
            code, data = self._upstream(self.path, "POST", raw)
            try:
                d = json.loads(raw.decode("utf-8"))
                head = f"i={d.get('i')} ticks={d.get('ticks')} trace={len(d.get('trace', []))}건"
            except Exception:
                head = f"{len(raw)}B"
            log(f"  POST /api/chunk {head} ua={self.headers.get('user-agent','-')[:22]!r}"
                f" -> {code} {data[:120].decode('utf-8', 'replace')}")
            self._json(code, data)
            return

        if path0 == "/api/scores":
            log(f"  바디({len(raw)}B): {raw[:180].decode('utf-8','replace')}")
            # 시뮬레이터 검증용 정답지. 모의 토큰이면 시드를 되계산해 함께 적는다 —
            # (seed, trace, ticks, rows)가 있으면 포팅이 맞는지 오프라인에서 확인할 수 있다.
            dump = os.environ.get("DUMP_BODIES")
            if dump:
                try:
                    d = json.loads(raw.decode("utf-8"))
                    tok = str(d.get("token", ""))
                    if ".mock" in tok:
                        mn = int(tok.split(".")[1][4:])
                        d["seed"] = mock_world_seed(mn)
                        d["chunks"] = {str(i): mock_chunk_seed(mn, i)
                                       for i in range(64)}
                    with open(dump, "a", encoding="utf-8") as fh:
                        fh.write(godot_json(d) + "\n")
                    log(f"  덤프 -> {dump}")
                except Exception as e:
                    log(f"  덤프 실패: {e}")
        # 오버라이드가 하나도 없으면 재직렬화하지 않는다 — 서버가 바디 형태를 지문으로
        # 검사하므로(§6) 손대지 않는 것이 항상 안전하다.
        if path0 == "/api/scores" and any(
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
        if path0 == "/api/scores" and os.environ.get("BLOCK_POST"):
            log(f"  POST {self.path} -> 로컬에서 차단 (중계하지 않음)")
            self._json(403, {"ok": False, "error": "blocked-locally"})
            return
        # 탐색 주행도 실토큰을 들고 도는 프로토콜 v4에서는 이 가드가 오제출을 막는
        # 마지막 방벽이다. 게임 안의 어떤 실수도 이 조건을 통과하지 못한다.
        if path0 == "/api/scores":
            ok, why = self._post_allowed(raw)
            if not ok:
                log(f"  POST {self.path} -> 허용 조건 불일치로 차단: {why}")
                self._json(403, {"ok": False, "error": "blocked-locally",
                                 "hint": why})
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
    log(f"모의: start={bool(os.environ.get('MOCK_START'))} "
        f"chunk 지연={MOCK_CHUNK_DELAY}s | POST 차단={bool(os.environ.get('BLOCK_POST'))}")
    log(f"제출 허용: name={os.environ.get('ALLOW_POST_NAME')} "
        f"최소점수={os.environ.get('ALLOW_POST_MIN_SCORE')}"
        + ("  ← 조건 없음(모든 제출 중계)" if not os.environ.get("ALLOW_POST_NAME")
           and not os.environ.get("ALLOW_POST_MIN_SCORE") else ""))
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
