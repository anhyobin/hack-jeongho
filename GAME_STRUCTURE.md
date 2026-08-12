# 고라니 피하기 — 게임 구조 분석

분석 대상은 `https://d15csla760jzen.cloudfront.net/` 에서 서비스되는 웹 게임 "고라니 피하기"다. Godot 4.7.1로 빌드된 HTML5(WebAssembly) 익스포트이며, 세로 화면(640x960) Crossy-Road / Frogger 계열의 무한 진행형 아케이드 게임이다. 이 문서는 CloudFront에서 내려온 `index.pck`을 언팩하고 그 안의 GDScript 바이너리 토큰 파일(`.gdc`) 8개를 전부 소스로 되돌려 얻은 결과를 기반으로, 게임의 실행 구조·모듈 경계·게임 디자인 수치·서버 계약을 정리한 것이다.

**한눈에 보기.** 이 게임은 **약 1,900줄(정확히 1,880줄)의 순수 GDScript로만 이루어져 있고, 씬 파일은 단 하나(`res://main.tscn`)뿐이며 그 씬조차 스크립트 한 개가 붙은 `Node` 하나짜리 껍데기다.** 플레이어, 행(row), 차량, 통나무, 기차, 눈송이, 그리고 타이틀·HUD·게임오버·랭킹·일시정지 5개 화면의 모든 위젯까지 — 화면에 보이는 전부가 런타임에 `Row.new()`, `Label.new()`, `Button.new()`, `ColorRect.new()` 같은 호출로 명령형(imperative)으로 조립된다. 즉 에디터 씬 트리에 의존하는 부분이 사실상 0이고, 게임의 구조 전체가 8개 스크립트 파일 안에 텍스트로 존재한다. 이 성질 덕분에 `.gdc` 디컴파일 하나만으로 게임의 100%를 복원할 수 있었다.

---

## 1. 분석 방법

### 1.1 전달 자산 수집

시작점은 CloudFront 배포 `d15csla760jzen.cloudfront.net`이다. 루트 문서 `index.html`은 Godot 웹 익스포트의 표준 로더 페이지로, 인라인 `GODOT_CONFIG` 객체와 `new Engine(GODOT_CONFIG)` 호출을 담고 있다(index.html:114-116). 로더 스크립트 `index.js`가 WebAssembly 런타임과 파일시스템 브리지를 제공하고, `index.wasm`이 엔진 바이너리, `index.pck`이 게임 데이터 전체다. 이 중 로컬 디스크로 내려받아 정적 분석에 사용한 것은 `index.js`(279,815 B)와 `index.pck`(3,419,732 B)이며, `index.html`·`index.wasm`에 관한 서술은 라이브 HTTP 응답을 직접 관찰해 얻은 것이다(로컬 사본 없음).

### 1.2 GDPC 팩 언팩

`index.pck`은 Godot의 GDPC 컨테이너다. 헤더에서 읽어낸 값은 `pack_format_version=4`, `engine=4.7.1`, `flags=2`, `file_base=112`이고, 디렉터리는 파일 **끝부분**(`dir_off = 0x3409f0`)에 놓여 있으며 총 **110개 엔트리**를 담는다. `flags=2`는 디렉터리의 오프셋이 절대값이 아니라 `file_base`를 기준으로 하는 상대값(`PACK_REL_FILEBASE`)이라는 뜻이므로, 각 엔트리의 실제 파일 위치는 `file_base + entry_offset`으로 계산해야 한다. 이 규칙을 적용해 110개 엔트리를 전부 추출한 결과가 `/Users/anhyobin/dev/hack-jeongho/unpacked_manifest.txt`이며, 내용은 크게 다음으로 나뉜다.

| 그룹 | 엔트리 | 비고 |
|---|---|---|
| 스크립트 | `scripts/*.gdc` 8개 + `*.gd.remap` 8개 | remap 스텁이 `res://scripts/x.gd` → `.gdc`를 연결 |
| 씬 | `main.tscn.remap`(97 B) + `.godot/exported/.../*-main.scn`(675 B) | **씬 파일은 이것 하나뿐** |
| 프로젝트 설정 | `project.binary`(886 B, magic `ECFG`) | 아래 §2.4 표 |
| 텍스처 | `.godot/imported/*.ctex` 30개 (magic `GST2`) | WebP 임베드 |
| 오디오 | `.godot/imported/*.sample` 11개 (magic `RSRC`) | `AudioStreamWAV` |
| 폰트 | `*.fontdata` 3개 (magic `RSCC`) | Galmuri9 / 11 / 11-Bold |

`main.tscn`이 단일 노드(`Main`, 타입 `Node`, `res://scripts/main.gd` 첨부)라는 사실 — 즉 게임의 나머지 전부가 코드로 만들어진다는 사실 — 이 이 시점에서 확정되었다. `.scn` 크기가 675 B밖에 되지 않는 것이 그 정황 증거다.

### 1.3 `.gdc` 바이너리 토큰 디컴파일

Godot 4.3 이후의 릴리스 익스포트는 GDScript를 텍스트가 아닌 **토큰 버퍼**로 저장한다. 8개 파일 모두 magic이 `GDSC`이고 레이아웃은 다음과 같다(구현 근거: Godot 4.7의 `modules/gdscript/gdscript_tokenizer_buffer.cpp`).

```
Header : "GDSC" | u32 tokenizer_version | u32 decompressed_size | zstd payload
Payload: u32 identifier_count, constant_count, token_line_count, token_count
         identifiers   (각각 u32 len + len*u32 코드포인트, 전 바이트 XOR 0xb6)
         constants     (core/io/marshalls.cpp의 encode_variant 스트림)
         token_lines   (token_line_count * (u32 token_idx, u32 line))
         token_columns (token_line_count * (u32 token_idx, u32 column))
         tokens        (토큰당 5바이트, 첫 바이트에 0x80 플래그가 있으면 8바이트 + 값 인덱스)
```

이 포맷을 되돌리는 데 결정적인 요소는 세 가지였다.

1. **식별자 난독화가 XOR 0xb6 한 겹뿐**이다. 각 식별자는 UTF-32 코드포인트 배열로 저장되고 전 바이트에 `0xb6`이 XOR되어 있을 뿐이라, 변수·함수·클래스 이름이 **원본 그대로** 복원된다. 이름 해싱이나 매핑 테이블 제거가 없으므로 `_over_token`, `_resolve_landing`, `ambush_armed` 같은 이름이 개발자가 쓴 그대로 나온다.
2. **`token_lines`와 `token_columns`가 남아 있다.** 각 줄의 첫 토큰마다 (토큰 인덱스 → 원본 줄 번호)와 (토큰 인덱스 → 원본 컬럼)이 기록되어 있어, 줄 번호를 정확히 재현하고 컬럼 값에서 들여쓰기 깊이를 역산할 수 있다. 디컴파일러는 `col - 1`을 들여쓰기 단위로 나눠 깊이를 얻고, 관측된 최소 들여쓰기 폭이 1이면 탭 인덱스로 판단한다(`gdc_decompile.py` `render()`). 이 게임의 8개 파일은 모두 탭 들여쓰기로 판정되었다. 그래서 이 문서의 모든 `file.gd:LINE` 인용은 **원본 줄 번호와 일치**한다.
3. **리터럴이 Variant 스트림으로 온전히 남아 있다.** 상수 풀을 `encode_variant`로 역직렬화하면 정수/실수/문자열이 값 그대로 나온다. 한국어 문자열(`"고라니 피하기"`, `"차에 치이고 말았다…"`)도 UTF-8로 그대로 복원된다.

### 1.4 무결성 증거: leftover = 0

디컴파일러가 페이로드를 끝까지 읽고 나서 남은 바이트 수(`leftover`)는 8개 파일 전부 **0**이다. 즉 헤더에 선언된 개수만큼의 식별자·상수·라인맵·토큰을 순서대로 소비한 결과가 버퍼 길이와 정확히 일치했고, 해석하지 못해 건너뛴 영역이 하나도 없다. 이것이 복원된 소스가 원본과 토큰 단위로 동일하다는 근거다.

| 파일 | tokenizer | 식별자 | 상수 | 토큰 | leftover | .gdc 크기 | 복원 줄 수 |
|---|---|---|---|---|---|---|---|
| `main.gdc` | v101 | 66 | 16 | 491 | 0 | 2,362 B | 93 |
| `game.gdc` | v101 | 202 | 98 | 2,668 | 0 | 10,473 B | 384 |
| `row.gdc` | v101 | 186 | 156 | 3,075 | 0 | 11,570 B | 424 |
| `player.gdc` | v101 | 86 | 54 | 963 | 0 | 3,751 B | 140 |
| `ui.gdc` | v101 | 257 | 213 | 4,538 | 0 | 17,949 B | 569 |
| `ranking.gdc` | v101 | 86 | 31 | 726 | 0 | 3,207 B | 108 |
| `sfx.gdc` | v101 | 51 | 20 | 325 | 0 | 1,604 B | 52 |
| `theme_defs.gdc` | v101 | 24 | 130 | 1,020 | 0 | 3,397 B | 110 |
| **합계** | | | | **13,806** | **0** | | **1,880** |

### 1.5 복원되지 않는 것 — 정직한 한계

**주석은 복원 불가능하다.** 토크나이저가 주석을 토큰으로 만들지 않으므로 주석은 애초에 버퍼에 존재하지 않는다. 따라서 이 문서는 개발자의 의도를 주석에서 읽은 적이 단 한 번도 없으며, 의도에 대한 진술은 모두 코드 동작에서 유도한 추론이고 그럴 때마다 "추정"으로 표시했다.

**서식은 정규화된다.** 토큰 사이의 공백은 버퍼에 없으므로 디컴파일러의 규칙(`NO_SPACE_BEFORE` / `NO_SPACE_AFTER` / 단항 연산자 문맥 판정)으로 재구성된 것이다. 줄 번호·빈 줄·들여쓰기 깊이는 정확하지만, 한 줄 안에서 연산자 주변 공백이나 긴 리터럴 배열의 줄바꿈 위치는 원본과 다를 수 있다. `var x:= 1` → `var x := 1` 같은 치환은 디컴파일러가 가독성을 위해 정규식으로 적용한 것이다(`gdc_decompile.py` 말미). 문서에 인용한 GDScript 발췌문은 이 정규화된 형태다.

**의미 없는 잔재는 그대로 남는다.** 사용되지 않는 변수(`Ranking.server_ok`, `UI.font_s`)나 쓰이지 않는 매개변수(`UI.show_game_over`의 `stage_i`)는 복원된 소스에 그대로 나타난다. 이것들은 디컴파일 오류가 아니라 원본에 실제로 존재하는 죽은 코드다(§8.2).

---

## 2. 배포 구조

### 2.1 호스팅과 오리진

오리진 서버는 응답 헤더에 `server: SimpleHTTP/0.6 Python/3.9.25`를 실어 보내는 Python `http.server` 기반 프로세스다. 존재하지 않는 경로를 요청하면 파이썬 표준 오류 페이지(`Error code: 404 / Message: File not found. / HTTPStatus.NOT_FOUND`)가 그대로 돌아온다. 즉 S3 정적 호스팅이 아니라 `SimpleHTTPRequestHandler`를 상속해 `/api/start`·`/api/scores` 라우트와 커스텀 응답 헤더를 덧붙인 **단일 파이썬 서버가 정적 Godot 익스포트와 리더보드 API를 동시에** 서비스하는 구성이다(오리진 코드를 확보하지 못했으므로 이 구성 추정은 헤더·오류 페이지·라우팅 조합에서 유도한 추론이다). 그 앞단에 CloudFront가 놓여 TLS 종료, HTTP/2·HTTP/3(`alt-svc: h3`), 엣지 캐싱을 담당한다(`x-amz-cf-pop: ICN80-P1`).

게임과 API가 **같은 origin에** 놓인다는 점이 클라이언트 설계와 정확히 맞물린다. `Ranking.base_url()`이 페이지 URL에서 API 베이스를 유도하므로(§7.2) CORS 설정, 프리플라이트, 자격증명 정책이 전부 불필요해진다.

### 2.2 자산 크기와 캐시 정책

| 경로 | content-type | cache-control | 관측 |
|---|---|---|---|
| `/`, `/index.html` | `text/html` | `no-cache` | `RefreshHit from cloudfront` |
| `/index.js` | `application/javascript` | `max-age=3600` | `Hit`, `age: 1204`; Brotli 적용 시 279,815 → **66,650 B** |
| `/index.wasm` | `application/wasm` | `max-age=3600` | `Hit`, **압축 없이 39,513,091 B** |
| `/index.pck` | `application/octet-stream` | `max-age=3600` | `Hit`, 3,419,732 B, 압축 없음 |
| `/api/*` | `application/json; charset=utf-8` | `no-cache` | 항상 `Miss from cloudfront` |

세 가지가 눈에 띈다. 첫째, `/api/*`가 `no-cache`이므로 리더보드 조회는 엣지에서 캐시되지 않고 항상 오리진까지 간다 — 순위가 항상 최신이지만 파이썬 단일 프로세스가 모든 조회를 직접 받는다. 둘째, HTML만 `no-cache`이고 나머지는 1시간 캐시인데 **파일명에 해시가 없다.** 재배포 시 `index.html`은 즉시 갱신되지만 `index.js`/`index.wasm`/`index.pck`은 최대 1시간의 버전 스큐가 생길 수 있다. 셋째, `Accept-Encoding: gzip, br`을 보내도 **`index.wasm`(`application/wasm`, 39,513,091 B)과 `index.pck`(`application/octet-stream`, 3,419,732 B)은 둘 다 `content-encoding` 없이 원본 크기 그대로 내려온다** — 실측으로 확인했다. 같은 요청에서 `index.js`는 `content-encoding: br`로 66,650 B까지 줄어든다. CloudFront 자동 압축은 오브젝트 크기가 1 KB~10 MB 범위이고 content-type이 압축 대상 목록에 있을 때만 적용되므로, `index.wasm`은 크기 상한에, `index.pck`은 content-type 조건에 각각 걸린다(AWS 문서화된 동작). 결과적으로 콜드 로드 전송량 약 43 MB 가운데 압축 혜택을 받는 것은 로더 스크립트 하나뿐이다.

### 2.3 로더, COOP/COEP, 그리고 죽은 서비스 워커 경로

`index.html`에 인라인된 `GODOT_CONFIG`는 `fileSizes: {index.pck: 3419732, index.wasm: 39513091}`을 담고 있어(index.html:114) 로더가 진행률 바를 그릴 때 총량을 미리 안다. 같은 config의 `canvasResizePolicy: 2`는 캔버스를 창 크기에 적응시키는 모드로 프로젝트의 `canvas_items` 스트레치 설정과 짝을 이루고, `experimentalVK: true`는 모바일 가상 키보드 지원으로 게임오버 화면의 닉네임 `LineEdit`(ui.gd:336-343) 입력에 직접 필요하다. `emscriptenPoolSize: 8`, `godotPoolSize: 4`는 `index.js`의 `EngineConfig` 기본값과 동일하므로 익스포터가 스레드 여부와 무관하게 찍어 넣은 값으로 보인다(추정).

흥미로운 조합은 **스레드가 꺼져 있는데도 cross-origin isolation 헤더를 보낸다**는 점이다. 모든 응답에 `cross-origin-opener-policy: same-origin`과 `cross-origin-embedder-policy: require-corp`가 붙지만, `GODOT_THREADS_ENABLED = false`(index.html:115)이고 로더는 이 값을 그대로 기능 검사에 넘긴다.

```js
const missing = Engine.getMissingFeatures({
	threads: GODOT_THREADS_ENABLED,
});
```
(index.html:165-167) `index.js`의 `Features.getMissingFeatures`는 WebGL2·Fetch·Secure Context는 항상 검사하지만 Cross-Origin Isolation과 `SharedArrayBuffer`는 `if (supportsThreads)` 블록 안에서만 검사한다. 즉 **이 빌드는 cross-origin isolation을 필요로 하지 않는다** — `index.worker.js`가 404인 것도 싱글 스레드 익스포트임을 뒷받침한다. 그럼에도 헤더를 보내는 이유는 세 갈래로 정리된다. (a) Godot 웹 익스포트 문서·템플릿이 권장하는 기본 서버 설정을 그대로 따랐을 가능성(오리진 코드가 없어 추정), (b) 부작용이 사실상 없다 — `require-corp`는 모든 서브리소스가 CORP/CORS를 만족하도록 요구하는 강한 제약이지만 이 사이트의 서브리소스(`index.js`, `index.wasm`, `index.pck`, 오디오 워클릿, 아이콘, `/api/*`)는 **전부 same-origin**이라 자동으로 통과한다(외부 CDN 폰트나 서드파티 스크립트가 없다), (c) 나중에 스레드 활성 빌드로 교체할 때 서버 설정을 손대지 않아도 된다.

필수 기능이 없을 때(`missing.length !== 0`)의 복구 경로도 코드에 있지만 **이 배포에서는 실행되지 않는 죽은 코드**다. 조건은 세 개의 논리곱이다.

```js
if (GODOT_CONFIG['serviceWorker'] && GODOT_CONFIG['ensureCrossOriginIsolationHeaders'] && 'serviceWorker' in navigator) {
```
(index.html:169) 세 조건이 모두 참이면 서비스 워커가 fetch를 가로채 COOP/COEP 헤더를 주입하는 이른바 COI 서비스 워커 기법으로 isolation을 사후에 성립시키려 시도한다. `navigator.serviceWorker.getRegistration()`을 호출해 이미 등록본이 있으면 `Service worker already exists.`로 reject해 무한 새로고침 루프를 막고, 없으면 `engine.installServiceWorker()` 후 `window.location.reload()`를 실행한다. `getRegistration()`이 멈추는 브라우저 버그를 대비해 2000 ms 타이머와 `Promise.race`를 걸어 둔다(index.html:186-188). 그런데 `GODOT_CONFIG`(index.html:114)에는 `serviceWorker` 키 자체가 없어 `undefined`(falsy)이고 `index.service.worker.js`와 `manifest.json`은 모두 404다. 따라서 PWA 없이 익스포트되었으며 `ensureCrossOriginIsolationHeaders: true`는 이 조건절에서만 쓰이므로 실질적으로 무효한 설정이다. WebGL2·Fetch·Secure Context 중 하나라도 없는 브라우저는 폴백 없이 곧바로 실패 안내를 보게 된다: `"Error\nThe following features required to run Godot projects on the Web are missing:\n"` + 누락 항목(index.html:197-198).

정상 경로에서는 `missing.length === 0`이면 진행률 모드로 전환하고 `engine.startGame({onProgress})`를 호출해 `<progress>`를 갱신하며, 완료 시 `setStatusMode('hidden')`이 오버레이 DOM을 제거한다(index.html:200-214). 부팅 순서를 한 줄로 정리하면 다음과 같다.

```
CloudFront → index.html (no-cache)
  → index.js 로더 로드 → getMissingFeatures() 통과
  → engine.startGame() → index.wasm(39.5MB) + index.pck(3.4MB) fetch (진행률은 fileSizes로 추정)
  → GodotFS.init(['/userfs'])가 IDBFS 마운트, FS.syncfs(true)로 IndexedDB → 메모리 FS 복원
  → main.tscn 실행 → Main._ready() → Ranking._ready() → load_local()이 user://save.json 읽기
  → UI.show_title()
```

### 2.4 프로젝트 설정 (`project.binary`)

| 키 | 값 | 의미 |
|---|---|---|
| `application/config/name` | `고라니 피하기` | 창/문서 제목 |
| `application/run/main_scene` | `res://main.tscn` | 유일한 씬 |
| `application/config/features` | `["4.7"]` | 엔진 4.7 계열 |
| `application/config/icon` | `res://icon.png` | 128x128 |
| `application/boot_splash/show_image` | `False` | 부트 스플래시 이미지 없음 |
| `display/window/size/viewport_width` / `_height` | `640` / `960` | 세로 설계 해상도 |
| `display/window/stretch/mode` | `canvas_items` | 해상도 대응을 엔진에 일임 |
| `display/window/handheld/orientation` | `1` | 세로(portrait) |
| `input_devices/pointing/emulate_touch_from_mouse` | `True` | 마우스 드래그가 터치 경로로 유입 |
| `rendering/textures/canvas_textures/default_texture_filter` | `0` | nearest — 픽셀아트 확대 시 블러 없음 |
| `rendering/renderer/rendering_method` (+ `.mobile`) | `gl_compatibility` | 웹/모바일 호환 렌더러 |
| `rendering/2d/snap/snap_2d_transforms_to_pixel` | `True` | 서브픽셀 흔들림 제거 |

UI 코드가 640x960을 하드코딩하고 뷰포트 크기를 한 번도 질의하지 않는다는 사실(§5.5)과 `stretch mode=canvas_items`는 직접 연결된다 — 실제 화면 크기 대응은 전적으로 엔진 스트레치에 위임되어 있다.

---

## 3. 전체 아키텍처

### 3.1 모듈 의존 관계

여덟 개 모듈은 **Main을 서비스 로케이터로 삼는 별 모양(star) 구조**를 이룬다. `Main`이 `Sfx`·`Ranking`·`UI`를 상주 자식으로 보유하고 `Game`을 판마다 만들며, `Game`과 `UI`는 형제 모듈에 직접 접근하지 않고 항상 `main.sfx`, `main.ranking`, `main.ui`를 경유한다(예: game.gd:164 `main.ui.set_score`, game.gd:32 `main.ranking.start_run`, ui.gd:353 `main.ranking.submit`). 시그널은 프로젝트 전체에서 단 하나(`Ranking.submitted`, ranking.gd:5)뿐이고 나머지 모든 통신은 직접 메서드 호출과 필드 접근이다.

```
                        ┌──────────────────────┐
                        │  Main (main.gd)      │  앱 상태 머신 + 서비스 로케이터
                        └──┬────┬────┬─────┬───┘
            생성/보유 ┌─────┘    │    │     └───── 판마다 생성/파괴
                      ▼          ▼    ▼                    ▼
                 ┌────────┐ ┌────────┐ ┌──────┐      ┌──────────┐
                 │  Sfx   │ │Ranking │ │  UI  │◄─────│   Game   │
                 └────────┘ └────────┘ └──┬───┘ set_score  └──┬───┘
                      ▲          ▲        │ show_banner       │
                      │          │        │ float_text        │
                      └──────────┴────────┘                   │
                       main.sfx / main.ranking 경유 접근        │
                                                              │
                     ┌────────────────────────────────────────┼───────────┐
                     ▼                    ▼                   ▼           │
                ┌────────┐          ┌──────────┐        ┌──────────┐      │
                │  Row   │◄────────►│  Player  │        │ThemeDefs │◄─────┘
                └────────┘  log_at  └──────────┘        └──────────┘  static only
                 hazard_hit / is_blocked                      ▲
                 Row.tex() / Row.make_eye_glow() ─────────────┘
                 (정적 헬퍼를 Player·UI가 재사용)      Row·UI도 직접 호출
```

