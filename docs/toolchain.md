# 툴체인 — 언팩·디컴파일 파이프라인

`index.pck` 하나에서 게임 소스 1,880줄을 복원하기까지의 절차와 함정.
포맷 서술의 근거는 Godot 4.7의 `modules/gdscript/gdscript_tokenizer_buffer.cpp`와
`core/io/marshalls.cpp`다.

## 0. 전제 — Python 3.14 이상

`gdc_decompile.py`가 `from compression import zstd`를 쓴다. zstd가 **표준 라이브러리에
들어온 것은 3.14부터**다. 그 아래 버전에서는 `ImportError`로 죽으므로,
`python3 --version`을 먼저 확인하거나 `pip install zstandard`로 바꿔 써야 한다.
(작업 환경: Python 3.14.3)

## 1. 자산 수집

CloudFront에서 내려받은 것은 `_dl/index.pck`(3,419,732 B)와 `_dl/index.js`(279,815 B)뿐이다.
`index.html`·`index.wasm`(39.5 MB, 무압축)은 라이브 HTTP 응답을 관찰만 했고 로컬 사본이 없다.

## 2. GDPC 언팩

```bash
cd _dl && python3 unpack.py > ../unpacked_manifest.txt
```

`unpack.py`는 `./index.pck`를 읽어 `./extracted/`에 110개 엔트리를 풀고 매니페스트를
표준출력으로 낸다. **경로가 하드코딩되어 있으므로 반드시 `_dl/`에서 실행한다.**

헤더 실측값: `pack_format_version=4  engine=4.7.1  flags=2  file_base=112`,
디렉터리 오프셋 `0x3409f0`(파일 **끝부분**), 엔트리 110개.

> **함정: `flags=2`는 `PACK_REL_FILEBASE`다.** 각 엔트리의 오프셋이 절대값이 아니라
> `file_base` 기준 상대값이다. 실제 위치는 `file_base + entry_offset`으로 계산해야 하고,
> 이걸 놓치면 전부 112바이트씩 밀려서 읽힌다.

디렉터리 오프셋은 헤더의 `reserved[0] | (reserved[1] << 32)`에 u64로 들어 있다.

## 3. GDSC 디컴파일

```bash
cd _dl/extracted/scripts && python3 ../../gdc_decompile.py *.gdc
```

입력 옆에 `*.decompiled.gd`를 쓰고, 파일마다 한 줄씩 요약을 출력한다.

레이아웃:

```
Header : "GDSC" | u32 tokenizer_version(=101) | u32 decompressed_size | zstd payload
Payload: u32 identifier_count, constant_count, token_line_count, token_count
         identifiers   (u32 len + len*u32 코드포인트, 전 바이트 XOR 0xb6)
         constants     (encode_variant 스트림)
         token_lines   (token_line_count * (u32 token_idx, u32 line))
         token_columns (token_line_count * (u32 token_idx, u32 column))
         tokens        (5바이트/토큰, 첫 바이트에 0x80 플래그면 8바이트 + 값 인덱스)
```

복원이 이렇게까지 잘 되는 이유 세 가지:

1. **식별자 난독화가 XOR 0xb6 한 겹뿐**이다. 해싱이나 이름 테이블 제거가 없어 변수·함수·클래스 이름이 개발자가 쓴 그대로 나온다.
2. **`token_lines` / `token_columns`가 남아 있다.** 줄 번호를 정확히 재현할 수 있고, 컬럼에서 들여쓰기 깊이를 역산한다(`col - 1`을 들여쓰기 단위로 나눔; 관측 최소 폭이 1이면 탭). 8개 파일 모두 탭으로 판정됐다.
3. **리터럴이 Variant 스트림으로 온전히 남는다.** 정수·실수·문자열이 값 그대로 나오고 한글 문자열도 UTF-8로 복원된다.

### 무결성 판정: `leftover=0`

