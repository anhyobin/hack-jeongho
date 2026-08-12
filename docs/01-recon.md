# 01. 표적 파악

## 첫 화면에서 얻은 것

`https://d15csla760jzen.cloudfront.net/` 는 `<canvas>` 하나뿐인 페이지예요.
DOM 접근성 트리에는 `Your browser does not support the canvas tag.` 만 남아 있어서,
브라우저 자동화로 UI를 읽는 접근은 처음부터 쓸 수 없었어요.

HTML 안의 부트스트랩 설정에서 무엇으로 만든 게임인지 바로 드러납니다.

```js
const GODOT_CONFIG = {
  "executable": "index",
  "fileSizes": { "index.pck": 3419732, "index.wasm": 39513091 },
  "ensureCrossOriginIsolationHeaders": true,
  ...
};
```

- Godot 엔진 웹 익스포트 (엔진 버전은 나중에 pck 헤더에서 4.7.1 로 확인)
- 게임 로직은 39MB `index.wasm`(엔진 본체)이 아니라 3.4MB `index.pck`(게임 데이터) 안에 있음
- 정적 호스팅은 CloudFront, 단 `/api/*` 응답 헤더는 `server: SimpleHTTP/0.6 Python/3.9.25`
  → 오리진에 파이썬 HTTP 서버가 직접 붙어 있고, 랭킹은 거기서 처리

## 네트워크 관찰

게임을 실제로 한 번 시작해 보면 API가 두 개뿐이에요.

| 시점 | 요청 |
|---|---|
| 랭킹 화면 열기 | `GET /api/scores` |
| 게임 시작 | `GET /api/start` → `{"token": "..."}` |
| 게임 오버 후 등록 | `POST /api/scores` |

`GET /api/start` 가 게임 **시작 시점에** 토큰을 발급한다는 게 핵심 단서였어요.
토큰 문자열의 첫 필드가 유닉스 타임스탬프라서, 서버가 "언제 시작해서 언제 제출했는지"로
점수의 타당성을 볼 것이라고 예상할 수 있어요.

기존 랭킹 1위는 `민지 401점(stage 16)` 이었고, 상위권은 대체로 300~400점대였어요.
목표였던 10000점은 사람 최고 기록의 25배라서, 실제 플레이로는 불가능한 값이라는 게 이때 확정됐어요.

## pck 열기 — 포맷 v4 함정

`index.pck` 를 내려받아 `strings` 로 훑으면 리소스 경로는 보이는데 URL이나 로직 문자열이 안 나와요.
스크립트가 `.gdc`(토큰 버퍼)로 컴파일되어 있고 zstd 압축이라 그렇습니다.

먼저 pck 인덱스를 읽어야 하는데, 널리 알려진 v2/v3 레이아웃 기준으로 파싱하면 `file_count == 0` 이 나와요.
Godot 4.7 이 쓰는 **포맷 v4** 는 헤더에 uint64 하나가 더 있고, 파일 인덱스가 **파일 끝**으로 이동했어요.

```
0x00  "GDPC"
0x04  pack format version = 4
0x08  engine 4 / 7 / 1
0x14  flags = 0x2          (bit1 = 파일 오프셋이 file_base 상대값)
0x18  file_base    = 0x70
0x20  index_offset = 0x3409f0   <- v4 에서 추가된 필드, 인덱스가 여기 있음
```

이 한 줄 차이 때문에 범용 추출기가 조용히 빈 결과를 내놨어요.
직접 작성한 추출기가 [`tools/extract_pck.py`](../tools/extract_pck.py) 이고, 110개 파일 중 스크립트 8개를 얻었어요.

```
scripts/game.gdc        10473 bytes
scripts/main.gdc         2362
scripts/player.gdc       3751
scripts/ranking.gdc      3207   <- 랭킹 API 로직
scripts/row.gdc         11570   <- 차/통나무/기차 생성과 충돌 판정
scripts/sfx.gdc          1604
scripts/theme_defs.gdc   3397   <- 스테이지별 난이도 수치
scripts/ui.gdc          17949
```

## .gdc 복원

`.gdc` 는 바이트코드가 아니라 **토큰 스트림**이에요 (Godot 4.3+ `GDScriptTokenizerBuffer`).
식별자 테이블, 상수 테이블, 그리고 `토큰 인덱스 → 줄/열` 매핑까지 그대로 들어 있어서
주석과 정확한 공백만 빼면 원본 소스를 거의 그대로 되돌릴 수 있어요.

```
"GDSC" | version=101 | decompressed_size | zstd frame
  payload: identifier_count, constant_count, token_line_count, token_count
           identifiers[]  (각 문자 4바이트, 바이트마다 ^ 0xb6)
           constants[]    (encode_variant 포맷)
           token_lines[]  (토큰 인덱스 → 줄)
           token_columns[](토큰 인덱스 → 열)  <- 들여쓰기 복원에 사용
           tokens[]       (1 또는 4바이트 타입 + uint32 줄번호)
```

멀티라인 모드로 직렬화되어 `NEWLINE`/`INDENT`/`DEDENT` 토큰이 아예 없어서,
줄바꿈은 `token_lines`, 들여쓰기 깊이는 `token_columns` 로 재구성했어요.
복원기는 [`tools/gdc_decompile.py`](../tools/gdc_decompile.py), 결과는 [`decompiled/`](../decompiled) 에 있어요.

복원 품질은 이 정도예요 (`decompiled/ranking.gd` 일부).

```gdscript
func submit(name: String, score: int, rows: int, char_id:= "rabbit") -> void:
	if token == "":
		submit_reason = "offline"
		submitted.emit(false, -1, [])
		return
	var body:= JSON.stringify({ "name": name, "score": score, "rows": rows, "char": char_id, "token": token})
	_request(base_url() + "api/scores", HTTPClient.METHOD_POST, body, func(payload):
		...
	)
```

여기서 제출 페이로드 형식이 확정됐고, 다음 단계는 서버가 이 값들을 어떻게 검사하는지였어요.
→ [03-api-protocol.md](03-api-protocol.md)