`ThemeDefs`는 인스턴스가 존재하지 않는 순수 정적 데이터 계층이라 누구든 정적 함수로 직접 호출한다 — `theme_for_row`의 호출 지점은 game.gd:42·76·82·344와 ui.gd:252다. 단 `Row`는 `theme_for_row`를 직접 부르지 않고 테마 딕셔너리를 `build()`의 `p_theme` 인자로 전달받으며(row.gd:75, 78, game.gd:76), 대신 `ThemeDefs.difficulty`(row.gd:80), `ambush_p`(row.gd:139), `rush_lane_p`(row.gd:158), `gorani_p`(row.gd:313)를 직접 호출한다. `Row`는 정적 텍스처 캐시 `Row.tex()`와 `Row.make_eye_glow()`를 제공하는데, 이것을 `Player`(player.gd:36, 42-47)와 `UI`(ui.gd:126, 131, 166, 426, 470)가 재사용한다 — 즉 `Row`는 행 로직 모듈이면서 동시에 스프라이트 로딩 유틸리티 역할을 겸한다.

### 3.2 런타임 노드 트리

`Main._ready()`가 조립하고 `Game.setup()`이 확장하는 실제 트리는 다음과 같다. 괄호 안은 `process_mode`이며, 일시정지 동작의 근거가 되므로 명시했다.

```
main.tscn
└── Main  (Node, res://scripts/main.gd)            process_mode = ALWAYS      (main.gd:14)
    ├── Sfx      (Node)                            INHERIT → 사실상 ALWAYS    (main.gd:16-17)
    │   ├── AudioStreamPlayer × 8                  bus="Master", 라운드로빈 풀 (sfx.gd:17-21)
    │   └── AudioStreamPlayer  music               bus="Master", volume_db=-7.0 (sfx.gd:22-25)
    ├── Ranking  (Node)                            INHERIT → 사실상 ALWAYS    (main.gd:18-19)
    │   └── HTTPRequest                            요청마다 생성 → queue_free, timeout=5.0 (ranking.gd:52-67)
    ├── UI       (CanvasLayer, layer = 10)         명시적 ALWAYS              (main.gd:20-23, ui.gd:42)
    │   ├── title_root  (Control)                  배경 + 미니 디오라마 + 캐릭터 5버튼 + 버튼 3개
    │   ├── hud_root    (Control, MOUSE_FILTER_IGNORE)  score_lbl / stage_lbl / best_lbl
    │   ├── over_root   (Control)                  딤 + 패널 + LineEdit + 리더보드 TOP 5
    │   ├── rank_root   (Control)                  딤 + 패널 + 리더보드 TOP 10  (타이틀 위 모달)
    │   └── pause_root  (Control)                  명시적 ALWAYS              (ui.gd:535)
    └── Game     (Node2D)                          명시적 PAUSABLE, 판마다 생성/파괴 (main.gd:39-41)
        ├── world (Node2D)                         position.y = 600 + cam_row*64 (game.gd:60, 131)
        │   ├── CanvasModulate                     color = theme["ambient"]   (game.gd:41-43)
        │   ├── Row × 약 21개                      rows[idx], position.y = -idx*64,
        │   │   │                                  z_index = (2000-idx)*2     (row.gd:81-83)
        │   │   ├── ColorRect                      배경 832x64 + 풀포기/물결/레일/침목/경고등
        │   │   ├── Sprite2D                       나무·바위·부시·sign_deer·warn
        │   │   ├── Node2D holder × N              차량 / 고라니 / 통나무(유빙)
        │   │   │   ├── Sprite2D                   4배 스케일, flip_h = lane_dir < 0
        │   │   │   └── Polygon2D | Sprite2D glow  밤 테마 헤드라이트 / 눈 발광
        │   │   └── Node2D train_node              4량 편성(engine + car×3), visible 토글
        │   └── Player (Node2D)                    z_index = (2000-row)*2 + 1 (player.gd:56)
        │       ├── ColorRect shadow               40x12, alpha 0.22          (player.gd:29-34)
        │       └── Sprite2D sprite                4배 스케일, 2프레임 교체
        │           └── Sprite2D glow × 2          gorani_p / peccy 전용 눈빛 (player.gd:40-47)
        └── snow_layer (CanvasLayer, layer = 5)    겨울 숲에서만 visible      (game.gd:357-369)
            └── ColorRect × 42                     4x4 또는 6x6, 낙하 55~120px/s
```

`z_index` 배치가 페인터 정렬을 만든다. 행은 `(2000 - idx) * 2`, 플레이어는 `(2000 - row) * 2 + 1`이므로 플레이어는 항상 자기 행 배경 바로 위, 그리고 화면상 더 아래쪽(=`idx`가 작은) 행보다는 아래에 그려진다. 결과적으로 아래 행의 나무가 위 행의 플레이어를 가리는 자연스러운 겹침이 나온다.

### 3.3 8개 모듈 요약

| 파일 | 클래스 | 상속 | 줄 수 | 책임 |
|---|---|---|---|---|
| `main.gd` | (없음, `main.tscn`에 첨부) | `Node` | 93 | 앱 루트. 모듈 조립, `"title"/"play"/"paused"/"over"` 4상태 머신, 일시정지, 음소거, 게임오버 시퀀스 |
| `game.gd` | `Game` | `Node2D` | 384 | 게임플레이 코어. 월드 생성/컬링, 카메라 강제 스크롤, 입력 해석, 충돌·사망 판정, 점수·스테이지 진행 |
| `row.gd` | `Row` | `Node2D` | 424 | 한 줄(64px) 지형 조립과 이동 해저드(차량·고라니·통나무·기차)의 스폰·이동·충돌 질의. 정적 텍스처 캐시 제공 |
| `player.gd` | `Player` | `Node2D` | 140 | 아바타 표현. 홉 트윈, 착지 스쿼시, 통나무 위치 상속, 사인별 사망 연출 |
| `ui.gd` | `UI` | `CanvasLayer` | 569 | 5개 화면 전부를 코드로 생성. HUD 갱신, 캐릭터 선택 영속화, 닉네임 등록, 리더보드 렌더링 |
| `ranking.gd` | `Ranking` | `Node` | 108 | `user://save.json` 로컬 저장 + 3개 HTTP 엔드포인트 리더보드 클라이언트 |
| `theme_defs.gd` | `ThemeDefs` | `RefCounted` | 110 | 무상태 정적 데이터. 5개 스테이지 팔레트/가중치/로스터 + 난이도 곡선 4종 |
| `sfx.gd` | `Sfx` | `Node` | 52 | 8보이스 라운드로빈 풀, BGM 루프 런타임 설정, 마스터 버스 뮤트 |

---

## 4. 실행 흐름

### 4.1 앱 상태 머신

`app_state`는 `"title"`, `"play"`, `"paused"`, `"over"` 네 문자열만 갖는다(초기값 `"title"`, main.gd:8). 전이는 아래 다이어그램이 전부다.

```
   (부팅) Main._ready() ──► app_state = "title" ──► ui.show_title()
              │
              ▼
        ┌───────────┐   start_game(char_id)          ┌──────────┐
        │  "title"  │ ─────────────────────────────► │  "play"  │
        └───────────┘   ui.gd:188 "게임 시작"          └──────────┘
              ▲                                        │      ▲
              │                       ESC / P           │      │  ESC / P (main.gd:92-93)
              │                     pause_game()        │      │  또는 "계속하기" (ui.gd:547)
              │                     (main.gd:90-91)     ▼      │
              │                                    ┌────────────┐
              ├───── to_title() ◄───────────────── │  "paused"  │  get_tree().paused = true
              │      ui.gd:549 "타이틀로"            └────────────┘
              │
              │        game.kill_player(cause) → main.on_game_over(...)   ("play"에서만)
              │                                        │  game.gd:313
              │                                        ▼
              │                                   ┌──────────┐
              ├───── to_title() ◄──────────────── │  "over"  │ ── 1.0초 후 ui.show_game_over()
              │      ui.gd:380 "타이틀로"           └──────────┘
              │                                        │
              └────────────────────────────────────────┘
                       retry() → start_game(last_char) ──► "play"
                       ui.gd:377 "다시하기"
```

| 전이 | 함수(위치) | 트리거 |
|---|---|---|
| (부팅) → title | `_ready` (main.gd:8, 25) | 앱 시작 |
| title → play | `start_game` (main.gd:38) | 타이틀 "게임 시작" (ui.gd:188) |
| play → over | `on_game_over` (main.gd:48) | `game.kill_player` → `main.on_game_over(...)` (game.gd:313) |
| over → play | `retry` → `start_game` (main.gd:60-61) | 게임오버 "다시하기" (ui.gd:377) |
| over → title | `to_title` (main.gd:69) | 게임오버 "타이틀로" (ui.gd:380) |
| play → paused | `pause_game` (main.gd:76) | ESC 또는 P (main.gd:90-91) |
| paused → play | `resume` (main.gd:83) | ESC/P (main.gd:92-93) 또는 "계속하기" (ui.gd:547) |
| paused → title | `to_title` (main.gd:69) | 일시정지 메뉴 "타이틀로" (ui.gd:549) |

`pause_game`은 `if app_state != "play": return`(main.gd:74-75), `resume`은 `if app_state != "paused": return`(main.gd:81-82)으로 가드되어 잘못된 상태에서의 전이를 막는다. 화면상 일시정지 버튼은 존재하지 않으며, `pause_game`의 호출 경로는 키보드가 유일하다(전 소스 grep으로 확인: main.gd:91이 유일한 호출부). 따라서 **터치 전용 기기에서는 일시정지에 진입할 방법이 없다**(§8.2).

`"play"`와 `"paused"`의 차이는 `get_tree().paused` 한 줄(main.gd:77, 84)이고, 실제 정지 범위는 §3.2의 `process_mode` 배치가 결정한다. `Game`만 `PAUSABLE`이므로 게임플레이(스크롤·차량·플레이어 입력)가 전부 얼어붙고, `Main`이 `ALWAYS`라 `_unhandled_input`이 계속 살아 있어 ESC/P로 재개할 수 있으며, `UI`가 `ALWAYS`라 일시정지 메뉴 버튼이 반응한다. 만약 main.gd:40에서 `Game`에 `PAUSABLE`을 명시하지 않았다면 부모 `Main`의 `ALWAYS`를 상속해 `get_tree().paused`가 게임을 전혀 멈추지 못했을 것이다(엔진 상속 규칙에 근거한 추론). 또한 `start_game`(main.gd:37)과 `to_title`(main.gd:65)은 진입 시 무조건 `get_tree().paused = false`로 리셋해, 어떤 경로로 오더라도 paused 상태가 새 화면으로 새어 들어가지 않게 한다.

### 4.2 한 판의 생애 — show_title에서 on_game_over까지

**1) 타이틀 (`UI.show_title`, ui.gd:103-212).** `hide_all()`로 기존 화면을 정리하고 `selected_char = int(main.ranking.data["char"])`로 저장된 캐릭터 선택을 복원한다(ui.gd:105). 이 시점까지 네트워크 통신은 전혀 없다 — `Ranking._ready()`는 `load_local()` 한 줄뿐이고 프리페치를 하지 않는다(ranking.gd:15-16).

**2) 시작 (`Main.start_game`, main.gd:32-44).** "게임 시작" 버튼이 `main.start_game(CHARS[selected_char]["id"])`를 호출한다(ui.gd:188). `last_char`를 갱신하고 `_over_token += 1`, 이전 `Game`이 있으면 `queue_free()`, `paused = false`, `app_state = "play"`, 새 `Game.new()`에 `PROCESS_MODE_PAUSABLE`을 지정해 `add_child`, 그리고 `game.setup(self, char_id)`로 월드를 만든 뒤 `ui.show_hud()`와 `sfx.start_music()`을 호출한다.

**3) 월드 구성 (`Game.setup`, game.gd:30-62).** 순서가 의미를 갖는다. ① `main.ranking.start_run()`으로 서버 토큰을 **선요청**한다(game.gd:32) — 판 시작 시각이 토큰에 새겨지므로 서버는 나중에 소요 시간을 검증할 재료를 얻는다(추정). ② `rng.randomize()`로 매 판 무작위 시드를 잡는다(game.gd:33). ③ 웹이면 URL 쿼리 `?s=N`을 읽어 `start_row = clampi(N, 0, 500) * 20`으로 시작 행을 점프한다(game.gd:35-38). ④ `world`와 `CanvasModulate`를 만들고 앰비언트 색을 지정한다. ⑤ 시작 지점 뒤 6줄을 강제 잔디로 깔고 `consec`를 초기화한 뒤 앞으로 15줄을 절차 생성한다(game.gd:45-50) — 초기 월드는 21행. ⑥ `Player`를 정중앙 열(`center_x(4) = 320`)에 배치한다. ⑦ `_setup_snow()`로 눈 레이어를 숨긴 채 만들고 `_apply_stage_visuals(stage_idx, true)`로 테마를 즉시 적용한다.

**4) 프레임 루프 (`Game._process`, game.gd:120-164).** 물리 프레임을 전혀 쓰지 않고 모든 시뮬레이션이 `_process(dt)` 한 곳에서 돈다. 순서는 정확히: `elapsed += dt` → 강제 스크롤 + 카메라 추적으로 `cam_row` 갱신 → `world.position.y` 반영 → 화면 흔들림 → 행 선행 생성 → 후방 행 컬링 → 21행 `step()` → `player.follow_ride(dt)` → 탑승 중 화면 밖 익사 판정 → 현재 행 `hazard_hit` → 화면 하단 이탈(`"scroll"`) 판정 → 눈 갱신 → `main.ui.set_score(score(), max_row)`. 사망 판정에 걸리면 즉시 `return`한다.

**5) 이동 1회.** 입력(`Game._unhandled_input`, game.gd:250-289) → `try_move(dir)`(game.gd:174-205)가 경계·장애물을 검사 → `main.sfx.play("hop", -6.0, 1.0, 0.06)` → `player.hop(dir, to_row, to_x, _resolve_landing)`(0.13초 트윈, 이 동안 `hazard_hit` 면역) → 착지 콜백이 `_resolve_landing()`을 호출(game.gd:207-248) → 강이면 통나무 탐색/익사, 지상이면 열 스냅 + 막힌 칸 회피 + 잔디 매복 격발 → 착지 지점 `hazard_hit` 재검사 → `max_row` 갱신 및 스테이지 전환 → 버퍼된 입력이 있으면 `try_move` 재귀.

**6) 사망 (`Game.kill_player`, game.gd:292-313).** `if state != "play": return`으로 중복을 막고 `state = "dead"`, `player.die(cause)`로 연출을 튼 뒤 사인별 효과음과 화면 흔들림(0.35초)을 재생하고, 마지막에 `main.on_game_over(score(), rows_crossed(), stage_idx, cause)`를 호출한다. 이 호출이 게임플레이에서 앱 계층으로 올라가는 유일한 지점이다.

**7) 게임오버 시퀀스 (`Main.on_game_over`, main.gd:46-58).** ① `app_state = "over"` ② `_over_token += 1` 후 `var token := _over_token`으로 세대 스냅샷 ③ `ranking.record_score(score)`로 로컬 최고기록 갱신 여부(`is_new_best`)를 얻는다 — 갱신되면 그 자리에서 `save_local()`이 디스크에 기록한다(ranking.gd:44-50) ④ `sfx.stop_music()` ⑤ `if cause != "scroll": sfx.play("over", -6.0)` — `"scroll"` 사인일 때는 `kill_player`가 이미 `"over"`를 -4.0 dB로 재생했으므로 중복을 피한다(game.gd:300-301) ⑥ `await get_tree().create_timer(1.0).timeout`으로 1.0초 대기 ⑦ `if token != _over_token or app_state != "over": return`으로 재검증 ⑧ `ui.show_game_over(score, rows, int(ranking.data["best"]), is_new_best, cause, stage_idx)`.

1.0초의 지연 동안 화면에는 여전히 HUD와 죽은 플레이어가 보인다. 사망 연출(효과음, 납작해지는 스쿼시, 화면 흔들림)이 패널에 가려지지 않게 하는 연출 간격이다(의도는 추정).

**8) 서버 제출.** 점수 제출은 `Main`이 아니라 게임오버 패널에서 일어난다. 사용자가 닉네임을 넣고 "랭킹 등록"을 누르면 `main.ranking.submit(nm, score, rows, main.last_char)`가 호출되고(ui.gd:353) 결과는 `submitted` 시그널로 돌아온다(§7.3).

**9) 재시작 또는 복귀.** `retry()`는 단 한 줄 `start_game(last_char)`(main.gd:60-61)로 캐릭터 재선택 없이 같은 캐릭터로 다시 시작한다. `to_title()`(main.gd:63-71)은 토큰 증가 → `paused = false` → `game.queue_free()` 후 `game = null`로 참조까지 정리 → `app_state = "title"` → `sfx.stop_music()` → `ui.show_title()` 순이다. `Game` 노드를 해제하는 주체는 언제나 `Main`이며 `Game`이 스스로 소멸하는 경로는 없다.

---

## 5. 모듈 상세

### 5.1 main.gd — 애플리케이션 루트와 상태 머신

`main.gd`(class 선언 없음, `extends Node`, 93줄)는 `res://main.tscn`의 유일한 노드 "Main"에 붙는 스크립트다. 씬 파일이 이것 하나뿐이므로 이 스크립트의 `_ready`가 사실상 애플리케이션 부트스트랩이다.

#### 상태 변수

| 변수 | 타입/초기값 | 역할 |
|---|---|---|
| `sfx` | `Sfx` | 효과음/BGM 재생기 (main.gd:4) |
| `ranking` | `Ranking` | 로컬 저장 + 서버 랭킹 (main.gd:5) |
| `ui` | `UI` | 모든 화면 (main.gd:6) |
| `game` | `Game = null` | 현재 판. 판마다 새로 생성 (main.gd:7) |
| `app_state` | `:= "title"` | 4값 상태 머신 (main.gd:8) |
| `last_char` | `:= "rabbit"` | 마지막 선택 캐릭터 id, `retry`에 사용 (main.gd:9) |
| `_over_token` | `:= 0` | 세대(generation) 카운터 (main.gd:10) |

#### _ready: 노드 그래프 조립 (main.gd:12-25)

먼저 자기 자신을 `process_mode = Node.PROCESS_MODE_ALWAYS`로 설정하고(main.gd:14) `RenderingServer.set_default_clear_color(Color("1e3524"))`로 전역 클리어 컬러를 지정한다(main.gd:15). 이어서 `Sfx.new()`, `Ranking.new()`, `UI.new()`를 코드로 생성해 자식으로 붙이고(main.gd:16-23), `ui.main = self`로 역참조를 주입하며 UI에만 명시적으로 `PROCESS_MODE_ALWAYS`를 부여한다(main.gd:21-22). `Sfx`와 `Ranking`은 `process_mode`를 건드리지 않으므로 엔진 기본값 `PROCESS_MODE_INHERIT`이며, 부모 Main이 ALWAYS이므로 사실상 항상 동작한다(엔진 기본 동작에 근거한 추론). 마지막으로 `sfx.set_muted(bool(ranking.data["muted"]))`(main.gd:24)로 저장된 음소거 상태를 복원하고 `ui.show_title()`(main.gd:25)로 타이틀을 띄운다. 이 복원이 성립하는 이유는 `add_child(ranking)`(main.gd:19) 시점에 `Ranking._ready`가 실행되어 `load_local()`이 `user://save.json`을 이미 읽어두기 때문이다(ranking.gd:15-16, 25-35).

#### 게임오버 지연과 `_over_token` 세대 카운터가 막는 레이스

`_over_token`이 증가하는 곳은 정확히 세 군데다 — `start_game`(main.gd:34), `on_game_over`(main.gd:49), `to_title`(main.gd:64). `pause_game`(main.gd:73-78)과 `resume`(main.gd:80-85)도 §4.1의 전이 함수이지만 토큰을 건드리지 않는다(파일 전체에서 `_over_token`이 등장하는 줄은 10·34·49·50·56·64뿐이다). 즉 세대가 갱신되는 것은 **판의 시작·종료·이탈 전이뿐이고 일시정지 전이는 세대에 영향을 주지 않는다** — `"over"` 상태에서는 애초에 ESC/P가 무시되므로(main.gd:90-93) 게임오버 대기 중에 pause 전이가 끼어들 여지가 없기 때문이다. 방어 대상은 `await`로 매달린 **오래된(stale) 코루틴의 뒤늦은 재개**다. `on_game_over`의 코루틴은 `Game`이 아니라 `Main`(ALWAYS) 소속이므로 1.0초 대기 중에 `game.queue_free()`가 일어나도 죽지 않고 반드시 재개된다. 만약 그 1초 사이에 `start_game`이나 `to_title`이 실행됐다면 가드 없는 코루틴은 새 판의 HUD 위나 타이틀 화면 위에 게임오버 패널을 덮어씌웠을 것이다. `if token != _over_token or app_state != "over": return`(main.gd:56-57)이 이를 이중으로 차단한다 — 스냅샷한 세대가 현재 세대와 다르면(그 사이 전이 발생) 포기하고, 세대가 같아도 상태가 `"over"`가 아니면 포기한다.

다만 현재 출시된 UI에서 그 1초 창 동안 사용자가 실제로 전이를 일으킬 경로는 발견하지 못했다. HUD의 모든 컨트롤이 `MOUSE_FILTER_IGNORE`이고(ui.gd:229-245) ESC/P도 `"over"` 상태에서는 무시되기 때문이다(main.gd:90-93). 따라서 이 토큰은 심층 방어(defense-in-depth)로 보인다(추정). 한 판 안에서의 이중 호출은 `kill_player`의 state 가드가 상류에서 이미 막는다(game.gd:293).

#### retry / to_title 수명주기