출력의 `leftover`는 선언된 개수만큼 소비한 뒤 남은 바이트 수다. **8개 파일 전부 0**이라는 것이
해석하지 못해 건너뛴 영역이 없다는 증거다. 디컴파일러를 수정했는데 `leftover`가 0이 아니면
그 출력은 신뢰할 수 없다.

| 파일 | 식별자 | 상수 | 토큰 | leftover | 복원 줄 수 |
|---|---|---|---|---|---|
| main | 66 | 16 | 491 | 0 | 93 |
| game | 202 | 98 | 2,668 | 0 | 384 |
| row | 186 | 156 | 3,075 | 0 | 424 |
| player | 86 | 54 | 963 | 0 | 140 |
| ui | 257 | 213 | 4,538 | 0 | 569 |
| ranking | 86 | 31 | 726 | 0 | 108 |
| sfx | 51 | 20 | 325 | 0 | 52 |
| theme_defs | 24 | 130 | 1,020 | 0 | 110 |
| | | | **13,806** | **0** | **1,880** |

### 복원되지 않는 것

- **주석.** 토크나이저가 토큰으로 만들지 않으므로 버퍼에 애초에 없다. 따라서 개발자 의도에 대한 서술은 전부 코드 동작에서 유도한 추론이며, `GAME_STRUCTURE.md`는 그럴 때마다 "추정"으로 표시한다.
- **토큰 사이 공백.** 디컴파일러 규칙(`NO_SPACE_BEFORE`/`NO_SPACE_AFTER`/단항 판정)으로 재구성한 것이다. 줄 번호·빈 줄·들여쓰기 깊이는 정확하지만 한 줄 안의 연산자 주변 공백은 원본과 다를 수 있다.

## 4. 프로젝트 설정과 자산 인벤토리

```bash
cd _dl && python3 inspect_assets.py
```

`extracted/project.binary`(magic `ECFG`)를 파싱해 ProjectSettings를 덤프하고,
스프라이트/오디오 크기 목록을 낸다. `gdc_decompile`의 `decode_variant`를 재사용하므로
`sys.path`에 `.`이 있어야 한다 — 즉 이것도 `_dl/`에서 실행.

팩 안 자산의 magic별 분류:

| magic | 확장자 | 내용 |
|---|---|---|
| `ECFG` | `project.binary` | ProjectSettings |
| `GST2` | `.ctex` | 텍스처 30개 (WebP 임베드) |
| `RSRC` | `.sample` | 오디오 11개 (`AudioStreamWAV`) |
| `RSCC` | `.fontdata` | 폰트 3개 (Galmuri9 / 11 / 11-Bold) |

## 5. 디스크 배치

```
GAME_STRUCTURE.md        게임 구조 분석 본문 — 최종 산출물
unpacked_manifest.txt    110 엔트리 매니페스트 (unpack.py 출력)
recovered/*.gd           복원 소스 8개 — 정본
tools/                   분석·제출 스크립트
_dl/index.pck            원본 팩
_dl/index.js             Godot 웹 로더
_dl/extracted/           언팩 결과 (scripts/*.decompiled.gd 포함)
docs/                    이 폴더 — 운영 기록
```

> **중복 주의:** `tools/{unpack,gdc_decompile,inspect_assets}.py`는 `_dl/`의 사본과
> **바이트 단위로 동일**하다. 한쪽만 고치면 조용히 갈라진다. `recovered/*.gd`도
> `_dl/extracted/scripts/*.decompiled.gd`와 바이트 동일하며, `recovered/`를 정본으로 취급한다.

`tools/`에만 있는 것은 리더보드 클라이언트 2개다.

| 스크립트 | 용도 |
|---|---|
| `board_probe.py <대기초> <score> [rows] [name] [char]` | 단발 프로브 — 토큰 발급 → 대기 → 제출, 나이·비율·응답 출력 |
| `submit_run.py` | 토큰을 미리 대량 발급해 나이를 병렬로 쌓고, 목표 점수를 나이 순으로 재시도하는 스케줄러 |