`start_game(char_id)`(main.gd:32-44)은 `if game != null: game.queue_free()`로 이전 판을 지연 해제하는데, 여기서는 `game = null`을 거치지 않고 곧바로 main.gd:39에서 새 `Game.new()`로 재할당한다. `queue_free`는 프레임 말미 해제이므로 옛 `Game`과 새 `Game`이 한 프레임 안에 잠시 공존한다(엔진 semantics에 근거한 추론). 반면 `to_title()`은 해제 후 `game = null`로 참조까지 끊는다(main.gd:66-68).

#### ESC/P 키 처리 (main.gd:87-93)

`_unhandled_input`은 `InputEventKey`이고 `event.pressed`이며 `not event.echo`(키 반복 무시)일 때만 반응한다. 키 판정은 `event.physical_keycode == KEY_ESCAPE or event.physical_keycode == KEY_P`로, `keycode`가 아닌 `physical_keycode`를 쓰므로 키보드 레이아웃과 무관하게 물리 위치 기준으로 동작한다. `"title"`/`"over"`에서는 아무 일도 하지 않는다. `_unhandled_input` 단계이므로 UI Control이 먼저 소비한 입력에는 반응하지 않으며(엔진 입력 전파 순서에 근거한 추론), Main이 ALWAYS라서 트리가 paused여도 입력을 계속 받는다 — 이것이 ESC로 재개가 가능한 이유다.

#### 음소거 경로 (main.gd:27-30)

`set_muted(m)`은 두 갈래로 작동한다. 첫째, `sfx.set_muted(m)`이 `muted` 플래그를 세워 이후의 `play()` 호출을 입구에서 차단하고(sfx.gd:34) 동시에 `AudioServer.set_bus_mute(0, m)`으로 버스 0(Master)을 뮤트해 이미 재생 중인 루프 BGM까지 즉시 침묵시킨다(sfx.gd:50-52). 둘째, `ranking.data["muted"] = m` 후 `ranking.save_local()`로 `user://save.json`에 영속화한다. 토글 진입점은 타이틀 화면의 사운드 버튼으로 `main.set_muted(not main.sfx.muted)`를 호출하며(ui.gd:197), 부팅 시 main.gd:24가 저장값을 복원해 세션 간 유지된다.

#### 클리어 컬러

정확한 값은 `Color("1e3524")` = #1e3524 = RGB(30, 53, 36), 매우 어두운 저채도 숲색이다(main.gd:15). `RenderingServer.set_default_clear_color`는 아무것도 그려지지 않은 픽셀의 배경색을 정한다. 이 게임에는 전체 화면 배경 스프라이트나 `ColorRect`가 따로 없으므로, 행(Row)들이 덮지 않는 모든 영역 — `stretch mode=canvas_items`로 인한 640x960 뷰포트 밖 레터박스 포함 — 이 이 다크 그린으로 채워진다. 잔디/숲 테마의 기본 톤과 맞춘 선택으로 보인다(의도는 추정).

---

### 5.2 game.gd — 게임플레이 코어

`Game`(`extends Node2D`, game.gd:1-2)은 `main.gd`의 `start_game()`이 `Game.new()`로 생성해 `game.setup(self, char_id)`를 호출하면서 기동된다(main.gd:39-42).

#### 좌표계와 타일 메트릭

- `CELL := 64`, `COLS := 9`(game.gd:5-6). 열 중심은 `center_x(col) = col*64 + 64`(game.gd:65-66)이므로 col 0~8의 중심 x는 64~576이고 그리드가 가로 32~608px을 차지한다. 역변환은 `col_of(x) = clampi(round((x-64)/64), 0, 8)`(game.gd:68-69).
- 행 인덱스 `idx`는 **위로 갈수록 증가**하며 Row 노드는 `position = Vector2(0, -idx*CELL)`에 놓인다(row.gd:81). 플레이어의 정지 위치는 `(x, -row*64 - 32)`(player.gd:51-52).
- 카메라는 `world.position.y = CAM_ANCHOR + cam_row * CELL`(`CAM_ANCHOR := 600.0`, game.gd:7, 60, 131). 즉 행 `cam_row`의 바닥선이 화면 y=600에 오도록 월드 전체를 내려서 그린다. 행 `r`의 플레이어 화면 y는 `568 + 64*(cam_row - r)`이다.
- `X_MIN := 34.0`, `X_MAX := 606.0`(game.gd:8-9)은 통나무 탑승 중 허용되는 x 범위로, 그리드 좌우 끝(32/608)에서 2px 안쪽 값이다(경계 여유라는 해석은 추정).

#### 행 컨테이너 전략 — Dictionary 인덱스 + 스폰어헤드/컬비하인드

행 컨테이너는 `var rows := {}` — **정수 행 인덱스를 키로 하는 Dictionary**다(game.gd:15, 77). 객체 재사용 풀은 아니고, 매번 `Row.new()`로 만들고 뒤처진 행은 `queue_free()`로 파괴하는 방식이다.

- **생성(앞)**: 매 프레임 `while gen_next < int(cam_row) + 14: _gen_row()`(game.gd:134-135). 추가로 `try_move()`에서도 목적지보다 한 줄 더(`while gen_next <= to_row + 1`) 보장 생성한다(game.gd:184-185).
- **파괴(뒤)**: `idx < int(cam_row) - 8`인 행을 `queue_free()` 후 `rows.erase(idx)`(game.gd:136-139). 살아있는 창은 대략 `[cam_row-8, cam_row+13]`.
- **시뮬레이션 창**: `range(int(cam_row)-7, int(cam_row)+14)`의 최대 21행만 `step(dt, self)`를 받는다(game.gd:141-143). 창 밖 행은 존재해도 정지 상태다.

`_make_row(idx, kind)`는 바로 아래 행도 도로일 때 `below_is_road`를 넘겨 차선 점선을 그리게 하고(game.gd:74-76 → row.gd:145-149), 테마는 `ThemeDefs.theme_for_row(maxi(idx, 0))`로 조회한다.

#### 행 종류 절차 생성 규칙 (_gen_row / _pick_kind)

`_gen_row()`(game.gd:79-103)는 기본값을 잔디로 두고, `idx >= start_row + 3`(시작 직후 3줄은 안전) **그리고** `idx % 20 != 0`(**모든 스테이지 경계 행은 강제 잔디**)일 때만 위험 행을 추첨한다. 추첨은 `_pick_kind()`가 테마의 `weights{grass, road, river, rail}`로 누적 룰렛을 돌린다(game.gd:105-117; 다섯 스테이지 모두 가중치 합이 1.0이므로 각 값이 곧 1차 확률이다). 후처리 규칙은 다음 네 가지다.

1. `consec["since_grass"] >= 6`이면 강제 잔디 — 잔디 없는 구간은 최대 6줄(game.gd:85-86).
2. 잔디가 이미 3줄 이상 연속인데 또 잔디가 나오면 1회 재추첨(game.gd:90-91). 따라서 이 상황에서 잔디가 다시 나올 확률은 `w_grass²`이다.
3. 철길은 2연속 금지(game.gd:93-94).
4. 강은 테마별 `river_run`(스테이지 순서대로 2/2/2/3/1) 이상 연속 금지(game.gd:95-96).

마지막에 `consec`(직전 종류·연속 수·잔디 이후 경과)를 갱신한다(game.gd:97-102).

#### 카메라 추적과 강제 스크롤("scroll" 사망)

카메라 갱신은 네 줄이 전부다(game.gd:126-131).

```gdscript
var auto := 0.0
if elapsed > 3.0:
	auto = minf(0.1 + float(max_row) * 0.004, 0.62)      # 단위: 행/초
var target := maxf(cam_row, float(max_row) - 3.0)
cam_row = maxf(cam_row + auto * dt, lerpf(cam_row, target, minf(1.0, 4.5 * dt)))
```

- **강제 스크롤**: 시작 3.0초 유예 후부터 `0.1 + 0.004*max_row` 행/초(= 6.4 + 0.256*max_row px/s)로 밀어 올리며 행 130에서 상한 0.62행/초(39.68 px/s)에 도달한다. `max_row`가 절대 행 번호이므로 URL로 스킵하면 압박도 함께 커진다.
- **추적**: 목표는 `max_row - 3`(최고 도달 행보다 3행 아래)이고 계수 `min(1, 4.5*dt)`의 지수 평활(시간상수 약 0.22초)로 따라간다. `maxf` 두 겹 덕에 **`cam_row`는 단조 증가**하므로 뒤로 이동해도 카메라는 절대 되돌아가지 않는다.
- **사망선**: `py = world.position.y + player.position.y > 1000.0`이면 `kill_player("scroll")`(game.gd:159-161). 960px 화면 아래 40px 지점이며, 식을 풀면 `cam_row - player.row > 6.75`일 때 죽는다.

`_update_shake`는 `shake_t`(0.35초)를 감쇠시키며 `world.position.x = rng.randf_range(-1, 1) * 7.0 * (shake_t / 0.35)`로 최대 ±7px 수평 흔들림을 준다(game.gd:166-171). `state != "play"`여도 이 함수만은 계속 돌아 사망 후에도 흔들림이 자연히 감쇠한다(game.gd:121-123).

#### 이동(try_move)과 착지 판정(_resolve_landing)

`try_move(dir)`(game.gd:174-205)의 순서는 다음과 같다. 홉 중이면 `player.input_buffer`에 저장하고 리턴(game.gd:177-179). `to_row < 0`(절대 행 0 아래)은 `bump`로 거부. 좌우 이동은 탑승 중이면 픽셀 단위(`x ± 64`, [34, 606] 밖 거부), 지상이면 열 단위(0~8 밖 거부). 목적지가 잔디이고 `is_blocked(col)`이면 `bump` + `click`(-12 dB, pitch 0.7)(game.gd:199-203). 통과하면 `hop`(-6 dB, pitch jitter 0.06)을 재생하고 `player.hop(..., _resolve_landing)`을 호출한다 — 홉은 0.13초이며 **홉 중에는 `hazard_hit`을 건너뛰므로 사실상 무적**이다(game.gd:151 조건).

`_resolve_landing()`(game.gd:207-248)은 강이면 `log_at(player.x)`(허용 오차 `half + 4`, row.gd:420-424)로 통나무를 찾아 `start_ride`하고 없으면 `kill_player("water")`. 그 외에는 열에 스냅하고, 잔디의 막힌 칸에 내렸으면 오프셋 `[1, -1, 2, -2, 3, -3, 4, -4]` 순서로 가장 가까운 빈 열을 탐색한다(game.gd:223-229). 잔디 착지 시 `r.trigger_ambush(self)`로 고라니 매복을 격발한다(game.gd:231-232). 이후 착지 지점에서 다시 `hazard_hit`을 검사하고, `player.row > max_row`이면 `max_row`를 갱신하고 `ThemeDefs.stage_index(max_row)` 변화 시 `_apply_stage_visuals`를 호출한다(game.gd:238-243). 마지막으로 버퍼된 입력이 있으면 비우고 `try_move(b)`를 재귀 호출한다(game.gd:245-248).

#### 입력 처리

키보드는 `physical_keycode` 기준 화살표/WASD이며 W와 ↑가 전진 `(0, 1)`이다(game.gd:253-258). 터치는 스와이프 상태 머신이다(game.gd:259-289): press에서 시작점·시각을 기록하고 drag는 마지막 위치만 갱신하며, release 시 ① 누른 시간이 **700 ms 초과면 무시**(long-press 배제) ② 끝점은 마지막 drag 위치와 release 위치 중 시작점에서 **더 먼 쪽**을 택함 ③ 변위 길이가 **26.0 px 미만이면 탭으로 간주해 전진** ④ 그 이상이면 지배 축 판정으로 좌/우, 또는 화면 아래 스와이프 = 후진. 프로젝트 설정 `emulate_touch_from_mouse=true` 덕분에 마우스 드래그도 같은 경로를 탄다.

#### 충돌·사망 판정과 cause 문자열

사망 진입점은 `kill_player(cause)` 단일 함수다(game.gd:292-313).

| cause | 판정 위치 | 조건 | SFX / 연출 (game.gd:297-312) |
|---|---|---|---|
| `"car"` | `Row.hazard_hit` (row.gd:409-414) | 비(非)통나무 엔티티와 `\|e.x - px\| < half + 18` | `crash` -2 dB + `horn` -8 dB, shake 0.35 s |
| `"gorani"` | 동일 함수, `e["gorani"]`일 때 | 위와 동일 판정 | `crash` -2 dB + `gorani` pitch 0.8, shake 0.35 s |
| `"train"` | 동일 함수 (row.gd:415-417) | 철길 `rail_phase == "run"`이고 `\|px - train_x\| < train_half + 16` | `crash` 0 dB pitch 0.8, shake 0.35 s |
| `"water"` | 착지 시 통나무 없음(game.gd:218) 또는 탑승 중 x가 [34, 606] 이탈(game.gd:146-148) | — | `splash` -2 dB |
| `"scroll"` | 화면 하단 `py > 1000`(game.gd:159-161) | 강제 스크롤에 밀림 | `over` -4 dB (main.gd:53-54가 중복 재생을 생략) |

`hazard_hit` 검사는 매 프레임 현재 행에 대해(game.gd:151-157), 그리고 착지 순간 한 번 더(game.gd:234-237) 이뤄진다. 물리 엔진은 전혀 쓰이지 않고 **1차원 x축 구간 겹침**만으로 판정된다.

#### 점수와 스테이지 전환

- `score() = max_row - start_row + bonus`, `rows_crossed() = max_row - start_row`(game.gd:315-319). 전진으로 최고 행을 갱신할 때만 점수가 오르며 후진·재방문은 무효다.
- **니어미스 보너스**: 고라니가 같은 행에서 84px(`NEAR_DIST`) 이내로 스쳐 지나간 뒤 화면 밖으로 사라질 때 플레이어가 생존 중이면 `game.on_near_miss(idx)`가 호출되어 `bonus += 2`, `near` 효과음(-4 dB), 금색(`ffd94a`) 부유 텍스트 `"아슬아슬! +2"`를 띄운다(row.gd:365-373, game.gd:321-325).
- **스테이지 전환**: `_apply_stage_visuals`(game.gd:343-355)가 `CanvasModulate.color`를 1.2초 트윈하고 `stage` 효과음(-3 dB)과 배너 `"STAGE %d — %s" % [s_idx + 1, theme["name"]]`를 띄우며, `snow_layer.visible = theme["snow"]`와 `player.set_night(theme["night"])`를 적용한다. `instant = true`는 `setup` 시에만 쓰인다.
- **눈송이**: `_setup_snow`(game.gd:357-369)가 `CanvasLayer`(layer=5)에 42개의 `ColorRect`(3개 중 1개는 4x4, 나머지 6x6, `Color(1,1,1,0.85)`)를 흩뿌리고 각각 낙하 속도 55~120 px/s, 좌우 드리프트 ±25 px/s를 부여한다. `_update_snow`는 y > 970이면 위로 되돌리고 x가 화면 밖이면 반대편으로 감싼다(game.gd:371-384).

#### 결정론과 RNG

시드는 `rng.randomize()` 하나뿐이고(game.gd:33) 외부에서 주입할 방법이 없어 **판마다 비결정적**이다. 행 종류 추첨, 각 행의 내부 배치와 차량 스폰(row.gd:79로 참조 전달), 화면 흔들림(game.gd:169)까지 전부 이 단일 `rng` 인스턴스를 공유하므로, 플레이어 행동(예: `try_move`의 선행 생성)이 난수 소비 순서를 바꿔 이후 난수열에도 영향을 준다. 예외적으로 눈송이 초기화/리스폰만 전역 `randf()` 계열을 쓴다(game.gd:365, 368, 380).

#### URL 쿼리 `?s=N` 스테이지 스킵

웹 빌드에서만 `JavaScriptBridge.eval("new URLSearchParams(location.search).get('s')", true)`로 쿼리를 읽고, 정수로 파싱되면 `start_row = clampi(int(str(v)), 0, 500) * ThemeDefs.ROWS_PER_STAGE`를 적용한다(game.gd:35-38). 상한 500은 스테이지 번호 기준이므로 행 10000까지 점프할 수 있다. 점수는 `max_row - start_row` 기준이라 **점수를 부풀리는 데는 쓸 수 없고**(game.gd:315-319) 난이도·스크롤 압박만 앞당겨진다. 개발용 스테이지 셀렉트로 보인다(용도는 추정).

---

### 5.3 row.gd — 절차적 행 생성과 이동 해저드

`Row`(`extends Node2D`, row.gd:1-2)는 게임 월드의 가로 한 줄(64px 높이, 9칸)을 전부 책임진다. `ColorRect`와 `Sprite2D`를 코드로 생성해 배경·장식·해저드를 조립하며, `game.gd`가 매 프레임 호출하는 `step(dt, game)`으로 해저드를 갱신하고 `hazard_hit` / `log_at` / `is_blocked` 세 질의 함수로 충돌·점유 정보를 외부에 노출한다.

#### 상수와 정적 헬퍼

행 종류는 4가지로 `KIND_GRASS := 0`, `KIND_ROAD := 1`, `KIND_RIVER := 2`, `KIND_RAIL := 3`이 전부다(row.gd:8-11). 기하 상수는 `CELL := 64`, `COLS := 9`(row.gd:6-7), 해저드 상수는 `SPAWN_MARGIN := 280.0`(화면 밖 스폰/제거 여유), `NEAR_DIST := 84.0`(니어미스 판정 거리), `TRAIN_SPEED := 950.0`(row.gd:13-14, 73)이다.

정적 헬퍼는 세 개다. `tex(n)`이 `"res://assets/sprites/%s.png" % n`을 `_tex_cache`에 캐싱하고(row.gd:19-22), `glow_mat()`이 `BLEND_MODE_ADD`짜리 `CanvasItemMaterial`을 싱글턴으로 만들며(row.gd:24-28), `make_eye_glow(parent, at, size)`가 `"glow"` 텍스처(11x11)에 `modulate = Color(1.35, 1.3, 1.05)`를 준 가산 블렌딩 스프라이트를 붙인다(row.gd:31-39). 이 함수들은 `player.gd`(캐릭터 눈 발광, player.gd:36, 42-47)와 `ui.gd`(스프라이트 아이콘)에서도 재사용된다.

`build(p_idx, p_kind, p_theme, p_rng, below_is_road)`는 `diff = ThemeDefs.difficulty(maxi(idx, 0))`를 계산하고(row.gd:80), `position = Vector2(0, -idx * CELL)`로 배치한 뒤 `z_index = clampi((2000 - idx) * 2, -4000, 4000)`을 설정하고(row.gd:81-83) `match kind`로 각 빌더에 분기한다(row.gd:84-88). 공통 배경 `_bg`는 `(-96, -64)`에서 832x64 크기이므로 640px 화면 좌우로 96px씩 넘치게 그려진다(row.gd:101-102) — 화면 밖에서 들어오는 해저드가 배경 없는 영역에 뜨는 것을 막는다.

#### 잔디 행 — `_build_grass` (row.gd:113-141)

배경은 `theme_def["grass"]` 두 색을 `idx % 2`로 번갈아 칠해 줄무늬를 만든다(row.gd:114-115). 그 위에 3~6개의 8x6 풀포기 `ColorRect`를 반대편 색을 `darkened(0.08)`한 색으로 흩뿌리고(row.gd:117-119), 좌우 화면 밖 경계(x = -20, 660)에 `theme_def["trees"][0]` 스프라이트를 ±8px 지터로 세워 `deco_tint`로 물들인다(row.gd:121-124).

`idx > 2`이면 장애물을 놓는다. `n_block = randi_range(0, 3)`개의 칸을 `range(COLS)` 셔플에서 뽑아 `blocked[c] = true`로 점유 표시하고, `theme_def["trees"]` 목록에서 무작위 장식을 고른다. y 오프셋은 `"tree"`/`"pine_snow"`면 `-CELL + 8`, 그 외(bush/rock)는 `-18`이다(row.gd:126-137). 한 잔디 행에서 최대 3칸이 막히므로 9칸 중 **통로는 항상 남는다.**

마지막으로 매복 무장 여부를 굴린다: `ambush_armed = idx > 6 and rng.randf() < ThemeDefs.ambush_p(idx, p_ambush)`, `pending_dir`은 50%로 ±1(row.gd:139-140).

#### 도로 행 — `_build_road`와 차량 스폰

`_build_road(below_is_road)`는 `theme_def["road"]` 색 배경을 깔고, 아래 행도 도로일 때만 y=-3에 26x4 점선을 x=-80부터 64px 간격으로 그린다(row.gd:143-149). 차선 파라미터는 `lane_dir`이 50%로 ±1, `lane_speed = randf_range(speed[0], speed[1]) * diff`, `gap_lo = gap[0] / diff`, `gap_hi = gap[1] / diff`다(row.gd:151-156) — 난이도가 오르면 빨라지고 촘촘해진다.

**러시 차선**: `rush = rng.randf() < ThemeDefs.rush_lane_p(idx)`(row.gd:158). 러시가 되면 `gorani_mult = 1.3`(기본 1.75에서 하향), `lane_speed *= 0.85`, 갭 양끝 `*= 0.75`, 그리고 좌우에 `"sign_deer"` 표지판을 세운다(row.gd:159-165). 즉 **느리지만 고라니가 쏟아지는 차선**이다(고라니 확률 0.8 고정, 아래 참조). 러시 차선에서 배율과 속도를 낮추는 것은 연속 고라니를 피할 시간을 확보하려는 조정으로 보인다(의도는 추정). 초기 `spawn_t = randf_range(0.2, gap_hi)`이고, 빌드 시점에 x∈[60, 580]에 차량 1~2대를 미리 배치한다(row.gd:166-169).

`_spawn_vehicle(at_x, gorani)`(row.gd:175-209)는 스프라이트 이름을 고라니면 `"gorani_0"`, 아니면 `theme_def["cars"]`에서 균등 추첨한다(`_vehicle_name`, row.gd:171-173 — 목록에 같은 항목을 중복 삽입하는 방식으로 가중치를 준다. 예: 노을 국도 `["truck", "car_white", "taxi", "car_red", "truck", "bus"]`에서 truck은 2/6). 스케일 4배, `flip_h = lane_dir < 0`. 충돌 반폭은 `half = sp.texture.get_width() * 2.0`(4배 스케일 폭의 절반)인데 고라니는 `half = 44.0`으로 고정하고 `speed *= gorani_mult`를 적용한다(row.gd:183-187). 밤(`theme_def["night"]`)이면 고라니는 진행 방향 쪽 `(±9.0, -4.5)`에 눈 발광 1개, 일반 차량은 전방 95px짜리 사다리꼴 헤드라이트 `Polygon2D`(색 `Color(1.0, 0.96, 0.35, 0.3)`, 가산 블렌딩)를 단다(row.gd:188-200). 기본 스폰 x는 `lane_dir > 0`이면 `-280`, 아니면 `920`이고(row.gd:201-203) y는 `-CELL * 0.5 = -32`다. 개체는 `{node, x, speed, half, gorani, near, log, anim_t, sp}` 딕셔너리로 `entities`에 들어간다(row.gd:206-209).

#### 도로 스텝과 간격 유지 — `_step_road` (row.gd:300-325)

`spawn_t -= dt`가 0 이하가 되면 `spawn_t = randf_range(gap_lo, gap_hi)`로 재장전하고 스폰을 시도한다. **간격 유지(clearance)**: 진입점(`-280` 또는 `920`)에서 `|e.x - entry| < e.half + 150`인 비통나무 개체가 하나라도 있으면 이번 틱 스폰을 통째로 건너뛴다(row.gd:305-310). 즉 최소 간격은 "차량 반폭 + 150px"이며 건너뛴 스폰은 보상되지 않는다(타이머만 리셋된다). 통과하면 확률에 따라 고라니 경고를 시작하거나 일반 차량을 스폰하고, 차량 스폰 시 **4% 확률**로 `game.sfx_near_row(idx, "horn")` 경적을 울린다(row.gd:317-319).

`_step_entities`(row.gd:351-375)는 모든 개체를 `x += speed * dt`로 이동시킨다. 통나무는 화면 밖에서 반대편으로 랩어라운드하고(`x - half > 800` → `-160 - half`, 역방향은 대칭), 차량·고라니는 중심 320에서 `|x - 320| > 640 + 280 = 920`을 벗어나면 제거 목록에 들어간다. 고라니는 `anim_t`를 누적해 `tex("gorani_%d" % (int(anim_t * 8.0) % 2))`로 **8 Hz 2프레임** 애니메이션을 돌리고, 플레이어가 살아 있고 같은 행이며 `|x - player_x| < 84`이면 `near = true`를 기록한다(row.gd:362-367). 제거 시점에 `gorani and near and player_alive`면 `game.on_near_miss(idx)`를 호출한다(row.gd:371-373).

#### 고라니 해저드 — 두 개의 등장 경로

**(A) 도로 스폰 틱 추첨**(row.gd:313-315):

```gdscript
var p_g := 0.8 if rush else ThemeDefs.gorani_p(idx, float(theme_def["p_gorani"]))
if pending_gorani <= 0.0 and rng.randf() < p_g:
	_begin_gorani_warn(lane_dir, game)
else:
	_spawn_vehicle()
```

`gorani_p(row, base) = min(base * (1 + 0.4 * loop_count(row)), 0.45)`이고 `loop_count(row) = floor(row / 100)`이다(theme_defs.gd:94-99). 예를 들어 밤의 숲 1루프(행 140~159, `floor(140/20) % 5 == 2`)에서는 `0.22 × 1.4 = 0.308`이다(행 120~139는 노을 국도로 `0.11 × 1.4 = 0.154`다). 이 추첨은 `pending_gorani <= 0.0`일 때만 이루어지며, 이미 경고가 진행 중이면 고라니 추첨만 건너뛰고 `else` 분기로 빠져 **일반 차량이 그대로 스폰된다**(4% 경적 판정도 함께 수행된다, row.gd:314-319). 즉 경고 중에 나오지 않는 것은 새 고라니뿐이며, GDScript `and`의 단축 평가 덕에 이때 `rng.randf()`는 소비되지 않는다. 당첨되면 즉시 스폰이 아니라 `_begin_gorani_warn`으로 **0.55초 경고**가 시작된다: `pending_gorani = 0.55`, 진입 방향 쪽 가장자리(x=20 또는 620, y=-70)에 `"warn"` 스프라이트를 3배 스케일로 띄우고 `game.sfx_near_row(idx, "gorani")` 울음소리를 낸다(row.gd:327-331, 342-344). 타이머가 만료되면 경고를 지우고 `_spawn_vehicle(-99999.0, true)`로 화면 밖(±280px)에서 고라니를 발진시킨다(row.gd:320-324). 최종 속도는 `uniform(speed_lo, speed_hi) * diff * gorani_mult`다.

**(B) 잔디 매복(ambush)**: 발동 트리거는 시간이 아니라 **플레이어의 착지**다. `game._resolve_landing`이 잔디 착지 시 `r.trigger_ambush(self)`를 부르고(game.gd:231-232), `trigger_ambush`는 `armed && !done && pending_gorani <= 0`일 때 **1회만**(`ambush_done = true`) `pending_gorani = 0.45`의 0.45초 경고를 건다(row.gd:333-340). 만료 시 `_step_grass`가 `lane_dir = pending_dir`, `lane_speed = 245.0 * (1.0 + diff * 0.18) / 1.75`를 설정하고 고라니를 스폰한다(row.gd:289-297). 스폰 함수 안에서 `gorani_mult = 1.75`가 다시 곱해지므로 1.75는 상쇄되고, **매복 고라니의 실효 속도는 정확히 `245 * (1 + 0.18 * diff)` px/s**다 — diff=1.0에서 289.1, 상한 diff=2.2에서 342.0. 경고 0.45초 + 화면 밖 280px 접근 시간(약 0.8~1.0초)이 플레이어에게 주어지는 전체 반응 시간이다(접근 시간은 속도로부터의 계산상 추정).

텔레그래프에 쓰이는 스프라이트는 셋이다: `"warn"`(도로·매복 공통 경고 아이콘), `"sign_deer"`(러시 차선 상시 표지판), `"glow"`(밤 고라니 눈 발광). `sfx_near_row`는 카메라 행에서 15행 이내일 때만 실제로 소리를 낸다(game.gd:327-331).

한 가지 코드 구조상의 사실: `_step_road`에서 같은 프레임에 경고를 시작(`pending_gorani = 0.55`)한 직후 아래 블록의 `pending_gorani -= dt`가 즉시 실행되므로, 실제 경고 시간이 최대 1프레임만큼 짧아질 수 있다(row.gd:314-321). 의도된 것인지는 알 수 없다.

#### 강 행 — 통나무/유빙과 드리프트 (row.gd:212-237)

`theme_def["river"]` 배경에 상단 3px 어두운 경계선(`darkened(0.25)`)과 2~4개의 20x3 물결 하이라이트(`lightened(0.18)`)를 그린다. `lane_dir`은 ±1 50%, `lane_speed = randf_range(42.0, 80.0) * sqrt(diff)`로 도로와 달리 **스테이지 무관 고정 범위에 √diff 스케일**만 적용된다(row.gd:218-219). 플랫폼 텍스처는 `theme_def["snow"]`가 참이면 `"floe"`(유빙), 아니면 `"log"`다(row.gd:220) — 겨울 숲에서만 유빙이 뜬다.

배치는 스폰 타이머 없이 빌드 시 한 번에 끝난다. x=-160부터 800 미만까지, 각 통나무는 60% 확률로 폭 1.0배 / 40%로 0.65배(`scale_x`)이며 `half = width * 2 * scale_x`(48px 텍스처 기준 96 또는 62.4), 다음 위치는 `x += half * 2 + randf_range(115, 210)`이다(row.gd:222-237). 이후에는 `_step_entities`의 랩어라운드만으로 순환하므로 **통나무 개수와 상대 간격은 그 행이 살아 있는 동안 영구 불변**이고, 115~210px 간격은 그 사이가 항상 물(즉사 구간)임을 뜻한다.

#### 철길 행 — 경고등 텔레그래프와 기차 (row.gd:240-275, 377-403)

`theme_def["rail"]` 배경 위에 y=-44, -20 두 줄의 레일(832x4, `Color("5a5248")`)과 48px 간격 침목(8x38, `Color("6e5a42")`)을 그리고, x=10과 618에 경고등 두 개를 세운다(`_lamp`: 4x18 기둥 `"3a3630"` + 12x10 램프, 소등색 `"7a2020"`, row.gd:277-279). 초기 대기는 `rail_t = randf_range(2.0, 6.5) / diff`, 통과 후 재대기는 `randf_range(3.0, 7.5) / diff`로 난이도가 오르면 기차가 잦아진다(row.gd:252, 400).

기차 편성은 항상 `["train_engine", "train_car", "train_car", "train_car"]` 4량이고 `train_dir < 0`이면 `parts.reverse()`를 적용한다(row.gd:256-258). 각 부품은 4배 스케일에 10px 간격으로 이어 붙이며 `total = Σ(width*4 + 10) - 10`, `train_half = total * 0.5 + 8`이다(row.gd:259-263).

배치 루프는 `cursor`를 `-total * 0.5`에서 시작해 배열 순서대로 오른쪽으로 채우므로(row.gd:264-273) **배열의 첫 원소가 항상 가장 왼쪽**에 온다. 좌표를 끝까지 계산하면 `train_engine`의 로컬 중심 x는 `train_dir > 0`일 때 −303, `train_dir < 0`일 때 +303이다. 두 경우 모두 기관차가 **진행 방향의 반대쪽 끝(트레일링 엔드)**에 놓인다는 뜻이다 — dir>0이면 오른쪽이 선두이므로 최좌측인 기관차가 뒤, dir<0이면 왼쪽이 선두이므로 최우측이 된 기관차가 뒤다. 따라서 `reverse()`의 실제 효과는 기관차를 앞으로 보내는 것이 **아니라**, 뒤집지 않았다면 dir<0에서 선두가 되어 버릴 기관차를 계속 뒤쪽에 유지시켜 편성 방향을 좌우 대칭으로 만드는 것이다. 다만 두 스프라이트를 실제로 디코딩해 보면 `train_engine`(52x22)과 `train_car`(48x22)는 창문 4개와 노란 띠를 가진 거의 좌우대칭인 전동차 그림이고 운전실·노즈 같은 방향 단서가 없어(폭이 4px 넓은 것이 유일한 차이), 여기에 `flip_h = train_dir < 0`로 각 칸이 미러링되기까지 하므로 플레이 중 눈에 보이는 차이는 사실상 없다. 텍스처 실측(train_engine 52px, train_car 48px)을 대입하면 `total = 218 + 202*3 - 10 = 814 px`, `train_half = 415`다. 선언 기본값 `train_half := 410.0`(row.gd:72)은 `_build_rail`이 항상 덮어쓰므로 무의미하며, 두 값이 다른 이유는 소스만으로는 알 수 없다.

상태 기계는 3단계다.

| 페이즈 | 지속 | 동작 |
|---|---|---|
| `"idle"` | `randf_range(2.0, 6.5)/diff` (재대기 `3.0~7.5/diff`) | 만료 시 `"warn"`으로 전환하고 `game.sfx_near_row(idx, "train")` 기적을 울린다 (row.gd:380-384) |
| `"warn"` | 1.25초 | `int(rail_t / 0.16) % 2`로 0.16초마다 두 램프가 **교대로** 점멸(점등 `ff4040`, 소등 `7a2020`; `lamp_a`와 `lamp_b`는 항상 반대 상태). 만료 시 `train_x = -360 - train_half`(dir>0) 또는 `1000 + train_half`에서 출발 (row.gd:385-394) |
| `"run"` | — | `train_x += 950 * train_dir * dt`. `|train_x - 320| > 690 + train_half`가 되면 idle 복귀, 기차 숨김, 램프 소등 (row.gd:395-403) |

기차 속도 950 px/s는 640px 화면을 약 0.67초에 관통한다는 뜻이므로(계산상 추정), 1.25초의 경고음+점멸이 사실상 유일한 회피 단서다.

#### 충돌·점유 질의 API — 외부와의 계약 (row.gd:406-424)

- `is_blocked(col) -> bool`: 잔디 장애물 점유. `game.try_move`가 이동 전 검사해 bump + 클릭음으로 튕겨내고(game.gd:200-203), 착지 보정에서도 막힌 칸이면 인접 빈 칸을 찾아 밀어낸다(game.gd:223-228).
- `hazard_hit(px) -> String`: 비통나무 개체 중 `|e.x - px| < e.half + 18`이면 `"gorani"` 또는 `"car"`, 철길 `"run"` 중 `|px - train_x| < train_half + 16`이면 `"train"`, 아니면 `""`.
- `log_at(px) -> Variant`: `|e.x - px| <= half + 4`인 통나무 개체 딕셔너리 또는 null. 통나무는 `hazard_hit`의 루프에서 `if e["log"]: continue`로 아예 제외되므로(row.gd:411-412) 통나무 자체가 플레이어를 치는 일은 없다. 대신 강 행 착지 시 `log_at`이 null을 반환하면 그 자리에서 `kill_player("water")`이므로(game.gd:214-219), **`half + 4`라는 좁은 허용 폭이 곧 생사의 경계**다 — 통나무 끝을 4px 넘겨 스치면 탑승 대신 익사한다.

역방향 호출(row → game)은 `sfx_near_row(idx, name)`, `player_alive()`, `player_row()`, `player_x()`, `on_near_miss(idx)` 다섯 가지다. 스텝 구동은 game.gd가 카메라 기준 `[int(cam_row)-7, int(cam_row)+14)` 범위의 행에만 `step(dt, self)`를 호출하므로(game.gd:141-143) 화면에서 멀어진 행의 해저드는 완전히 정지한다.

---

### 5.4 player.gd — 아바타, 홉 메커니즘, 사망 연출

`Player`(`extends Node2D`, 140줄)는 `Game.setup()`에서 `Player.new()`로 생성되어 `world`에 붙는다(game.gd:54-59). 이 모듈은 **시그널을 하나도 선언하지 않는다.** 모든 통신은 game.gd가 Player의 메서드를 호출하고 필드를 직접 읽는 방식이며, 유일한 역방향 경로는 `hop()`에 인자로 넘어오는 `on_land: Callable` 콜백이다. 입력 해석과 규칙 판정은 전부 game.gd가 하고 Player는 호출당하는 쪽이다.

#### 상태 변수와 상수

| 이름 | 값/타입 | 의미 |
|---|---|---|
| `CELL` | `64` | 타일 한 칸의 픽셀 크기 (player.gd:5) |
| `HOP_T` | `0.13` | 홉 1회의 지속 시간(초) (player.gd:6) |
| `char_name` | `"rabbit"` 기본 | 스프라이트 이름 접두어 (player.gd:8) |
| `row`, `x` | `0`, `320.0` | 논리 행 인덱스와 픽셀 x 좌표 (player.gd:9-10) |
| `dead`, `hopping` | `false` | 상태 플래그 (player.gd:11-12) |
| `riding` | `null`(무타입) | 탑승 중인 Row 엔티티 Dictionary (player.gd:13) |
| `input_buffer` | `Vector2i.ZERO` | 홉 도중 입력 1개 버퍼 (player.gd:14) |
| `ride_offset` | `0.0` | 통나무 중심 대비 상대 오프셋 (player.gd:109) |

#### 홉 상태 기계와 아크 곡선

상태는 사실상 `hopping` 불리언 하나로 표현된다. `hop()`(player.gd:68-94)의 동작 순서는 다음과 같다. ① `hopping = true`, `riding = null` — 홉 시작 즉시 탑승이 해제되어 공중에서는 통나무에 끌려가지 않는다. ② `face(dir)`로 방향 회전, 그리고 **논리 좌표 `row`/`x`를 출발 시점에 즉시 목적지 값으로 커밋**한다(player.gd:71-74). ③ 텍스처를 `char_name + "_1"`(점프 프레임)으로 교체. ④ 기존 `_hop_tw`가 유효하면 `kill()` 후 새 Tween 생성.

보간은 다음 한 덩어리다(player.gd:82-86).

```gdscript
tw.tween_method(func (t: float):
	var p := from.lerp(to, t)
	p.y -= sin(t * PI) * 22.0
	position = p
, 0.0, 1.0, HOP_T)
```

수평 이동은 출발점→도착점 선형 lerp이고(별도 `set_trans`/`set_ease` 호출이 없으므로 t는 엔진 기본값으로 선형 진행 — 추정), 수직 아크는 `sin(t·π) × 22.0` 픽셀의 반파장 사인 곡선으로 t=0.5에서 최고 높이 22px에 도달한다. 64px 한 칸을 0.13초에 건너므로 평균 속도는 약 492 px/s다.

착지 콜백(player.gd:87-94)은 `hopping = false` → 텍스처 `_0` 복귀 → 스쿼시 연출(`scale`을 `(4.4, 3.4)`로 찍고 0.06초에 걸쳐 `(4, 4)`로 복원) → `on_land.call()` 순이다. `hopping = false`가 스쿼시보다 먼저이므로 **다음 입력은 0.13초 경과 즉시** 받을 수 있다.

#### 입력 버퍼링 — 드롭되지 않는다

버퍼 저장소는 Player에 있지만 로직은 game.gd에 있다. 홉 도중 `try_move()`가 불리면 `player.input_buffer = dir`로 저장하고 리턴하며(game.gd:177-179), 1칸짜리 버퍼라 홉 중 여러 번 누르면 마지막 입력만 남는다. `_resolve_landing()` 말미에서 버퍼가 비어 있지 않으면 비우고 `try_move(b)`를 재귀 호출하므로(game.gd:245-248) 착지 즉시 다음 홉으로 이어진다. 즉 입력은 홉 중에도 버려지지 않고 1개까지 버퍼링된다.

#### 그리드 스냅과 논리→픽셀 매핑

수직축은 `rest_pos()`가 `Vector2(x, -row * CELL - CELL * 0.5)`를 반환한다(player.gd:51-52) — 행 `row`의 발판 y는 `-row*64 - 32`이고 위로 갈수록 row가 커진다. 수평축은 game.gd 소관으로 `center_x(col) = col*64 + 64`, `col_of(x) = clampi(round((x-64)/64), 0, 8)`이다. 초기 스폰은 `center_x(4) = 320`으로 정중앙이며 Player의 기본값 `x := 320.0`과 일치한다.

`x`는 항상 열에 스냅되어 있지는 않다. 통나무 위에서는 자유 부동 좌표이고, 전/후진 홉은 `to_x = player.x`를 유지한다(game.gd:186). 대신 착지 시 강 이외의 행이면 `player.x = center_x(col_of(player.x))`로 재스냅한다(game.gd:229). `sync_position()`은 `position = rest_pos()`와 함께 `z_index = clampi((2000 - row) * 2 + 1, -4000, 4000)`을 설정한다(player.gd:54-56).

`bump(dir)`(player.gd:96-102)는 이동 불가 시의 피드백으로 `Vector2(dir.x, -dir.y) * 10.0`만큼 0.05초 밀렸다가 0.05초에 복귀한다(y 부호 반전은 논리 y와 화면 y가 반대이기 때문). `hopping`이거나 `riding != null`이면 생략된다.

#### 2프레임 스프라이트와 회전 방향 처리

프레임은 `Row.tex(char_name + "_0")`(대기)과 `"_1"`(점프) 두 장뿐이고, 전환은 시간 기반 루프가 아니라 **상태 기반**이다 — 홉 시작에 `_1`, 착지에 `_0`(player.gd:75, 89). (시간 기반 8 Hz 2프레임 애니메이션을 쓰는 것은 차량 고라니 쪽이다, row.gd:363-364.)

방향 표현은 `flip_h`가 아니라 **회전**이다. `face(dir)`(player.gd:58-66)에서 전진(`dir.y > 0`)이 `rotation = 0.0`, 후진이 `PI`, 우측이 `PI * 0.5`, 좌측이 `-PI * 0.5`다. 기본 회전 0이 전진이므로 원본 도트가 위(등 쪽)를 보고 그려져 있다고 추정할 수 있다(텍스처 픽셀 자체는 확인하지 않았다). 스프라이트 스케일은 4배로 16x16 도트가 64px 타일에 맞는다. 그림자는 `(40, 12)` 크기의 반투명 `ColorRect`(alpha 0.22)로 Player의 자식이라 홉 아크를 따라 함께 떠오른다(player.gd:29-34).

#### 캐릭터 선택과 char_id 전달 경로

선택 UI는 ui.gd의 `CHARS` 배열이 정의한다: `rabbit`(토끼), `chick`(병아리), `hedgehog`(고슴도치), `gorani_p`(고라니), `peccy`(페키)(ui.gd:26-31). 선택 인덱스는 `ranking.data["char"]`에 영속화되고(ui.gd:105, 180), 시작 버튼이 `main.start_game(CHARS[selected_char]["id"])`를 호출하면 `main.start_game → game.setup(self, char_id) → player.setup(char_name)`으로 전달된다. `setup()`에서 `gorani_p`는 `(±2.5, -4.5)` 위치·크기 0.7, `peccy`는 `(±8.0, -8.0)`·크기 0.6의 눈빛 글로우 2개를 붙인다(player.gd:40-47). 이 글로우는 `set_night(on)`으로 **가시성만** 토글되며(player.gd:22-25), 스테이지 테마의 `"night"` 플래그에 따라 `game._apply_stage_visuals`가 호출한다(game.gd:354-355). 즉 5종 중 2종만 야간 연출을 갖는다.

#### 강 플랫폼 탑승과 익사 조건

`start_ride`는 엔티티 Dictionary 참조와 `ride_offset = x - ent["x"]`를 저장해(player.gd:111-113) 통나무 중앙으로 스냅하지 않고 **밟은 지점의 상대 오프셋을 유지**한다. 매 프레임 `game._process`가 `player.follow_ride(dt)`를 호출하고(game.gd:145), `riding != null and not hopping`일 때 `x = riding["x"] + ride_offset`으로 위치를 상속한다(player.gd:104-107). 딕셔너리 참조 공유이므로 **드리프트 속도는 통나무 속도 그대로**다. `follow_ride(dt)`의 `dt` 인자는 본문에서 쓰이지 않는데, 과거 버전의 잔재인지는 소스만으로 알 수 없다.

익사 경로는 둘이다. 착지 시 `log_at`이 null이면 즉시(game.gd:218-219), 그리고 탑승 중 표류로 `player.x < 34.0` 또는 `> 606.0`이 되면(game.gd:146-149). 통나무 자체는 화면 밖에서 반대편으로 랩어라운드하지만(row.gd:355-360) 플레이어가 그 경계에 닿으면 먼저 죽는다.

#### 사망 연출 `die(cause)`

`die()`(player.gd:115-140)는 `dead` 가드 후 두 Tween을 모두 kill하고 `hopping = false`, 스케일 리셋을 거쳐 원인별 연출을 튼다.

| cause | 연출 |
|---|---|
| `"water"` | 병렬 트윈으로 0.4초간 스케일 `(1.2, 1.2)` 축소 + 0.45초간 `Color(0.5, 0.7, 1.0, 0.0)`로 푸른 페이드 + y를 14px 가라앉히고 그림자를 숨김 |
| `"scroll"` | 0.3초 알파 페이드아웃. `sprite.rotation`을 리셋하지 않으므로 마지막 홉 방향의 회전이 페이드 중 유지된다(시각적 결과는 실행으로 검증하지 않았다) |
| 그 외(`car`/`gorani`/`train`) | 회전을 0으로 되돌리고 0.09초 만에 `(5.6, 1.1)`로 납작하게 눌리며 `Color(1.0, 0.45, 0.45)` 붉은 틴트 |

효과음과 화면 흔들림, `main.on_game_over` 통지는 전부 game.gd `kill_player`의 몫이다 — **Player는 효과음을 직접 재생하지 않는다.** "hop"조차 `try_move`가 `player.hop()` 직전에 재생한다(game.gd:204).

---

### 5.5 ui.gd — 코드로 조립된 5개 화면

`UI`(`extends CanvasLayer`, `class_name UI`)는 `_ready()`에서 `layer = 10`만 설정한다(ui.gd:41-42). 씬 파일이 없으므로 모든 화면이 `Control.new()`, `Label.new()`, `Button.new()` 등으로 완전히 명령형으로 조립된다. `main.gd`가 `UI.new()`로 생성해 `ui.main = self`로 역참조를 주입하고 `PROCESS_MODE_ALWAYS`로 붙이므로 트리가 일시정지돼도 UI는 동작한다.

#### 상태 변수와 화면 루트

| 변수 | 타입 | 역할 |
|---|---|---|
| `main` | `Node` | Main 역참조(sfx/ranking/화면 전환 호출용) (ui.gd:5) |
| `font_r` / `font_b` / `font_s` | `Font` | Galmuri11 / Galmuri11-Bold / Galmuri9 (ui.gd:7-9) |
| `title_root, hud_root, over_root, rank_root, pause_root` | `Control` | 5개 화면 루트 (ui.gd:11-15) |
| `score_lbl, stage_lbl, best_lbl` | `Label` | HUD 라벨 (ui.gd:17-19) |
| `selected_char` | `int` | 캐릭터 선택 인덱스, 초기값 0 (ui.gd:20) |
| `char_frames` | `Array` | 캐릭터 선택 버튼 목록(테두리 갱신용) (ui.gd:21) |
| `mute_b, submit_b` | `Button` | 음소거 토글 / 랭킹 등록 버튼 (ui.gd:23-24) |

`font_r`(Galmuri11)이 일반 라벨과 닉네임 `LineEdit`(ui.gd:341)에, `font_b`(Galmuri11-Bold)가 `bold=true` 라벨과 모든 버튼(ui.gd:48, 60, 422)에 쓰인다. **`font_s`(Galmuri9)는 로드만 되고 파일 내에서 단 한 번도 사용되지 않는다** (전 소스 grep으로 확인: ui.gd:9의 선언이 유일한 등장이며 다른 히트는 모두 `font_size`다).

존재하는 화면은 정확히 5종 — 타이틀(캐릭터 선택 포함), HUD, 일시정지, 게임오버(닉네임 입력 + 미니 리더보드 포함), 랭킹 모달 — 이다. **별도의 닉네임 화면이나 캐릭터 선택 화면은 없다.** main.gd가 구동하는 공개 API는 `show_title()`, `show_hud()`, `show_game_over(...)`, `show_pause()`, `hide_pause()`이고, `show_ranking()`은 UI 내부(타이틀의 "랭킹 보기" 버튼)에서만 호출된다. game.gd는 `set_score()`, `show_banner()`, `float_text()`를 호출한다.

#### 공용 팩토리 헬퍼

- `lbl(text, size, color, bold, outline)`(ui.gd:45-55): `bold`면 `font_b`, 아니면 `font_r`을 `add_theme_font_override`로 지정하고, `outline > 0`이면 외곽선 색 `Color(0.08, 0.1, 0.08, 0.9)`에 `outline_size`를 설정한다. 기본 가운데 정렬.
- `btn(text, size, cb, bg := Color("2f5a3a"))`(ui.gd:57-84): 글자색 `f4f1e8`(hover/focus는 흰색, pressed는 `cfe9c0`), `"normal"/"hover"/"pressed"/"focus"` 4개 상태 각각에 `StyleBoxFlat`을 만들어 hover는 `bg.lightened(0.12)`, pressed는 `bg.darkened(0.15)`, 모서리 반경 10, 테두리 두께 3(focus만 금색 `ffd94a`, 나머지는 `bg.darkened(0.35)`), content margin 상하 10 / 좌우 18을 준다. 그리고 `pressed` 시그널에 람다를 연결해 **항상 `main.sfx.play("click", -8.0)`을 먼저 재생한 뒤 콜백을 호출한다**(ui.gd:80-83) — 이 팩토리로 만든 모든 버튼은 클릭 SFX가 자동이다.
- `panel_box()`(ui.gd:86-93): 배경 `Color(0.09, 0.14, 0.1, 0.96)`, 모서리 14, 테두리 3 `4a7a52`, content margin 22.
- `full_rect(c)`(ui.gd:95-96)는 `PRESET_FULL_RECT` 앵커 적용, `clear(node)`(ui.gd:98-100)는 유효성 검사 후 `queue_free()`, `hide_all()`(ui.gd:557-569)은 5개 루트를 전부 `clear()`하고 모든 루트·라벨·버튼 참조를 null로 리셋한다.

#### 타이틀 화면과 캐릭터 선택 (ui.gd:103-212)

`hide_all()` 후 `selected_char = int(main.ranking.data["char"])`로 저장된 선택을 복원한다. 배경은 전체 화면 `ColorRect`(`223d28`)이고, 그 위에 장식용 도로 `ColorRect`(`41414b`, (0,250), 640x90)와 차선 점선 8개(`d8d4c0`, `i*84+10` 간격, y=292, 30x5), `Row.tex("car_red")` 4배 확대(430,268), `Row.tex("gorani_0")` 6배 확대(60,226)를 배치해 **미니 디오라마**를 만든다(ui.gd:109-134). 로고 "고라니 피하기"는 62pt 금색(`ffd94a`) 볼드 외곽선 10, y=90에 640폭 가운데 정렬, 부제 "숲속 찻길을 무사히 건너라!"는 24pt `cfe9c0`, y=168이다.

캐릭터 선택은 캐러셀이 아니라 **가로 일렬 5버튼**이다. `HBoxContainer`를 (33, 424)에 574x148로 놓고 separation 6을 준다(ui.gd:150-153) — 110×5 + 6×4 = 574이므로 좌우 여백 33px씩으로 정확히 640폭 중앙에 맞는 수치다. 각 캐릭터마다 `custom_minimum_size 110x140`의 `Button` 홀더를 만들고 4개 상태 모두에 같은 `StyleBoxFlat.duplicate()`(배경 `Color(0.14, 0.22, 0.15, 0.9)`, 모서리 12, 테두리 4 `2a4a30`)를 준다. 내부에는 `Row.tex(id + "_0")` 5배 확대 스프라이트(15,18)와 이름 라벨(19pt, y=104)을 `MOUSE_FILTER_IGNORE`로 얹어 클릭이 홀더 버튼으로 통과되게 한다(ui.gd:165-175). 클릭 시 `main.sfx.play("click", -8.0)` → `selected_char = idx` → **`main.ranking.data["char"] = idx` + `save_local()`로 즉시 영속화** → `_update_char_frames()`(ui.gd:177-183). `_update_char_frames()`는 선택된 버튼의 4개 상태 StyleBox 테두리를 금색 `ffd94a`로, 나머지는 `2a4a30`으로 바꾼다(ui.gd:217-222).

그 아래 버튼 3개: "게임 시작"(34pt, (200,610) 240x70, 기본 녹색) → `main.start_game(...)`, "랭킹 보기"(24pt, (200,700) 240x56, 파랑 `3a5a6a`) → `show_ranking()`, 음소거 토글(20pt, (230,776) 180x46, 회색 `4a4a52`)이다. 하단에 조작 안내 "이동: 화살표·WASD·스와이프  |  탭 = 앞으로"(17pt `8aa886`, y=850)와 "내 최고기록: %d"(20pt 금색, y=884)가 있고, 마지막에 `start.grab_focus()`로 키보드 포커스를 준다.

#### 음소거 토글

`_mute_text()`(ui.gd:214-215)는 `main.sfx.muted`에 따라 `"소리: 끔"` / `"소리: 켬"`을 반환한다. 버튼 콜백은 `main.set_muted(not main.sfx.muted)` 후 `mute_b.text = _mute_text()`로 라벨을 갱신하며(ui.gd:196-199), 영속화는 main 쪽에서 `ranking.data["muted"]`에 저장한다(main.gd:27-30).

#### HUD와 인게임 오버레이

`show_hud()`(ui.gd:225-246)는 `hud_root` 전체를 `MOUSE_FILTER_IGNORE`로 만들어 게임 입력을 가리지 않는다. 구성은 3개 라벨이다: `score_lbl`("0", 52pt 흰색 볼드 외곽선 8, y=18, 640폭 가운데), `stage_lbl`(18pt `cfe9c0` 외곽선 5, y=78), `best_lbl`("최고 %d", 17pt 금색 외곽선 5, 위치 (-16, 20)에 640폭 **오른쪽 정렬** — 즉 우측 16px 여백).

`set_score(s, row)`(ui.gd:248-255)는 game.gd의 프레임 루프에서 **매 프레임 호출**된다(game.gd:164). 점수 텍스트 갱신 후 `ThemeDefs.theme_for_row(maxi(row, 0))`와 `stage_index(...) + 1`로 `"STAGE %d · %s"`를 만들고, `maxi(int(ranking.data["best"]), s)`로 **현재 점수가 저장된 최고기록을 넘는 순간 실시간으로 "최고" 표시가 따라 올라가게** 한다.

`show_banner(text)`(ui.gd:257-290)는 스테이지 전환 배너다(game.gd:351에서 호출). 반투명 `PanelContainer`(배경 `Color(0.08, 0.12, 0.09, 0.55)`, 모서리 8, 금색 테두리 2, 상하 margin 5 / 좌우 18)에 22pt 금색 볼드 라벨을 넣고, `await get_tree().process_frame`으로 한 프레임 기다려 크기가 계산된 뒤 `((640.0 - p.size.x) * 0.5, 108)`로 수동 중앙 배치한다. Tween으로 0.25초 페이드인 → 1.0초 유지 → 0.4초 페이드아웃 → `queue_free`. await 후 `is_instance_valid`/`is_inside_tree` 재검사가 있어 화면 전환 중 크래시를 방지한다(ui.gd:281-282).

`float_text(text, pos, color)`(ui.gd:292-304)는 니어미스 보너스 연출용이다(game.gd:325에서 `"아슬아슬! +2"` 금색으로 호출). 26pt 볼드 외곽선 6 라벨을 `pos + Vector2(-150, 0)`에 300x30으로 놓아 pos 기준 가운데 정렬하고, 병렬 Tween으로 0.9초간 y를 60px 올리며 동시에 알파를 0으로(EASE_IN) 만든 뒤 제거한다.

#### 게임오버 화면과 닉네임 등록 흐름 (ui.gd:307-383)

시그니처는 `show_game_over(score, rows, best, is_new_best, cause, stage_i)`인데 **`stage_i` 매개변수는 본문에서 전혀 사용되지 않는다**(main.gd:58은 `stage_idx`를 전달한다). 검은 딤(`Color(0, 0, 0, 0.55)`) 위에 `panel_box()` 스타일 `PanelContainer`를 (60,150)에 520x660으로 놓고 separation 12의 `VBoxContainer`로 채운다. 내용은 "게임 오버"(44pt `ff8a7a` 볼드) → 사인별 문구(`CAUSE_TEXT`, 미등록 키 폴백 `"여정이 끝났다"`, 21pt) → 점수(64pt 흰색 볼드) → 신기록이면 `"★ 신기록! ★"`(24pt 금색 볼드), 아니면 `"내 최고기록 %d"`(19pt) 순이다.

닉네임 행은 가운데 정렬 `HBoxContainer`에 `LineEdit`(**`max_length = 12`가 유일한 길이 제한**, ui.gd:337)과 "랭킹 등록" 버튼(`6a5a2a` 갈색금색)으로 구성된다. LineEdit는 `ranking.data["nickname"]`으로 미리 채워지고 placeholder는 `"닉네임"`, 최소 크기 230x52, Galmuri11 22pt다. 등록 버튼 콜백(ui.gd:345-354)은 `strip_edges()`로 공백을 정리하고 → **빈 문자열이면 `"무명고라니"`로 대체**(이것이 유일한 내용 검증) → 닉네임을 `ranking.data`에 저장·영속화 → 버튼 비활성화 → 상태 라벨 `"등록 중…"` → `main.ranking.submit(nm, score, rows, main.last_char)` 순이다.

결과 처리는 `main.ranking.submitted` 시그널에 `CONNECT_ONE_SHOT`으로 연결된다(ui.gd:359-371). 성공 시 `rank > 0`이면 `"등록 완료! 현재 %d위"`, 아니면 `"등록 완료!"`를 표시하고 `board["reload"].call()`로 리더보드를 다시 불러온다. 실패 시 `submit_reason == "offline"`이면 `"오프라인이라 랭킹 등록이 안 돼요 (게임은 계속 즐길 수 있어요)"`(버튼은 비활성 유지), 그 외(`"rejected"`)면 `"등록이 거부됐어요 (점수 검증 실패)"`를 띄우고 버튼을 다시 활성화한다. 이 조합에서 나오는 두 가지 실제 결함은 §8.2에서 다룬다.

하단에는 "다시하기"(→`main.retry()`)와 "타이틀로"(→`main.to_title()`) 버튼 2개(각 200x62)가 있고 "다시하기"가 포커스를 받는다.

#### 리더보드 렌더링

`_add_filtered_board(parent, limit, default_filter)`(ui.gd:385-439)는 게임오버(limit=5, 기본 필터 = 방금 플레이한 캐릭터 `main.last_char`)와 랭킹 모달(limit=10, 필터 `""`)에서 공유된다. 필터 탭 바는 "전체" + 5개 캐릭터의 6버튼으로, 각 버튼은 높이 42 최소·`SIZE_EXPAND_FILL`이며 tooltip에 캐릭터 이름을 넣는다. "전체" 탭만 텍스트(볼드 16pt)이고 나머지는 `icon = Row.tex(id + "_0")` + `expand_icon = true`인 스프라이트 아이콘 탭이다(ui.gd:420-427). 선택 탭은 `_update_filter_tabs`(ui.gd:441-446)가 테두리를 금색으로 바꾼다. 탭 클릭 SFX는 예외적으로 `-10.0` dB다(ui.gd:430).

현재 필터는 `var cur := [default_filter]`라는 **1원소 배열을 클로저의 가변 캡처로** 쓴다(ui.gd:387). `load_fn`은 요청 전 `"불러오는 중…"`을 표시한 뒤 `main.ranking.fetch_board(want, cb)`를 호출하며, 콜백에서 `is_instance_valid(list_box)`와 `cur[0] != want` 검사로 **화면 파괴 후 또는 필터 변경 후 도착한 낡은 응답을 폐기**한다(ui.gd:396-403). 실패 시 note는 `"서버 랭킹 연결 실패"`다. 반환값은 `{"list_box", "reload", "get"}` 딕셔너리로, 게임오버 화면이 `reload`를 붙잡아 제출 성공 시 재조회에 쓴다.

`_fill_rank_list(box, list, limit, note)`(ui.gd:450-487)는 기존 자식을 전부 지우고 헤더 `"— 서버 랭킹 TOP %d —"`(18pt `8ab8d8`)와 note(있으면 16pt `c8a888`)를 넣은 뒤 최대 `mini(limit, list.size())`행을 `HBoxContainer`로 그린다. 열 구성은 ① 순위 `"%d."`(19pt, **상위 3위만 금색 `ffd94a`, 나머지 `d8d4c8`**, 최소폭 40) ② 캐릭터 아이콘(`e.get("char", "rabbit")`을 5종 허용 목록과 대조해 없으면 `"rabbit"`으로 폴백 — 서버 데이터 방어, ui.gd:466-468; 32x32 `STRETCH_KEEP_ASPECT_CENTERED`) ③ 이름(19pt `f4f1e8`, 왼쪽 정렬, `SIZE_EXPAND_FILL`) ④ 점수(19pt `cfe9c0`, 오른쪽 정렬, 최소폭 80)다. 목록이 비고 note도 없으면 `"아직 기록이 없어요 — 1등을 노려보세요!"`를 표시한다. **플레이어 본인 행을 하이라이트하는 로직은 존재하지 않는다** — 강조는 상위 3위 순위 숫자 색상뿐이다.

#### 랭킹 모달 (ui.gd:490-528)

`hide_all()`을 부르지 않으므로 타이틀 위에 겹치는 모달이다. 딤(알파 0.6) 위 `panel_box()` 패널을 (70,140)에 500x640으로 놓고, "랭킹"(40pt 금색 볼드) → 필터 보드(TOP 10, 필터 "전체") → "내 최고기록: %d"(20pt `cfe9c0`) → 가운데 정렬 "닫기" 버튼(24pt 파랑, 160x56)으로 구성한다. 닫기 버튼은 `focus_next`/`focus_previous`와 4방향 `focus_neighbor_*`를 **전부 자기 자신 경로로 지정해 포커스 트랩**을 만들고 `grab_focus()`한다(ui.gd:521-528) — 키보드/게임패드 포커스가 모달 뒤 타이틀 버튼으로 새는 것을 막는 장치로 보인다(해석은 추정). 다만 터치·마우스 입력에서 딤 클릭을 차단하는 별도 로직은 없다.

#### 일시정지 (ui.gd:531-555)

`pause_root.process_mode = Node.PROCESS_MODE_ALWAYS`로 설정해 `get_tree().paused = true` 상태에서도 버튼이 동작한다(ui.gd:535). 딤(알파 0.5) 위 (190,380) 위치 260x220 `VBoxContainer`(separation 18)에 "일시정지"(36pt 흰색 볼드), "계속하기"(→`main.resume()`), "타이틀로"(→`main.to_title()`, 파랑)를 쌓고 "계속하기"에 포커스를 준다. `hide_pause()`는 루트를 지우고 null 처리한다.

#### 반응형 레이아웃에 관하여

이 파일에 **뷰포트 크기를 질의하는 코드는 단 한 줄도 없다.** 모든 좌표·크기가 640x960 설계 해상도에 하드코딩돼 있고(640폭 라벨 + 가운데 정렬로 수평 중앙, 배너의 `(640.0 - p.size.x) * 0.5`, 캐릭터 행의 33+574+33=640), 실제 화면 크기 대응은 프로젝트 설정의 `stretch mode=canvas_items`에 전적으로 위임된다. 전체 화면 요소만 `PRESET_FULL_RECT` 앵커를 쓴다.

#### 사용자에게 보이는 한국어 문자열 전체 목록

| 화면 | 문자열 | 위치 |
|---|---|---|
| 타이틀 | "고라니 피하기" / "숲속 찻길을 무사히 건너라!" / "캐릭터 선택" | ui.gd:136, 140, 145 |
| 타이틀 | "토끼", "병아리", "고슴도치", "고라니", "페키" | ui.gd:27-31 (게임오버·랭킹 탭 tooltip에도 사용) |
| 타이틀 | "게임 시작" / "랭킹 보기" / "소리: 끔"·"소리: 켬" | ui.gd:188, 192, 215 |
| 타이틀 | "이동: 화살표·WASD·스와이프  \|  탭 = 앞으로" / "내 최고기록: %d" | ui.gd:204, 208 |
| HUD | "최고 %d" / "STAGE %d · %s" | ui.gd:241·255, 253 |
| HUD(외부 유입) | "STAGE %d — %s" 배너, "아슬아슬! +2" 부유 텍스트 | game.gd:351, game.gd:325 |
| 게임오버 | "게임 오버" / "여정이 끝났다"(폴백) / "★ 신기록! ★" / "내 최고기록 %d" | ui.gd:324, 325, 328, 330 |
| 게임오버(사인) | "차에 치이고 말았다…", "고라니와 정면충돌!", "기차는 못 이겨요…", "풍덩! 물에 빠졌다", "어둠에 삼켜졌다…" | ui.gd:34-38 |
| 게임오버 | "닉네임"(placeholder) / "랭킹 등록" / "무명고라니" / "등록 중…" | ui.gd:339, 345, 348, 352 |
| 게임오버 | "등록 완료! 현재 %d위" / "등록 완료!" / "오프라인이라 랭킹 등록이 안 돼요 (게임은 계속 즐길 수 있어요)" / "등록이 거부됐어요 (점수 검증 실패)" | ui.gd:363, 366, 368 |
| 게임오버 | "다시하기" / "타이틀로" | ui.gd:377, 380 |
| 보드(공용) | "전체" / "불러오는 중…" / "서버 랭킹 연결 실패" / "— 서버 랭킹 TOP %d —" / "아직 기록이 없어요 — 1등을 노려보세요!" | ui.gd:404·421, 398, 402, 453, 487 |
| 랭킹 모달 | "랭킹" / "내 최고기록: %d" / "닫기" | ui.gd:507, 510, 511 |
| 일시정지 | "일시정지" / "계속하기" / "타이틀로" | ui.gd:546, 547, 549 |

#### UI 팔레트 핵심 값

| 색 | 용도 |
|---|---|
| `ffd94a` | 금색 — 로고, 강조, 포커스 테두리, 선택 탭, 배너 텍스트, 니어미스 텍스트 |
| `2f5a3a` | 기본 버튼 배경 (ui.gd:57) |
| `3a5a6a` | 보조 버튼 배경(랭킹 보기·타이틀로·닫기) |
| `4a4a52` / `6a5a2a` | 음소거 토글 / 랭킹 등록 버튼 |
| `f4f1e8` | 버튼 글자색 |
| `223d28` | 타이틀 배경 |
| `ff8a7a` | 게임오버 제목 |
| `cfe9c0` / `a8c8a0` / `8aa886` | 보조 텍스트 3단 톤 |
| 딤 알파 | 게임오버 0.55 / 랭킹 0.6 / 일시정지 0.5 |

---

### 5.6 ranking.gd — 로컬 세이브와 리더보드 클라이언트

`Ranking`(`extends Node`, `class_name Ranking`, ranking.gd:1-2)은 화면 요소를 전혀 만들지 않는 순수 로직 노드다. `Main._ready()`에서 단 한 번 생성되며(main.gd:18-19) 이후 게임 전체가 `main.ranking.…` 형태로 접근하는 사실상의 싱글턴이다. 보유 상태는 다섯 개다.

| 변수 | 선언 | 용도 |
|---|---|---|
| `data` | ranking.gd:9 | 로컬 영속 딕셔너리 (`nickname`, `best`, `muted`, `char`) |
| `server_ok` | ranking.gd:10 | 마지막 서버 통신 성공 여부 플래그 |
| `top` | ranking.gd:11 | POST 성공 시 서버가 돌려준 `scores` 배열 캐시 |
| `token` | ranking.gd:12 | 현재 런(run)의 제출 티켓 |
| `submit_reason` | ranking.gd:13 | 제출 실패 사유 (`"offline"` / `"rejected"` / `""`) |

이 중 두 개는 실질적으로 죽은 필드다. `server_ok`는 ranking.gd:84, 87, 101에서 쓰이기만 하고 프로젝트 전체에서 읽는 코드가 없다(전 소스 grep 확인: 참조는 ranking.gd 내부 4곳뿐). `top`도 ranking.gd:102에서 채운 뒤 :104의 시그널 인자로만 전달되는데, 유일한 수신자인 UI는 그 인자를 `_list`로 받아 무시하고 별도 GET을 다시 던진다(ui.gd:359, 364). 즉 `top`은 캐시로 활용되지 않는다.

`_ready()`는 `load_local()` 한 줄뿐이다(ranking.gd:15-16). 네트워크 프리페치를 하지 않으므로 타이틀 화면 진입 시점에는 서버 통신이 전혀 없고, 첫 통신은 사용자가 "게임 시작" 또는 "랭킹 보기"를 눌렀을 때 발생한다.

#### 로컬 저장 — `load_local` / `save_local`

`load_local()`(ranking.gd:25-35)은 방어적으로 작성되어 있다. 파일이 없으면 즉시 반환, `FileAccess.open`이 `null`이면 반환, `JSON.parse_string` 결과가 `Dictionary`가 아니면 아무것도 하지 않는다. 병합 로직이 `for k in data.keys(): if parsed.has(k)`(ranking.gd:33-34) 형태의 **화이트리스트**라는 점이 중요하다 — 저장 파일에 낯선 키가 있어도 무시되고 빠진 키는 기본값을 유지하므로 스키마 추가에 대해 전방 호환이다. 반면 **타입 검증은 없다.** `parsed[k]`를 그대로 대입하므로 JSON 숫자는 Godot에서 `float`로 들어오고, 그래서 소비 지점마다 `int(...)` / `bool(...)` 캐스팅이 강제된다(main.gd:24, main.gd:58, ui.gd:105, ui.gd:254 등). 실질 리스크는 `data["best"]`에 Dictionary/Array 같은 값이 주입되는 경우인데, 이때는 `int()` 캐스팅이 런타임 에러를 낸다(추정).

`save_local()`(ranking.gd:37-42)은 `FileAccess.open(..., WRITE)` → `store_string(JSON.stringify(data))` → **명시적 `f.close()`** 순이다. 웹에서 이 `close()`가 결정적으로 중요하다. Godot 웹 빌드는 `user://`를 Emscripten FS의 `/userfs` 마운트에 매핑하고 이 마운트는 IDBFS다(`index.js`의 `GodotFS.init` → `FS.mount(IDBFS, {}, path)`, `persistentPaths: ['/userfs']`). 이 마운트는 `autoPersist` 옵션 없이 붙으므로 메모리 FS 쓰기만으로는 IndexedDB에 반영되지 않고 `GodotFS.sync()` → `FS.syncfs(false, …)`가 호출되어야 실제로 커밋된다. 엔진이 쓰기 모드 파일 close 시 이 sync를 트리거하는 구조이므로(Godot의 웹 파일 접근 콜백 — 엔진 소스가 없어 추정), `close()`를 생략하면 IndexedDB 반영이 지연되거나 누락될 수 있다. 부팅 시에는 반대 방향으로 `FS.syncfs(true, …)`가 IndexedDB → 메모리 FS를 채우며, 실패하면 `IndexedDB not available:`을 출력하고 `GodotFS._idbfs = false`가 되어 **저장이 조용히 세션 한정으로 격하된다.** IDBFS는 `DB_VERSION: 21`, 스토어 이름 `"FILE_DATA"`를 쓴다.

저장이 트리거되는 지점은 정확히 네 곳이다: 음소거 토글(main.gd:30), 캐릭터 선택(ui.gd:181), 닉네임 확정(ui.gd:350), 신기록 갱신(ranking.gd:48). 주기적 flush는 없다.

#### `record_score` — 최고 기록 로직

```gdscript
func record_score(score: int) -> bool:
	if score > int(data["best"]):
		data["best"] = score
		save_local()
		return true
	return false
```
(ranking.gd:44-50) 동점은 신기록이 아니며(`>`), 반환값이 그대로 "신기록" 연출 플래그가 된다. 호출자는 `Main.on_game_over`뿐이다(main.gd:51). `record_score`가 UI 표시보다 먼저 실행되므로 `show_game_over`에 넘어가는 `best`는 이미 이번 점수로 갱신된 값이고, 그래서 UI는 신기록일 때 `"★ 신기록! ★"`만 띄우고 `best` 숫자는 표시하지 않는다(ui.gd:327-330). 최고 기록은 **서버로 전송되지 않으며**(POST 바디에 `best` 없음) 순수 로컬 표시용이다.

#### `base_url()` — JavaScriptBridge로 API origin 유도

```gdscript
func base_url() -> String:
	if OS.has_feature("web"):
		var v = JavaScriptBridge.eval("location.origin + location.pathname.replace(/[^/]*$/, '')", true)
		if v is String and v.begins_with("http"):
			return v
	return "http://127.0.0.1:8000/"
```
(ranking.gd:18-23) JS 정규식 `/[^/]*$/`는 경로의 마지막 세그먼트(파일명)를 지우므로 `https://host/index.html` → `https://host/`, `https://host/game/index.html` → `https://host/game/`가 된다. 결과가 항상 `/`로 끝나기 때문에 호출부는 `base_url() + "api/start"`처럼 슬래시 없이 이어 붙인다(ranking.gd:72, 79, 98). 이 설계의 효과는 **API를 페이지 상대 경로로 고정**하는 것이다 — 게임이 서브패스에 배포되면 API도 그 서브패스 아래를 자동으로 가리키고, 항상 same-origin이므로 CORS 프리플라이트가 발생하지 않는다(POST가 `Content-Type: application/json`을 붙이므로 cross-origin이라면 프리플라이트가 필요해진다).

`eval`의 두 번째 인자 `true`는 전역 실행 컨텍스트에서 평가하라는 뜻이다. 반환값이 String이 아니거나 `http`로 시작하지 않으면(예: `file://`로 열었을 때 `location.origin`이 `"null"`) 폴백 `http://127.0.0.1:8000/`을 쓴다. 이 포트는 Python `http.server`의 기본 포트이자 실제 프로덕션 오리진이 `SimpleHTTP/0.6 Python/3.9.25`인 것과 일치하므로, 개발 시 같은 스크립트를 로컬에서 띄워 쓰는 흐름으로 보인다(추정). 데스크톱/에디터 실행에서는 `OS.has_feature("web")`이 false라 항상 이 폴백이 쓰인다. HTTPS 페이지에서 폴백이 선택되면 mixed content로 차단되어 결과적으로 `"offline"` 경로로 떨어진다(추정).

#### `_request()` — 공통 HTTP 래퍼

요청마다 `HTTPRequest` 노드를 새로 만들어 `Ranking`의 자식으로 붙이고 `hr.timeout = 5.0`을 준 뒤, 콜백 안에서 `hr.queue_free()`로 회수한다(ranking.gd:52-67). 성공 판정은 매우 좁다.

```gdscript
var payload = null
if result == HTTPRequest.RESULT_SUCCESS and code == 200:
	payload = JSON.parse_string(raw.get_string_from_utf8())
cb.call(payload)
```
(ranking.gd:56-60) 즉 **HTTP 200 이외의 모든 응답(3xx/4xx/5xx)과 모든 전송 실패·5초 타임아웃이 동일하게 `payload = null`로 축약**된다. 응답 헤더는 `_h`로 받아 버리고 재시도·백오프도 없다. 요청 헤더는 GET/POST 구분 없이 `PackedStringArray(["Content-Type: application/json"])` 하나뿐이며 인증 헤더나 쿠키는 없다. `hr.request()`가 즉시 에러를 반환하면 콜백을 직접 `null`로 호출하고 노드를 해제해 콜백 계약을 지킨다(ranking.gd:64-67).

웹에서 `HTTPRequest`는 `index.js`의 `GodotFetch.create`가 `fetch(url, {method, headers, body})`로 구현하므로 실제 네트워크 레벨에서는 브라우저 fetch가 나간다. `Ranking`은 `process_mode`를 지정하지 않아 부모 Main의 `PROCESS_MODE_ALWAYS`를 상속하며, 따라서 `get_tree().paused = true` 상태에서도 진행 중인 요청 폴링이 계속된다.

#### `submitted(ok, rank, list)` 시그널과 소비자

선언은 `signal submitted(ok: bool, rank: int, list: Array)`(ranking.gd:5)이고 emit 지점은 세 곳 — 오프라인 즉시 실패(:95), 서버 성공(:104), 서버 거부(:107) — 이다. 수신자는 프로젝트 전체에서 단 하나, 게임오버 패널이 `CONNECT_ONE_SHOT`으로 붙이는 람다다(ui.gd:359-371). `submit_reason`이 존재하는 이유는 명확하다 — 시그널의 `ok = false` 하나로는 "네트워크가 없어서 못 보냈다"와 "서버가 거절했다"를 구분할 수 없으므로, 문자열 사이드 채널로 사용자 문구와 버튼 재활성화 여부를 분기한다. `rank`는 성공 시에만 의미가 있고 `rank > 0`일 때만 등수를 문구에 넣는다(서버가 `rank`를 안 주면 `-1`이 되어 "등록 완료!"만 표시). 성공 시 `list` 인자는 쓰지 않고 `board["reload"]`로 GET을 한 번 더 보내 목록을 새로 그리므로, **성공적인 제출 1회는 POST 1개 + GET 1개의 트래픽을 만든다.**

---

### 5.7 theme_defs.gd + sfx.gd — 데이터 계층과 오디오 계층

#### ThemeDefs: 무상태 정적 데이터

`ThemeDefs`는 `RefCounted`를 상속하지만 인스턴스 상태가 전혀 없고 모든 멤버가 `static func`이다(theme_defs.gd:1-2). 제공하는 것은 스테이지 데이터(`stages()`)와 난이도 수식 4종(`difficulty`, `gorani_p`, `rush_lane_p`, `ambush_p`), 그리고 조회 헬퍼(`theme_for_row`, `stage_index`, `loop_count`)뿐이다. 유일한 상수는 `const ROWS_PER_STAGE := 20`(theme_defs.gd:5)이다.

한 가지 구현상의 사실: `stages()`는 **호출할 때마다 5개 Dictionary 배열을 새로 생성해 반환한다**(theme_defs.gd:7-79). 그리고 `theme_for_row`, `loop_count`가 매번 `stages()`를 호출하므로(theme_defs.gd:82, 95), 행 생성 시마다, HUD 갱신 시마다(즉 `set_score`를 통해 **매 프레임**, ui.gd:252) 5개 스테이지 딕셔너리 전체가 새로 할당된다. 캐싱은 없다.

각 스테이지 딕셔너리의 필드와 소비처는 다음과 같다.

| 필드 | 소비처 |
|---|---|
| `name` | HUD 스테이지 라벨(ui.gd:253), 전환 배너(game.gd:351) |
| `grass`(2색), `road`, `line`, `river`, `rail` | 각 행 빌더의 배경·차선·레일 색(row.gd:114-115, 144, 149, 213-217, 241) |
| `ambient` | `CanvasModulate.color`, 1.2초 트윈(game.gd:42, 346, 349) |
| `deco_tint` | 잔디 장식 스프라이트 `modulate`(row.gd:124, 137) |
| `night` | 차량 헤드라이트·고라니 눈빛(row.gd:188-191), 플레이어 야간 글로우(game.gd:355) |
| `snow` | 눈 파티클 레이어 표시(game.gd:353), 통나무→유빙 교체(row.gd:220) |
| `weights` | 행 종류 룰렛(game.gd:105-117) |
| `river_run` | 강 연속 상한(game.gd:95-96) |
| `trees` | 잔디 장식 풀(row.gd:121, 134) |
| `cars` | 차량 로스터 추첨(row.gd:171-173) |
| `speed`, `gap` | 차선 속도·스폰 간격(row.gd:152-156) |
| `p_gorani`, `p_ambush` | 고라니/매복 확률의 base(row.gd:313, 139) |

스테이지별 실제 값 전체는 §6.1의 비교표에 정리했다.

#### 20행 스테이지와 무한 루프 구조

- `theme_for_row(row)`는 `idx := int(floor(float(row) / ROWS_PER_STAGE)) % s.size()`로 테마를 고른다(theme_defs.gd:81-84). 행 0–19는 stage 0, 20–39는 stage 1, …, 80–99는 stage 4, 그리고 행 100부터 다시 stage 0으로 **무한 순환**한다.
- `stage_index(row)`는 모듈로 없이 `floor(row / 20)`을 그대로 반환하므로(theme_defs.gd:86-87) 계속 증가한다. UI가 이 값에 +1을 해서 표시하기 때문에(ui.gd:253) **2바퀴째의 숲속 도로는 "STAGE 6 · 숲속 도로"로 표시**된다.
- `loop_count(row) = floor(row / (ROWS_PER_STAGE * stages().size())) = floor(row / 100)`(theme_defs.gd:94-95)으로, 5개 스테이지를 몇 바퀴 돌았는지를 뜻하며 아래 확률 곡선들의 배율 입력이 된다.
- 스테이지 경계 행(`idx % 20 == 0`)은 game.gd가 강제로 잔디로 만들어(game.gd:84) 테마 전환 지점에 안전지대를 보장한다.

#### Sfx: 8보이스 라운드로빈 풀

`Sfx`(`extends Node`, `class_name Sfx`)는 `_ready()`에서 `NAMES`의 11개 이름을 `"res://assets/audio/%s.wav" % n` 경로로 로드해 `streams` Dictionary에 캐시하고(sfx.gd:13-16), `for i in 8` 루프로 `AudioStreamPlayer` 8개를 만들어 `bus = "Master"`로 `pool`에 넣는다(sfx.gd:17-21).

```gdscript
const NAMES := ["hop", "crash", "horn", "splash", "train", "gorani", "stage", "near", "over", "click", "bgm"]
```
(sfx.gd:11)

`play()`는 `pool[pool_i]`를 꺼내 `pool_i = (pool_i + 1) % pool.size()`로 커서를 전진시키는 순수 라운드로빈이다(sfx.gd:36-37). 이 풀이 필요한 이유는 Godot의 `AudioStreamPlayer` 하나가 재생 중일 때 다시 `play()`하거나 `stream`을 갈아끼우면 기존 소리가 끊기기 때문이다. 이 게임은 한 프레임에 효과음이 겹치는 상황이 흔하다 — 고라니 충돌 시 `"crash"` + `"gorani"`(game.gd:303-304), 차량 충돌 시 `"crash"` + `"horn"`(game.gd:310-311), 거기에 근접 경고음(`sfx_near_row`)까지 겹친다. 8보이스면 동시 8개까지 무손실 중첩되고, 9번째부터는 가장 오래된 보이스를 빼앗는(voice stealing) 동작이 라운드로빈으로 자연히 구현된다.

#### BGM 루프를 코드에서 설정하는 이유

`_ready()` 말미에서 전용 `music` 플레이어(`volume_db = -7.0`)를 만들고 `streams["bgm"]`을 `AudioStreamWAV`로 받아 다음을 런타임에 설정한다(sfx.gd:26-31).

```gdscript
var bgm: AudioStreamWAV = streams["bgm"]
bgm.loop_mode = AudioStreamWAV.LOOP_FORWARD
bgm.loop_begin = 0
bgm.loop_end = int(round(bgm.get_length() * bgm.mix_rate))
music.stream = bgm
```

`loop_begin` / `loop_end`는 초가 아니라 **샘플 프레임 인덱스**이므로, 초 단위 길이(`get_length()`)에 샘플레이트(`mix_rate`)를 곱해 마지막 프레임을 계산한다. 이렇게 하면 WAV 파일 전체가 심리스 루프 구간이 된다. Godot에서 WAV 루프는 원래 임포트 옵션으로 설정하는 것이 정석인데, 추출된 `bgm.wav.import` 스텁에는 `[remap]` 섹션(importer="wav", type="AudioStreamWAV", uid, .sample 경로)만 있고 루프 파라미터가 없으며 WAV 임포트 기본값은 루프 꺼짐이다. 코드에서 강제 설정하면 임포트 메타데이터 상태와 무관하게 루프가 보장된다 — 임포트 설정을 만지지 않고 코드만으로 확실히 하려는 방어적 처리로 추정된다(실제 `.sample` 바이너리에 루프 메타데이터가 구워졌는지는 파싱해 확인하지 않았다). 나머지 10개 효과음은 루프 설정 없이 원샷으로 재생된다.

#### play() 시그니처와 피치 지터

```gdscript
func play(n: String, vol_db := 0.0, pitch := 1.0, jitter := 0.0) -> void
```
(sfx.gd:33) `muted`이거나 미등록 이름이면 즉시 반환한다 — 스트림 할당조차 하지 않는다(sfx.gd:34-35). 핵심은 `p.pitch_scale = pitch + randf_range(-jitter, jitter)`(sfx.gd:40)로, 호출마다 피치를 ±jitter 범위에서 무작위로 흔든다. 실제 사용처를 보면 점프음은 `play("hop", -6.0, 1.0, 0.06)`(game.gd:204)으로 매 점프마다 피치가 0.94~1.06 사이에서 달라지고, 근접 경고음은 jitter 0.05(game.gd:331)다. 점프는 게임에서 가장 자주 발생하는 이벤트이므로 동일 샘플의 기계적 반복이 주는 청각 피로를 미세 피치 변조로 회피하는 표준 기법이다. 반면 단발성 소리는 jitter 없이 고정 피치를 쓰되 일부는 톤 변경용으로 pitch 자체를 낮춘다(`play("gorani", 0.0, 0.8)` game.gd:304, `play("click", -12.0, 0.7)` game.gd:202).

#### 뮤트 2단 구조와 BGM의 "이어듣기"

`set_muted(m)`은 두 겹으로 동작한다(sfx.gd:50-52): ① 내부 `muted` 플래그를 세워 이후의 `play()` 호출을 입구에서 차단, ② `AudioServer.set_bus_mute(0, m)`으로 버스 인덱스 0(Master — 풀과 music 모두 이 버스)을 뮤트. BGM은 `start_music()`이 `muted`를 검사하지 않으므로(sfx.gd:43-45) 뮤트 중에도 계속 "재생 상태"이며 버스 뮤트로만 소리가 죽는다 — 덕분에 뮤트 해제 시 BGM이 진행 중이던 위치에서 즉시 들린다(동작상 사실이며, 이것이 의도된 설계인지는 추정). 버스 인덱스 0이 Master라는 것은 Godot 기본 버스 레이아웃 가정이다(커스텀 `default_bus_layout.tres`의 존재 여부는 확인하지 않았다).

#### 에셋 인벤토리 — 30 스프라이트, 11 사운드

`.godot/imported/`의 `.ctex` 30개를 역할별로 분류하면 다음과 같다(크기는 `.ctex` 헤더 실측).

| 그룹 | 파일 (크기 px) | 소비처 근거 |
|---|---|---|
| 플레이어 캐릭터 (5종 × 2프레임 = 10) | `rabbit_0/1`, `chick_0/1`, `hedgehog_0/1`, `gorani_p_0/1`, `peccy_0/1` (모두 16x16) | `CHARS` 목록(ui.gd:26-31), `player.setup`(player.gd:36) |
| 적 고라니 (2프레임) | `gorani_0/1` (27x18) | 차선 스폰 `"gorani_0"`(row.gd:177), 8 Hz 교체(row.gd:364) |
| 차량 (8) | `car_red`, `car_blue`, `car_white`, `taxi` (28x14), `truck` (42x16), `bus` (44x16), `train_engine` (52x22), `train_car` (48x22) | 테마별 `cars` 로스터, 철길 4량 편성(row.gd:256) |
| 강 플랫폼 (2) | `log` (48x14), `floe` (48x14) | 눈 테마에서 유빙으로 교체(row.gd:220) |
| 지형 장식 (5) | `tree` (20x28), `pine_snow` (20x28), `bush` (16x12), `rock` (14x11), `sign_deer` (18x24) | 테마별 `trees` 풀, 러시 차선 표지판(row.gd:165) |
| 텔레그래프/FX (2) | `warn` (14x14), `glow` (11x11) | 고라니 경고 `_make_warn`(row.gd:342), 가산 블렌드 눈빛/헤드라이트(row.gd:24-39) |
| 메타 (1) | `icon` (128x128) | 프로젝트 아이콘 |

30개 텍스처 전부 `.ctex`(magic `GST2`) 안에 **WebP로 임베드**되어 있고 파일 크기는 142~442 B 수준이다(예: `warn` 142 B, `gorani_0` 296 B, `icon` 442 B). 사운드 11종은 모두 `AudioStreamWAV`이며 `.sample` 리소스 크기는 다음과 같다.

| 역할 | 파일 (크기) |
|---|---|
| 음악 | `bgm` 130,199 B — 유일한 루프 스트림 |
| 플레이어 액션 | `hop` 1,039 B |
| 위험 텔레그래프 | `near` 1,655 B, `horn` 2,999 B, `gorani` 2,359 B, `train` 5,935 B |
| 사망 | `crash` 3,527 B, `splash` 3,527 B, `over` 8,079 B |
| 진행 | `stage` 3,791 B |
| UI | `click` 687 B |

파일 크기 서열이 그대로 소리의 역할(짧은 틱 vs 징글)을 반영한다.

#### 픽셀아트 파이프라인

원본 스프라이트는 16x16 안팎의 극소 크기이고 코드에서 일괄 4배 확대된다(`_sprite`의 기본 스케일 `s := 4.0`, row.gd:104; 플레이어도 `Vector2(4, 4)`, player.gd:37) — 16px × 4 = 64px로 그리드 셀 `CELL := 64`와 정확히 맞아떨어진다. 여기에 프로젝트 설정의 `default_texture_filter=0`(nearest, 블러 없는 확대), `snap_2d_transforms_to_pixel=true`(서브픽셀 흔들림 제거), `stretch mode=canvas_items`(640x960 비율 유지 스케일링), 그리고 한글 픽셀 폰트 Galmuri9/11/11-Bold가 결합되어, 벡터 `ColorRect` 배경(row.gd:92-102) 위에 크리스프한 저해상도 픽셀아트가 얹히는 일관된 룩을 이룬다. UI에서도 캐릭터 스프라이트를 5배(ui.gd:167), 타이틀 디오라마의 고라니를 6배(ui.gd:132)로 확대해 같은 문법을 유지한다. WebP-in-ctex 압축과 극소 WAV 샘플은 웹 배포 전송량을 최소화하는 선택으로 보인다(추정).

---

## 6. 게임 디자인 수치

### 6.1 5개 스테이지 데이터 (theme_defs.gd:7-79)

| 필드 | 0 "숲속 도로" | 1 "노을 국도" | 2 "밤의 숲" | 3 "겨울 숲" | 4 "새벽 도심" |
|---|---|---|---|---|---|
| grass 2색 | `7ec850`/`74bd49` | `a8b04a`/`9ca644` | `3e6b38`/`376233` | `e8eef2`/`dde6ec` | `9aa0a8`/`90969e` |
| road / line | `4a4a52` / `e8e4d8` | `4e4a50` / `e8d8b8` | `3a3a44` / `c8c4b8` | `565a62` / `f0ece0` | `42444c` / `d8d4c8` |
| river / rail | `4a90c2` / `9a8a72` | `5a84b8` / `a08a68` | `2a5080` / `6e6252` | `7ab8d8` / `8a8478` | `4a7898` / `7a7268` |
| ambient | (1, 1, 1) | (1.0, 0.86, 0.72) | (0.52, 0.58, 0.78) | (0.88, 0.93, 1.0) | (0.8, 0.84, 0.98) |
| deco_tint | (1, 1, 1) | (1.0, 0.92, 0.8) | (0.75, 0.8, 0.95) | (0.95, 0.98, 1.0) | (0.9, 0.92, 1.0) |
| night / snow | false / false | false / false | **true** / false | false / **true** | **true** / false |
| weights grass/road/river/rail | .42/.40/.12/.06 | .36/.44/.08/.12 | .44/.38/.10/.08 | .40/.38/.14/.08 | .32/**.50**/**.00**/**.18** |
| river_run | 2 | 2 | 2 | **3** | 1 |
| trees | tree×2, bush, rock | tree, bush×2, rock | tree×3, rock | pine_snow×3, rock | bush×2, rock×2 |
| cars | car_red×2, car_blue, car_white, truck | truck×2, car_white, taxi, car_red, bus | car_white, car_blue, truck, car_red | car_blue, truck, car_white, bus | bus×2, taxi×2, car_white, truck |
| speed [min, max] px/s | [85, 150] | [115, 190] | [100, 175] | [110, 185] | **[130, 210]** |
| gap [lo, hi] 초 | [1.6, 3.2] | [1.4, 2.8] | [1.5, 3.0] | [1.5, 2.9] | **[1.3, 2.6]** |
| p_gorani | 0.13 | 0.11 | **0.22** | 0.16 | 0.07 |
| p_ambush | 0.20 | 0.16 | **0.32** | 0.22 | 0.08 |

다섯 스테이지 모두 `weights` 합이 정확히 1.0이므로 각 가중치가 곧 1차 확률이다. 설계 의도가 뚜렷하게 읽히는 두 극단이 있다. **"밤의 숲"(stage 2)**은 차량 자체는 평범하지만 고라니 돌진(`p_gorani` 0.22)과 잔디 매복(`p_ambush` 0.32)이 전 스테이지 최고치이고 `night = true`로 시야까지 어둡다 — 고라니 특화 스테이지다. 반대로 **"새벽 도심"(stage 4)**은 고라니 확률이 최저(0.07/0.08)인 대신 도로 비중 0.50, 철길 비중 0.18, 강 0.00, 속도 [130, 210], 간격 [1.3, 2.6]으로 차량·기차 압박이 최대다. `river` 색이 정의되어 있지만 `weights["river"] = 0.0`이므로 이 스테이지에서 강 행은 생성되지 않는다.

### 6.2 난이도 곡선 4종 (theme_defs.gd:90-110)

행 번호 `r`은 **절대 행 번호**(URL 스킵으로 시작 행을 옮기면 그만큼 앞당겨진다), `L = loop_count(r) = floor(r / 100)`이다.

| 곡선 | 수식 | 상한 | 상한 최초 도달 |
|---|---|---|---|
| `difficulty(r)` | `min(1 + r/140, 2.2)` | 2.2 | 행 168 |
| `gorani_p(r, base)` | `min(base * (1 + 0.4L), 0.45)` | 0.45 | base 0.22 기준 L=3 → 행 340 |
| `rush_lane_p(r)` | `L <= 0 → 0`; `min(0.1 + 0.04(L-1), 0.3)` | 0.3 | L=6 → 행 600 |
| `ambush_p(r, base)` | `min(base * (1 + 0.25L), 0.5)` | 0.5 | base 0.32 기준 L=3 → 행 340 |

`gorani_p` 상한 도달 시점은 base마다 다르다: base 0.22 → L=3(행 340–359), 0.16 → L=5(행 560–579), 0.13 → L=7(행 700–719), 0.11 → L=8(행 820–839), 0.07 → L=14(행 1480–1499). `ambush_p`는 base 0.32 → L=3(행 340–359), 0.22 → L=6(행 660–679), 0.20 → L=6(행 600–619), 0.16 → L=9(행 920–939), 0.08 → L=21(행 2180–2199). 이 "상한 도달 행" 값들은 해당 base 테마가 그 루프에서 등장하는 구간을 기준으로 계산한 산술 결과이며 소스에 명시된 값은 아니다.

`rush_lane_p`의 `L <= 0 → 0.0` 분기가 특히 중요하다. **첫 100행(첫 5개 스테이지) 동안은 러시 차선("고라니 주의" 표지판이 달린 고라니 전용 차선)이 절대 등장하지 않는다.** 즉 1루프는 학습 구간이고 2루프부터 새 메커니즘이 열리는 구조다.

### 6.3 `difficulty`가 실제로 곱해지는 지점

| 요소 | 공식 | diff=1.0 | diff=2.2 (행 168+) | 근거 |
|---|---|---|---|---|
| 차량 속도 | `U(speed_lo, speed_hi) * diff` px/s | 85~210 | 187~462 | row.gd:152-153 |
| 차량 스폰 간격 | `U(gap_lo, gap_hi) / diff` 초 | 1.3~3.2 | 0.59~1.45 | row.gd:154-156, 303 |
| 통나무 속도 | `U(42, 80) * sqrt(diff)` px/s | 42~80 | 62.3~118.7 | row.gd:219 |
| 기차 대기 | 최초 `U(2.0, 6.5)/diff`, 이후 `U(3.0, 7.5)/diff` 초 | 2.0~7.5 | 0.91~3.41 | row.gd:252, 400 |
| 매복 고라니 속도 | `245 * (1 + 0.18 * diff)` px/s | 289.1 | 342.0 | row.gd:296-297 (1.75 상쇄) |
| 러시 차선 보정 | `p_g = 0.8` 고정, `gorani_mult 1.3`, 속도 ×0.85, 간격 ×0.75 | — | — | row.gd:158-163, 313 |

강제 스크롤만은 `difficulty`가 아니라 `max_row`에 직접 비례한다: `0.1 + 0.004 * max_row` 행/초(3.0초 유예 후), 상한 0.62 행/초 = 39.68 px/s, 행 130에서 상한 도달(game.gd:127-128).

### 6.4 행별 실계산표

`base`는 해당 행의 `theme_for_row` 테마 값이다.

| row | 테마 | L | difficulty | gorani_p | rush_lane_p | ambush_p |
|---|---|---|---|---|---|---|
| 0 | 숲속 도로 (.13/.20) | 0 | 1.000 | 0.130 | 0.000 | 0.200 |
| 20 | 노을 국도 (.11/.16) | 0 | 1.143 | 0.110 | 0.000 | 0.160 |
| 100 | 숲속 도로 (.13/.20) | 1 | 1.714 | 0.182 | 0.100 | 0.250 |
| 140 | 밤의 숲 (.22/.32) | 1 | 2.000 | 0.308 | 0.100 | 0.400 |
| 200 | 숲속 도로 (.13/.20) | 2 | **2.200** (원값 2.429 캡) | 0.234 | 0.140 | 0.300 |
| 300 | 숲속 도로 (.13/.20) | 3 | 2.200 | 0.286 | 0.180 | 0.350 |
| 500 | 숲속 도로 (.13/.20) | 5 | 2.200 | 0.390 | 0.260 | 0.450 |

정리하면 난이도는 **삼중 구조**로 상승한다: (a) 행 번호에 선형 비례하는 `difficulty`(행 168에서 포화), (b) 100행 주기의 루프 배수 `L`로 열리고 증가하는 고라니·매복·러시 확률(행 340~600 사이에서 각각 포화), (c) `max_row`에 비례하는 강제 스크롤 압박(행 130에서 포화). 세 축이 모두 포화한 행 600 이후에는 난이도가 사실상 평탄해지고 스테이지 로스터 차이만 남는다.

### 6.5 지형 생성 규칙 상수

| 규칙 | 값 | 근거 |
|---|---|---|
| 스테이지 길이 | 20행 (`ROWS_PER_STAGE`) | theme_defs.gd:5 |
| 1루프 | 100행 (20 × 5 스테이지) | theme_defs.gd:95 |
| 시작 안전 구간 | 뒤 6행 강제 잔디 + 앞 3행(`idx < start_row + 3`) 강제 잔디 | game.gd:45-46, 84 |
| 스테이지 경계 행 | `idx % 20 == 0`이면 무조건 잔디 | game.gd:84 |
| 잔디 기근 방지 | `since_grass >= 6`이면 강제 잔디 (잔디 없는 구간 최대 6행) | game.gd:85-86 |
| 잔디 과잉 방지 | 잔디 3연속 이상이면 1회 재추첨 | game.gd:90-91 |
| 철길 연속 | 2연속 금지 | game.gd:93-94 |
| 강 연속 | 테마별 `river_run`(2/2/2/3/1) 이상 금지 | game.gd:95-96 |
| 잔디 장애물 | `randi_range(0, 3)`칸, `idx > 2`부터 (9칸 중 통로 항상 존재) | row.gd:126-131 |
| 매복 무장 조건 | `idx > 6` | row.gd:139 |
| 초기 월드 | 뒤 6행 + 앞 15행 = 21행 | game.gd:45-50 |
| 행 선행 생성 | `cam_row + 14`까지 | game.gd:134 |
| 행 컬링 | `cam_row - 8` 미만 | game.gd:136-139 |
| 시뮬레이션 창 | `[cam_row - 7, cam_row + 14)` = 최대 21행 | game.gd:141-143 |

### 6.6 조작감(feel) 상수

| 이름 | 값 | 의미 |
|---|---|---|
| `CELL` / `COLS` | 64 px / 9칸 | 타일 크기와 가로 칸 수 (game.gd:5-6) |
| `CAM_ANCHOR` | 600.0 | `cam_row` 행 바닥선이 놓이는 화면 y (game.gd:7) |
| `X_MIN` / `X_MAX` | 34.0 / 606.0 | 통나무 탑승 중 허용 x, 이탈 시 익사 (game.gd:8-9) |
| `HOP_T` | 0.13초 | 홉 지속 시간, 평균 약 492 px/s, 이 동안 `hazard_hit` 면역 (player.gd:6) |
| 홉 아크 높이 | 22.0 px | `sin(t·π) × 22.0` 반파장 사인 (player.gd:84) |
| 착지 스쿼시 | `(4.4, 3.4)` → `(4, 4)` / 0.06초 | (player.gd:90-92) |
| bump 넉백 | 10.0 px, 0.05 + 0.05초 | 이동 불가 피드백 (player.gd:100-102) |
| 입력 버퍼 | 1개 (마지막 입력만) | 홉 중 저장, 착지 즉시 소비 (game.gd:177-179, 245-248) |
| 스와이프 최대 시간 | 700 ms | 초과 시 입력 무효 (game.gd:273) |
| 탭 데드존 | 26.0 px | 미만이면 탭 = 전진 (game.gd:279) |
| 카메라 트레일 | `max_row - 3.0` | 추적 목표 행 (game.gd:129) |
| 카메라 평활 | `min(1, 4.5·dt)` | 지수 평활, 시간상수 약 0.22초 (game.gd:130) |
| 스크롤 유예 | 3.0초 | 이후부터 강제 스크롤 시작 (game.gd:127) |
| `"scroll"` 사망선 | `py > 1000.0` | 화면(960) 아래 40px = `cam_row - row > 6.75` (game.gd:159-161) |
| 화면 흔들림 | 0.35초, 진폭 ±7 px (수평) | 충돌 사망 시 (game.gd:169, 305) |
| 니어미스 | `NEAR_DIST` 84.0 px, 보너스 +2 | 통과 후 생존 시 (row.gd:14, game.gd:322) |
| 충돌 판정 폭 | 차량/고라니 `half + 18`, 기차 `train_half + 16`, 탑승 `half + 4` | row.gd:413, 416, 422 |
| 고라니 반폭 | 44.0 고정 | 텍스처 폭과 무관 (row.gd:187) |
| `SPAWN_MARGIN` | 280.0 px | 화면 밖 스폰/제거 여유 (row.gd:13) |
| 차량 최소 간격 | `half + 150` px (clearance) | 미달 시 스폰 스킵 (row.gd:308) |
| 경적 확률 | 0.04 | 일반 차량 스폰 시 (row.gd:318) |
| 고라니 경고 | 도로 0.55초 / 매복 0.45초 | (row.gd:328, 338) |
| 기차 | 경고 1.25초(0.16초 교대 점멸), 속도 950 px/s 고정, 4량 총폭 814 px(`train_half` 415) | row.gd:73, 383, 386, 259-263 |
| 통나무 | 폭 60% 1.0배 / 40% 0.65배, 간격 `half*2 + U(115, 210)` px | row.gd:224, 237 |
| 스테이지 전환 | ambient 1.2초 트윈, `stage` SFX -3 dB, 배너 0.25/1.0/0.4초 | game.gd:349-351, ui.gd:287-289 |
| 눈송이 | 42개, 4x4 또는 6x6, 낙하 55~120 px/s, 드리프트 ±25 px/s | game.gd:361-368 |
| 게임오버 지연 | 1.0초 | 사망 연출 후 패널 표시까지 (main.gd:55) |
| 사망 SFX | `splash` -2 / `over` -4 또는 -6 / `crash` -2·0 / `horn` -8 / `gorani` pitch 0.8 | game.gd:297-312, main.gd:54 |
| 니어미스 SFX | `near` -4 dB | game.gd:323 |
| 근접 경고음 | `horn` -6 dB, 그 외 -3 dB, jitter 0.05, 가청 반경 15행 | game.gd:329-331 |
| 홉 SFX | -6 dB, pitch 1.0 ± 0.06 | game.gd:204 |
| 차단 SFX | `click` -12 dB, pitch 0.7 | game.gd:202 |
| 클릭 SFX | -8 dB (리더보드 필터 탭만 -10 dB) | ui.gd:81, 178, 430 |
| BGM | -7.0 dB, 전체 구간 `LOOP_FORWARD` | sfx.gd:24, 27-31 |
| SFX 풀 | 8보이스 라운드로빈 | sfx.gd:17-21 |

---

## 7. 데이터 흐름과 영속성

### 7.1 로컬 저장 스키마

경로는 `const SAVE_PATH := "user://save.json"`(ranking.gd:7)이며 웹에서는 `/userfs`(IDBFS) 하위로 매핑되어 IndexedDB(`DB_VERSION 21`, 스토어 `"FILE_DATA"`)에 영속화된다. 스키마는 4개 키가 전부다.

```gdscript
var data := { "nickname": "", "best": 0, "muted": false, "char": 0}
```
(ranking.gd:9)

| 키 | 기본값 | 쓰는 곳 | 읽는 곳 |
|---|---|---|---|
| `nickname` | `""` | ui.gd:349 (등록 버튼) | ui.gd:338 (`LineEdit` 프리필) |
| `best` | `0` | ranking.gd:47 (`record_score`) | main.gd:58, ui.gd:208, 241, 254, 510 |
| `muted` | `false` | main.gd:29 (`set_muted`) | main.gd:24 (부팅 복원) |
| `char` | `0` | ui.gd:180 (캐릭터 클릭) | ui.gd:105 (타이틀 진입) |

파일 형식은 `JSON.stringify(data)` 한 줄이고 암호화·서명·체크섬이 없으므로 사용자가 브라우저 개발자 도구로 자유롭게 조작할 수 있다. 다만 **`best`는 서버로 전송되지 않으므로**(POST 바디에 없음) 리더보드 위협은 아니다 — 조작해도 자기 화면의 "내 최고기록" 숫자만 바뀐다.

### 7.2 리더보드 API 계약

베이스 URL은 `Ranking.base_url()`이 페이지 URL에서 유도한다(§5.6). 엔드포인트는 경로 2개, 메서드 3가지다. 아래 응답 형태는 라이브 엔드포인트에 GET만 보내 실측 확인한 것이며 **POST는 보내지 않았다**(따라서 POST 응답 스키마는 클라이언트 코드가 기대하는 형태다).

| 엔드포인트 | 메서드 | 요청 바디 | 클라이언트의 성공 조건 | 호출 지점 |
|---|---|---|---|---|
| `api/start` | GET | 없음 | `payload.has("token")` | game.gd:32 (`Game.setup` 내부, 런당 1회) |
| `api/scores` | GET | 없음 | `payload.has("scores")` | ui.gd:399 (`_add_filtered_board`의 `load_fn`) |
| `api/scores` | POST | `{name, score, rows, char, token}` | `payload.get("ok", false)` | ui.gd:353 ("랭킹 등록" 버튼) |

**(a) `GET api/start` — 토큰 발급** (ranking.gd:69-75). 먼저 `token = ""`으로 비운 뒤 요청하고, 응답이 `Dictionary`이며 `"token"` 키를 가지면 `str()`로 강제 변환해 보관한다. 실측 응답:

```json
{"token": "1786530403.17529b611b0cf662.7ddfdf354abe570b"}
```

`<10자리 epoch>.<hex16>.<hex16>` 구조로 발급 시각 + nonce + 서명으로 보인다(추정 — 서버 코드는 없다). 앞부분 `1786530403`은 응답의 `date: Wed, 12 Aug 2026 10:26:43 GMT`와 정확히 일치했다. 호출자는 `Game.setup()`의 세 번째 줄뿐이므로 **런 시작마다 정확히 한 번** 토큰을 받아 오며, `retry()` → `start_game()` → `setup()` 경로도 동일하다. 발급 시각이 런 시작 시각과 같으므로 서버는 "이 점수를 내는 데 걸린 최소 시간"을 검증할 재료를 갖는다(추정).

토큰 필드가 단일 슬롯이라 두 가지 경합이 생긴다. 첫째, `start_run()`이 먼저 `token = ""`으로 비우고 비동기 요청을 보내므로 이전 런의 지연된 응답이 새 런의 토큰 자리에 늦게 들어앉을 수 있다. 둘째, `submit` 성공 시 `token = ""`로 소진 처리하므로 클라이언트 측에서는 토큰 1개 = 제출 1회다.

**(b) `GET api/scores[?char=<id>]` — 보드 조회** (ranking.gd:77-89). 필터가 빈 문자열이면 쿼리 없이 전체 보드를 요청한다. 성공하면 `cb.call(payload["scores"], true)`, 실패하면 `cb.call([], false)`로 **항상 콜백이 (Array, bool) 두 인자를 받는 계약**이 유지된다. 실측 응답 형태:

```json
{"scores": [{"name": "민지", "score": 401, "stage": 16, "char": "hedgehog", "ts": 1786525459}, ...]}
```

- 최상위 키는 `scores` 단 하나이고 `rank`는 없다.
- 엔트리 키는 `name`, `score`, `stage`, `char`, `ts` 5개이며 `score` 내림차순으로 정렬되어 온다. 클라이언트는 `rows`를 보내고 `stage`는 보내지 않으므로 `stage`는 **서버가 `rows`에서 파생시킨 값**이다. 50건 전수 대조 결과 `stage = floor(rows / 20) + 1`(게임 HUD의 `STAGE %d`와 같은 1-based 규약)로 해석할 때만 모든 레코드가 `score >= rows` 불변식과 모순 없이 성립한다(§7.3).
- 전체 조회는 50개를 반환했고 `?char=rabbit`, `?char=gorani_p`도 각각 50개였다 — 필터별로 서버가 따로 질의해 50개 상한을 적용하는 것으로 보인다(추정: 무필터 50개 안의 rabbit은 25개인데 rabbit 필터는 50개를 돌려줬다). `?char=chick` 13개, `?char=hedgehog` 10개, `?char=peccy`는 `{"scores": []}`였다.
- 알 수 없는 값(`?char=notachar`)은 **필터를 무시하고 전체 목록**을 돌려줬다.

클라이언트가 실제로 쓰는 필드는 `name`, `char`, `score`뿐이고 `stage`, `ts`는 렌더링에 쓰이지 않는다(ui.gd:466-484). 표시 개수는 `mini(limit, list.size())`로 자르므로(ui.gd:456) 서버가 준 50개 중 게임오버는 5개, 랭킹 모달은 10개만 쓴다. `scores`가 Array인지는 검증하지 않으므로 서버가 다른 타입을 주면 `list.size()`에서 문제가 될 수 있다(추정).

**(c) `POST api/scores` — 점수 제출** (ranking.gd:91-108).

```gdscript
func submit(name: String, score: int, rows: int, char_id := "rabbit") -> void:
	if token == "":
		submit_reason = "offline"
		submitted.emit(false, -1, [])
		return
	var body := JSON.stringify({ "name": name, "score": score, "rows": rows, "char": char_id, "token": token})
```

토큰이 없으면 네트워크를 아예 타지 않고 즉시 실패를 emit한다 — `start_run`의 GET이 실패했다는 것은 곧 오프라인이라는 판단이다. 바디는 정확히 5개 키이고 GET과 같은 경로에 POST하는 REST 스타일이다. 기대 응답은 `{"ok": true, "rank": <int>, "scores": [...]}`이며 `rank`/`scores`는 없어도 각각 `-1`/`[]`로 기본값 처리된다(ranking.gd:99-104). `ok`가 falsy거나 200이 아니거나 타임아웃이면 전부 `"rejected"`다. 넘기는 `score`/`rows`의 원천은 `main.on_game_over(score(), rows_crossed(), stage_idx, cause)`(game.gd:313)로, `score() = max_row - start_row + bonus`, `rows_crossed() = max_row - start_row`다.

### 7.3 클라이언트가 서버에 위임하는 검증

`Ranking`이 서버에 보내는 값 중 **클라이언트가 위조할 수 없는 것은 `token` 하나뿐**이다. 나머지는 전부 클라이언트가 만든 숫자·문자열이며, 따라서 아래 항목은 전적으로 서버가 검증해야 한다.

- **`score` / `rows`의 정합성.** 정직한 플레이에서는 `bonus`가 `bonus += 2`로만 증가하므로(game.gd:322) 항상 `score = rows + bonus >= rows`라는 불변식이 성립한다. 클라이언트는 이 불변식을 강제하지 않고 두 값을 각각 바디에 실어 보내므로, 검증 책임은 서버에 있다. **실측 보드 50건은 이 불변식을 모두 만족한다.** 응답의 `stage`가 게임 내 HUD 표기와 같은 1-based(`stage = floor(rows / 20) + 1`, ui.gd:253의 `stage_index(...) + 1`과 동일 규약)라고 보면 각 레코드의 `rows`는 `[20*(stage-1), 20*stage - 1]` 구간에 있어야 하는데, 50건 전부 `score >= 20*(stage-1)`을 만족했다(위반 0건). 반면 0-based(`stage = floor(rows/20)`)로 가정하면 `{"name": "세상존잘정호", "score": 333, "stage": 17}` 한 건만 `rows >= 340 > score`가 되어 모순이 생긴다. 위반이 0건이 되는 해석이 하나뿐이므로 **`stage`는 1-based이고 현재 보드에서 정합성 위반 정황은 발견되지 않았다**고 보는 것이 타당하다(서버 코드가 없으므로 산출식 자체는 여전히 추정).
- **`char`의 유효성.** 임의 문자열이 들어갈 수 있다. 클라이언트는 항상 `main.last_char`를 넘기지만 이는 강제가 아니고, 화이트리스트 검사는 **읽는 쪽**에서만 한다(ui.gd:467).
- **`name`의 길이·문자셋.** `LineEdit.max_length = 12`(ui.gd:337)와 `strip_edges()`(ui.gd:346)는 UI 수준 제약일 뿐 `Ranking.submit`에는 길이·문자 검사가 전혀 없다. 신원 개념이 없으므로 임의의 닉네임으로 사칭 등록이 가능하다.
- **시도 횟수와 토큰 재사용.** 클라이언트는 토큰을 1회용으로 다루지만(ranking.gd:100) 그 규칙을 강제하는 것은 서버여야 한다. `GET api/start`는 인증 없이 누구나 호출할 수 있으므로 토큰을 대량으로 미리 발급받는 것도 클라이언트 측에서는 막을 수 없다.

서버가 실제로 가진 검증 재료는 (i) 토큰 서명 유효성, (ii) 토큰 재사용 여부, (iii) 토큰 발급 시각과 제출 시각의 차이 대비 `score`/`rows`의 물리적 타당성, (iv) `score >= rows` 정합성 정도로 보인다(추정). POST가 거부될 수 있다는 사실과 UI 문구 `"등록이 거부됐어요 (점수 검증 실패)"`(ui.gd:368)로 보아 서버 측 검증이 존재하는 것은 분명하다. 다만 **서버 구현 코드를 확보하지 못했으므로** 토큰이 무상태 HMAC인지 서버 저장 pending 토큰인지, 만료가 있는지, 재사용을 실제로 차단하는지, 레이트 리밋이 있는지는 확인할 수 없었다.

부수적으로, `Game.setup()`의 URL 쿼리 `?s=N`(game.gd:35-38)은 시작 행을 최대 10000까지 건너뛰게 하지만 점수는 `max_row - start_row` 기준이라 **점수를 부풀리는 데는 쓸 수 없다**(game.gd:315-319).

---

## 8. 관찰 및 특징

### 8.1 눈에 띄는 엔지니어링 선택

**세대 토큰(generation token) 관용구.** `Main._over_token`(main.gd:10)은 `await`가 있는 코드에서 흔히 놓치는 문제를 정면으로 다룬 패턴이다. `on_game_over`는 1.0초를 기다린 뒤 UI를 띄우는데, 그 코루틴은 `Main`(ALWAYS) 소속이라 대기 중 `Game`이 해제되어도 반드시 재개된다. 그래서 대기 전에 세대 번호를 증가시키고 지역 변수에 스냅샷을 떠 두었다가, 재개 시 `if token != _over_token or app_state != "over": return`으로 자신이 아직 유효한 세대인지 확인한다(main.gd:49-57). 모든 상태 전이 함수가 토큰을 올리므로(main.gd:34, 49, 64) 그 사이 어떤 전이가 일어났든 낡은 코루틴은 조용히 포기한다. 같은 사고방식이 UI에도 두 번 더 나타난다 — 리더보드 응답 폐기 조건 `cur[0] != want`(ui.gd:400)와 배너의 `await` 후 `is_instance_valid(p) and p.is_inside_tree()` 재검사(ui.gd:281-282)다. 비동기 경계마다 "내가 아직 유효한가"를 묻는 일관된 규율이 있다.

**8보이스 오디오 풀.** `AudioStreamPlayer` 하나로는 겹치는 효과음이 서로를 끊는다는 엔진 특성을 라운드로빈 풀로 우회한다(sfx.gd:17-21, 36-37). 8개면 이 게임의 최대 동시 발음(충돌 시 `crash` + `horn`/`gorani`에 근접 경고음까지)을 충분히 덮고, 9번째부터는 자연히 가장 오래된 보이스를 빼앗는 voice stealing이 된다. 여기에 `play()`의 `jitter` 인자로 피치를 ±6% 흔들어(game.gd:204) 가장 빈번한 점프음의 반복 피로를 줄인다. 52줄짜리 파일이 담당하는 일치고는 밀도가 높다.

**씬 파일 없는 코드 기반 UI.** 569줄의 `ui.gd`가 5개 화면을 전부 만든다. 반복을 흡수하는 장치가 `lbl()`, `btn()`, `panel_box()`, `full_rect()`, `clear()` 다섯 개 팩토리이고, 특히 `btn()`이 4개 상태의 `StyleBoxFlat`을 생성하면서 `pressed` 시그널에 클릭 SFX를 자동으로 끼워 넣는다(ui.gd:80-83). 덕분에 "버튼을 만들면 클릭음이 난다"는 규칙이 예외 없이 지켜진다. 리더보드는 `_add_filtered_board(parent, limit, default_filter)` 하나로 게임오버(TOP 5, 캐릭터 필터 기본값)와 랭킹 모달(TOP 10, 전체)을 모두 처리하고, 현재 필터를 **1원소 배열의 가변 캡처**(`var cur := [default_filter]`, ui.gd:387)로 클로저 간에 공유하는 GDScript 특유의 관용구를 쓴다. 반환값이 `{"list_box", "reload", "get"}` 딕셔너리라 호출자가 필요한 만큼만 붙잡아 쓸 수 있다.

**`JavaScriptBridge`로 API origin 유도.** `location.origin + location.pathname.replace(/[^/]*$/, '')`라는 정규식 한 줄(ranking.gd:20)로 API 베이스를 페이지 상대 경로에 고정한다. 하드코딩된 도메인이 없으므로 서브패스 배포·도메인 변경·로컬 개발이 모두 코드 수정 없이 동작하고, 항상 same-origin이라 CORS 프리플라이트가 아예 발생하지 않는다. 폴백 `http://127.0.0.1:8000/`이 프로덕션 오리진과 같은 Python `http.server` 기본 포트라는 점에서 개발-배포 대칭성도 유지된다. 같은 브리지가 `?s=N` 스테이지 스킵에도 쓰인다(game.gd:36).

**픽셀아트 파이프라인의 일관성.** 16px 도트 → 코드에서 4배 확대 → 64px 셀에 정확히 일치, 여기에 `default_texture_filter=0`(nearest)과 `snap_2d_transforms_to_pixel=true`, `canvas_items` 스트레치, 한글 픽셀 폰트 Galmuri 3종이 결합된다. 배경은 텍스처가 아니라 `ColorRect`로 그리므로(row.gd:92-102) 테마 색만 바꿔 5개 스테이지의 룩을 만들어낸다 — 30개라는 적은 스프라이트 수로 다섯 가지 분위기를 내는 비결이 여기 있다. 야간 연출도 텍스처 교체가 아니라 `CanvasModulate` 앰비언트 + 가산 블렌딩 `glow` 스프라이트 + `Polygon2D` 헤드라이트 조합이다(row.gd:188-200).

**텔레그래프 우선 설계.** 즉사 요소마다 예고가 붙는다: 고라니는 도로 0.55초 / 매복 0.45초의 `warn` 아이콘 + 울음소리(row.gd:328, 338), 기차는 1.25초의 기적 + 0.16초 주기 교대 점멸(row.gd:383-390), 러시 차선은 상시 `sign_deer` 표지판(row.gd:165), 일반 차량은 4% 확률 경적(row.gd:318). 그리고 `sfx_near_row`가 카메라에서 15행 이내만 소리를 내므로(game.gd:329) 화면 밖 소음이 쌓이지 않는다. 여기에 홉 0.13초 동안의 충돌 면역(game.gd:151)과 잔디 행의 통로 보장(최대 3칸만 차단), 20행마다의 강제 잔디 안전지대(game.gd:84)까지 합치면, 난이도 곡선은 공격적이지만 "피할 수 없는 죽음"은 구조적으로 배제되어 있다.

**차량 로스터의 중복 항목 가중치.** `theme_def["cars"]`에서 균등 추첨하되(row.gd:171-173) 목록에 같은 항목을 여러 번 넣어 확률을 준다 — 새벽 도심의 `["bus", "taxi", "car_white", "taxi", "bus", "truck"]`은 bus와 taxi가 각각 2/6이다. 가중치 자료구조 없이 배열 하나로 해결하는 단순한 선택이다.

### 8.2 코드에서 직접 따라 나오는 취약점

**오프라인 시 등록 버튼이 영구 비활성화된다.** 등록 버튼 콜백이 `submit_b.disabled = true`로 잠그지만(ui.gd:351) `"offline"` 분기는 `disabled`를 되돌리지 않는다(ui.gd:365-366). 네트워크가 복구되어도 같은 게임오버 화면에서는 다시 시도할 수 없고, 재시도하려면 새 런을 해야 한다(새 런이 새 토큰을 받아온다). `"rejected"` 분기만 버튼을 다시 켠다(ui.gd:369-370).

**`CONNECT_ONE_SHOT` 때문에 재시도 결과가 UI에 반영되지 않는다.** `"rejected"` 분기가 버튼을 다시 활성화하는 그 시점에 원샷 연결은 이미 소진되어 있다(ui.gd:371). 따라서 두 번째 제출은 HTTP 요청까지는 정상 수행되지만 `submitted`를 듣는 노드가 없으므로 상태 라벨은 `"등록이 거부됐어요 (점수 검증 실패)"`에 그대로 머물고, 설령 성공했더라도 보드가 갱신되지 않는다.

**실패 문구가 사실과 어긋날 수 있다.** `_request`의 성공 판정이 `RESULT_SUCCESS and code == 200`뿐이므로(ranking.gd:58) 5초 타임아웃, 502, 429, 5xx가 전부 `"rejected"`로 분류되어 사용자에게는 `"점수 검증 실패"`로 표시된다(ui.gd:368). 재시도·백오프도 없다.

**터치 전용 기기에서 일시정지에 진입할 수 없다.** `pause_game()`의 유일한 호출부가 키보드 핸들러(main.gd:91)이고 화면에 일시정지 버튼이 없다. HUD는 전체가 `MOUSE_FILTER_IGNORE`(ui.gd:229)이므로 탭할 대상 자체가 없다.

**죽은 코드와 잔재.** `Ranking.server_ok`는 세 곳에서 대입되지만 읽는 코드가 프로젝트 전체에 없다. `Ranking.top`은 채워지지만 유일한 수신자가 무시한다. `UI.font_s`(Galmuri9)는 로드만 되고 쓰이지 않는다 — 폰트 리소스 하나가 이유 없이 로드된다. `UI.show_game_over`의 `stage_i` 매개변수는 본문에서 사용되지 않으며 `Player.follow_ride(dt)`의 `dt`도 그렇다. `Row.train_half := 410.0` 선언 기본값은 `_build_rail`이 계산한 415로 항상 덮어써진다. 기능적 피해는 없지만 의도가 남지 않은 흔적들이다.

**640x960 하드코딩과 반응형 부재.** `ui.gd`에는 뷰포트 크기를 질의하는 코드가 한 줄도 없고 모든 좌표가 설계 해상도에 고정되어 있다. 극단적인 화면비에서는 `canvas_items` 스트레치의 레터박스 안에 그려질 뿐 레이아웃이 재배치되지는 않는다.

**콜드 로드 비용.** `index.wasm` 39.5 MB가 압축 없이 전송된다(§2.2). 게임 자체 데이터(`index.pck`)는 3.4 MB이므로 전송량의 92%가 엔진 바이너리다. 게다가 파일명에 해시가 없고 `max-age=3600`이라 재배포 시 최대 1시간의 자산 스큐 위험이 있다.

**서버 단일 프로세스와 캐시 미적용 API.** `/api/*`가 `no-cache`이므로 리더보드 조회가 전부 Python `http.server` 오리진에 도달한다. 게임오버 화면은 진입 시 GET 1회, 필터 탭을 누를 때마다 GET 1회, 제출 성공 시 GET 1회를 추가로 보내므로 한 판당 조회 요청이 여러 번 쌓인다.

**비결정성.** `rng.randomize()`(game.gd:33) 하나뿐이고 시드를 주입할 방법이 없어 리플레이·검증·재현이 불가능하다. 서버가 점수를 검증하려 해도 클라이언트 시드를 알 수 없으므로 시뮬레이션 기반 검증은 선택지에서 빠진다.

**`rows.keys()` 순회 중 `erase`.** 컬링 루프가 `for idx in rows.keys()` 안에서 `rows.erase(idx)`를 호출한다(game.gd:136-139). Godot 4의 `Dictionary.keys()`가 복사된 `Array`를 반환한다는 엔진 동작에 의존하는 코드이며, 소스 자체에 그 보장이 명시되어 있지는 않다.

**프레임레이트 의존성.** 카메라 평활이 `lerpf(cam_row, target, minf(1.0, 4.5 * dt))`(game.gd:130) 형태라 수렴 곡선이 프레임레이트에 따라 미세하게 달라진다. 또 `_step_road`에서 경고를 시작한 같은 프레임에 `pending_gorani -= dt`가 즉시 적용되어 경고 시간이 최대 1프레임 짧아진다(row.gd:314-321). 실제 체감 차이는 소스만으로 검증할 수 없다.

### 8.3 남은 불확실성

정직하게 확정하지 못한 것들을 모아 둔다. (1) **서버 구현 코드가 없다** — 토큰 구조·만료·재사용 차단, 레이트 리밋, `POST` 응답의 `scores`가 전체 보드인지 필터된 보드인지 모두 미확인이다. `stage` 산출식은 실측 50건 전수 대조로 `floor(rows/20)+1`이 유일하게 모순 없는 해석임을 확인했으나, 서버 코드가 아니라 데이터로부터의 역추론이다. (2) `X_MIN=34` / `X_MAX=606`이 그리드 경계(32/608)에서 2px 안쪽인 정확한 이유. (3) `train_half` 선언값 410과 계산값 415의 불일치 이유. (4) `sfx_near_row`의 가청 반경 15행이 시뮬레이션 창(21행)보다 넓게 잡힌 이유. (5) BGM 루프를 임포트 옵션 대신 코드로 설정한 이유(`.sample` 바이너리의 루프 메타데이터는 파싱하지 않았다). (6) `bgm.wav`의 실제 `mix_rate`와 길이 — 따라서 `loop_end`의 구체적 프레임 수. (7) `AudioServer.set_bus_mute(0, …)`의 버스 0이 Master라는 것은 Godot 기본 버스 레이아웃 가정이며 커스텀 `default_bus_layout.tres`의 존재 여부는 확인하지 않았다. (8) `Row.tex`가 `res://assets/sprites/%s.png`를 로드하는데 팩 안의 실제 자산은 `.ctex`(WebP)다 — Godot 임포트 리매핑으로 동작한다고 추정하나 리매핑 테이블 자체는 확인하지 않았다. (9) `?s=N`이 개발용 치트인지 공유 기능인지. (10) `PROCESS_MODE_INHERIT` 기본값, `queue_free`의 프레임 말미 해제, `SceneTreeTimer`가 paused 중에도 진행한다는 점, `_unhandled_input`의 전파 순서 등은 엔진 semantics에 의존한 서술이며 소스에 명시된 것이 아니다.

---

## 부록: 복원된 파일 목록

### 복원 소스

`/Users/anhyobin/dev/hack-jeongho/recovered/` 아래에 최종 소스 8개가 있고, `/Users/anhyobin/dev/hack-jeongho/_dl/extracted/scripts/` 아래에 원본 `.gdc`, `.gd.remap`, 그리고 디컴파일 산출물 `*.decompiled.gd`가 함께 있다. 두 위치의 8개 파일은 바이트 단위로 동일함을 확인했다(`diff` 전부 일치).

| 클래스 | 상속 | 줄 수 | `recovered/` | `_dl/extracted/scripts/` |
|---|---|---|---|---|
| (없음, main.tscn 첨부) | `Node` | 93 | `main.gd` | `main.gdc` / `main.decompiled.gd` |
| `Game` | `Node2D` | 384 | `game.gd` | `game.gdc` / `game.decompiled.gd` |
| `Row` | `Node2D` | 424 | `row.gd` | `row.gdc` / `row.decompiled.gd` |
| `Player` | `Node2D` | 140 | `player.gd` | `player.gdc` / `player.decompiled.gd` |
| `UI` | `CanvasLayer` | 569 | `ui.gd` | `ui.gdc` / `ui.decompiled.gd` |
| `Ranking` | `Node` | 108 | `ranking.gd` | `ranking.gdc` / `ranking.decompiled.gd` |
| `ThemeDefs` | `RefCounted` | 110 | `theme_defs.gd` | `theme_defs.gdc` / `theme_defs.decompiled.gd` |
| `Sfx` | `Node` | 52 | `sfx.gd` | `sfx.gdc` / `sfx.decompiled.gd` |
| **합계** | | **1,880** | | |

### 디스크 배치

| 경로 | 내용 |
|---|---|
| `/Users/anhyobin/dev/hack-jeongho/recovered/` | 최종 복원 소스 8개 (`*.gd`) |
| `/Users/anhyobin/dev/hack-jeongho/unpacked_manifest.txt` | GDPC 헤더, 110개 엔트리 목록, `project.binary` 설정, 스프라이트 30개 치수, 오디오 11개 크기, 폰트 임포트 스텁 |
| `/Users/anhyobin/dev/hack-jeongho/tools/` | `unpack.py`, `gdc_decompile.py`, `inspect_assets.py` |
| `/Users/anhyobin/dev/hack-jeongho/_dl/gdc_decompile.py` | GDSC 토큰 버퍼 디컴파일러 (parse + render, 269줄) |
| `/Users/anhyobin/dev/hack-jeongho/_dl/unpack.py` | GDPC 팩 언패커 |
| `/Users/anhyobin/dev/hack-jeongho/_dl/inspect_assets.py` | `.ctex` / `.sample` / `.import` 메타데이터 추출기 |
| `/Users/anhyobin/dev/hack-jeongho/_dl/index.pck` | 원본 팩 (3,419,732 B) |
| `/Users/anhyobin/dev/hack-jeongho/_dl/index.js` | Godot 웹 로더 (279,815 B) |
| `/Users/anhyobin/dev/hack-jeongho/_dl/extracted/scripts/` | `.gdc` 8개 + `.gd.remap` 8개 + `.decompiled.gd` 8개 |
| `/Users/anhyobin/dev/hack-jeongho/_dl/extracted/assets/sprites/` | `*.png.import` 스텁 29개 (실제 픽셀은 `.godot/imported/*.ctex`) |
| `/Users/anhyobin/dev/hack-jeongho/_dl/extracted/assets/audio/` | `*.wav.import` 스텁 11개 |
| `/Users/anhyobin/dev/hack-jeongho/_dl/extracted/assets/fonts/` | `*.ttf.import` 스텁 3개 (Galmuri9 / 11 / 11-Bold) |
| `/Users/anhyobin/dev/hack-jeongho/_dl/extracted/project.binary` | 프로젝트 설정 (§2.4) |
| `/Users/anhyobin/dev/hack-jeongho/_dl/extracted/main.tscn.remap` | 유일한 씬의 remap 스텁 (97 B) |
| `/Users/anhyobin/dev/hack-jeongho/_dl/extracted/icon.png` | 프로젝트 아이콘 (128x128) |

재현 명령은 `python3 _dl/gdc_decompile.py _dl/extracted/scripts/*.gdc`이며, 각 파일마다 `tokenizer_v101 … leftover=0 tabs=True`를 출력한다.
