# 웨이브 1 공통 지시서 — 워크트리 2개가 전부 읽는다

> **각 세션은 자기 지시서(`wt-bot.md` / `wt-search.md`)를 먼저 읽고 이 파일로 온다.**
> 여기 있는 사실은 전부 이미 실측된 것이다. **다시 조사하지 마라.**

## 무엇을 하는 단계인가

리더보드(`https://d15csla760jzen.cloudfront.net/`)에 **600점**을 등록한다. 두 워크트리가
**서로 다른 방법**으로 같은 목표를 노린다 — 어느 쪽이 먼저 되는지가 이 웨이브의 질문이다.

| 워크트리 | 방법 | 닉네임 |
|---|---|---|
| `wt/bot` | 엔진 안 온라인 봇을 강하게 만들어 **한 주행으로** 600점 | `정호야호` |
| `wt/search` | `replay_mode`로 죽은 지점을 되감아 **구간별로** 600점 경로를 조립 | `야호정호` |

600점은 **실제로 약 550행을 넘어야** 나온다(`score = 넘은 행 + 니어미스 보너스`, 보너스는
실측 행수의 1/12쯤). 점수를 부풀려 보내는 길은 막혀 있다 — 아래 "확정된 사실" 1번.

## 빌드와 실행 — 이 4줄이 전부다

```bash
python3 tools/make_bot_patch.py          # 디컴파일 원본 + patch/bot_*.part.gd -> patch/{game,main}.gd
python3 tools/pack.py -o _local/index.<HASH>.pck \
        --text scripts/game.gd=patch/game.gd --text scripts/main.gd=patch/main.gd
#   ↑ <HASH>는 _local/ 안의 실제 pck 파일명을 그대로 쓴다 (index.241563a7.pck)
python3 - <<'EOF'
import re, os
p='_local/index.html'; s=open(p,encoding='utf-8').read()
n=os.path.getsize('_local/index.241563a7.pck')
open(p,'w',encoding='utf-8').write(re.sub(r'("index\.241563a7\.pck": )\d+', lambda m: m.group(1)+str(n), s))
EOF
#   ↑ index.html의 fileSizes를 새 pck 크기로 고친다. 빼먹으면 로더가 멈춘다
PORT=<자기포트> MOCK_START=1 BLOCK_POST=1 python3 tools/local_proxy.py   # 연습(실서버 무접촉)
```

그리고 브라우저(Playwright MCP)로 `http://127.0.0.1:<자기포트>/?bot=1&...`를 연다.
파라미터는 `docs/autopilot.md` §5에 표로 있다 — `bot/bt/br/bn/bsub/bloop/bchar/bseed/bdump`.

**셋업은 이미 끝나 있다.** `.gitignore`로 빠지는 입력 3개를 워크트리에 복사해 두었고,
`pack.py --verify`(원본 바이트 복원)와 pck 빌드가 양쪽에서 통과하는 것을 확인했다.

```
_dl/extracted/     make_bot_patch.py의 입력 (디컴파일된 원본 8개)
_dl/index.pck      pack.py의 베이스 (--verify와 빌드 양쪽에서 읽는다)
_local/            클라이언트 사본. 패치된 pck만 각자 빌드한다
```

지웠거나 깨졌으면 메인 작업 디렉터리에서 다시 복사한다(재다운로드·재디컴파일은 필요 없다):

```bash
cp -R /Users/anhyobin/dev/hack-jeongho/_dl/extracted _dl/
cp /Users/anhyobin/dev/hack-jeongho/_dl/index.pck _dl/
```

## 포트 — 겹치면 서로의 주행을 망친다

```
wt/bot     8781
wt/search  8782
```

8777·8778·8779는 **다른 세션들이 쓴다**(이 레포는 지금 3개 이상의 세션이 동시에 만진다).

★★ **`pkill -f local_proxy.py` 를 절대 쓰지 마라.** 다른 세션의 프록시까지 죽는다 —
실제로 그렇게 죽여서 남의 주행을 끊은 사고가 있다. 종료는 포트로 PID를 찾아서 한다:

```bash
lsof -nP -iTCP:8781 -sTCP:LISTEN -t | xargs -r kill
```

## ★★★ 절대 건드리지 않는 파일

**고치면 통합에서 충돌하거나, 다른 세션이 이미 덮어쓴 전례가 있다. 읽기만 한다:**

```
docs/leaderboard-api.md    서버 규칙 정본. 최근 80커밋에서 8회 변경된 허브다
docs/submissions-log.md    제출 감사 기록. 다른 세션이 통째로 덮어써 기록이 사라진 적 있다
CLAUDE.md, README.md       프로젝트 규칙·요약. 통합 담당(베이스 세션)이 쓴다
recovered/*.gd             원본 복원본. 정본이며 수정 대상이 아니다
tools/pack.py              재패커. 원본을 바이트 단위로 복원하는 것이 검증된 상태다
tools/sim.py               파이썬 포팅 시도. 아래 "확정된 사실" 5번을 보고 손대지 마라
```

**커밋하지 않는 것** (빌드 산출물이라 매번 바뀐다. 통합에서 베이스가 한 번 생성한다):

```
patch/game.gd, patch/main.gd     make_bot_patch.py가 만든다
_local/index.html                fileSizes만 바뀐다
_local/*.pck                     .gitignore 되어 있다
```

## 네가 건드릴 파일

```
wt/bot      patch/bot_game.part.gd            (봇 판단 로직)
            docs/wt-notes/wt-bot.md           (작업 기록)

wt/search   patch/bot_search.part.gd  (신규)  (체크포인트 탐색 하네스)
            patch/bot_main.part.gd            (주행 시작·재시작 제어)
            tools/make_bot_patch.py           (새 part 파일 등록 + 삽입점 1개)
            docs/wt-notes/wt-search.md        (작업 기록)
```

## 계약 — 양쪽이 머지되므로 이 이름들을 바꾸지 마라

`wt/search`의 하네스가 `wt/bot`의 정책을 **블랙박스로** 호출한다. 아래 이름이 계약이다.

| 심볼 | 있는 곳 | 뜻 |
|---|---|---|
| `_bot_decide()` | `bot_game.part.gd` | 매 틱 호출. `pending_input`만 세운다 |
| `_bot_setup()` | `bot_game.part.gd` | `Game.setup` 끝에서 1회. URL 파라미터를 읽는다 |
| `_bot_after_death()` | `bot_game.part.gd` | `kill_player`에서 1회. 목표 달성 시 제출한다 |
| `bot_done` / `bot_target` / `bot_rows` | `bot_game.part.gd` | 정지 조건 |
| `bot_name` / `bot_submit` | `bot_game.part.gd` | 제출 설정 |
| `brng` / `bot_start_t` / `bot_gap` | `bot_game.part.gd` | **월드 rng와 분리된** 지터용 난수 |
| `bot_seed` / `bot_did_submit` / `bot_pending_submit` | `bot_main.part.gd` | 재시작·제출 상태 |
| `_bot_qs(key)` / `_bot_flag(key)` | 양쪽에 각각 있다 | URL 파라미터 읽기 |

`wt/bot`은 `_bot_decide` **내부**를 자유롭게 바꿔도 된다. 이름과 "pending_input만 세운다"는
성질만 유지하면 된다.

## ★★ 재조사 금지 — 확정된 사실

### 1. 점수를 부풀려 보내는 길은 막혔다

서버는 `api/start`의 `seed`로 월드를 재현하고 제출된 `trace`를 되돌려 **`rows`와 `score`를
직접 계산**한다. 정합성 상한(`score ≤ rows*2+40`) 안에 있어도 실제 점수와 다르면 거부된다.

```
503점 / rows 240 (실제 250점 주행)  -> 403 {"ok":false,"error":"rejected"}
200점 / rows  85 (부풀림)           -> 403 rejected
200점 / rows 188 (정직)             -> 200 ok
```

**따라서 제출값은 클라이언트가 계산한 `score()`·`rows_crossed()`를 그대로 쓴다.**

### 2. `ok: true`가 오면 저장된 것이다 — 보드에 안 보여도 재제출하지 마라

`GET api/scores`는 CloudFront가 낡은 사본을 준다(`x-cache: Error from cloudfront`,
`cache-control: no-cache`가 붙어 있어도 그렇다). 세 세션이 각각 "버려졌다"고 오판해
재제출했고, 그래서 같은 목표에 중복 항목이 4건 남았다. **삭제 API는 없다.**

```bash
curl -s "https://d15csla760jzen.cloudfront.net/api/scores?cb=$RANDOM$RANDOM"   # 캐시 우회
```

응답의 `rank`도 믿을 수 없다(1위로 저장된 항목이 `rank 4`를 받았다). 순위는 위 조회로 본다.

### 3. 게임 내부 — 봇 설계의 근거

- **홉 중에는 hazard 검사를 건너뛴다**(`game.gd:208`의 `if not player.hopping and not player.dead`).
  `HOP_TICKS = 8`이므로 8틱마다 끊김 없이 전진하면 **중간 행은 착지하는 한 틱만** 노출된다.
- **스크롤 사망**: `568 + (cam_row - row) * 64 > 1000`, 즉 `cam_row - row > 6.75`.
  홉 직후 `cam_row ≈ max_row - 3`이고 자동 스크롤 상한이 0.62행/초 →
  **한 칸에서 약 15초를 버틸 수 있다.**
- **자동 스크롤**: `elapsed > 3.0`부터 `auto = min(0.1 + max_row*0.004, 0.62)` 행/초.
- **매복**: 풀밭 착지가 `trigger_ambush`를 깨워 0.45초 뒤 고라니가 화면 밖에서 등장한다.
  중앙 열까지 도달에 약 130틱. 즉 **통과만 하면 안전하고, 머무르면 위험하다.**
- **히트박스** `half`: car_red/blue/white/taxi **56**, truck **84**, bus **88**,
  고라니 **44**(코드 고정값), 통나무 **96**(scale 0.65면 62), 기차 **415**.
  사망 판정은 `abs(e.x - px) < half + 18`.
- **강**: 통나무에 실려 `x < 34` 또는 `x > 606`이면 익사한다. `log_at`은 `half + 4`까지 인정.
- **레일**: `idle → warn(1.25초) → run`. 기차는 폭 830px이라 좌우로 못 피한다.

### 4. 봇의 현재 실력과 사인 (`wt/bot`이 넘어야 하는 기준선)

도달 행: **87, 96, 116, 119, 121, 136, 139, 166, 188, 192, 250** (구간 계획 도입 후).
사인은 `car`와 `scroll`이 대부분이다. 확인된 사망 패턴:

- 도로에 정지했다가 창이 만료되고 치인다(빠른 차선 v=155~356)
- 막힌 열에 갇힌다 — 앞이 나무, 좌우도 나무, 스크롤 여유를 다 써서 후퇴도 불가
- 계획 대기 중 통나무에 밀려 익사(표류 마감을 감시하지 않던 버그는 고쳤다)

### 5. 파이썬 포팅은 막혀 있다 — 다시 시도하지 마라

Godot 4.7의 `RandomNumberGenerator`는 시드를 그대로 상태로 쓰지 않는다. 실측:

```
seed 0   -> randf() 0.202271849, 0.125359401     ← state=seed 라면 정확히 0.0 이어야 한다
seed 1   -> 0.329559088, 0.276594847
seed 2   -> 0.702882349, 0.519367278
seed 3   -> 0.499491125, 0.714925110
seed 255 -> 0.105341010, 0.926077783
```

표준 PCG32 초기화 6변형(state=seed / srandom / inc<<1|1 / post-advance / 드롭 0~2 /
다른 스트림 상수)과 `randi_range` 정수열까지 **전부 불일치**했다. 시드→상태 함수를 역산하려면
64비트 상태 복원 탐색이 필요하다. `tools/sim.py`는 그 시도의 잔해이고, **월드 재현은
실제 엔진에게 맡기는 것이 옳다**(그것이 `wt/search`의 전제다).

## 실서버 규칙 — 각 세션 판단으로 제출한다

사용자가 "세션 판단으로 바로 제출"을 선택했다. 다만 **IP와 보드는 공유된다**:

1. **개발은 전부 `MOCK_START=1 BLOCK_POST=1`로 한다.** 실서버는 최종 주행에만 쓴다.
2. `api/start`에 IP 단위 제한이 있다(`429 too many starts`). 주행 사이 **10초 이상** 띄우고,
   429가 오면 백오프한다. 다른 세션도 같은 IP를 쓴다.
3. 목표에 못 미치는 주행은 **제출하지 않는다.** `_bot_after_death`에 이미 가드가 있다
   (`score() < bot_target`이면 스킵). 이 가드를 풀지 마라 — 보드에 쓰레기가 영구히 남는다.
4. 제출 후 `ok: true`를 받으면 끝이다. 보드 확인은 캐시 우회로 하고, **안 보여도 재제출하지 마라**.

## 검증 — 자기 것만

이 레포에는 테스트 스위트가 없다. 검증은 다음 3개다.

```bash
# 1) 문법 — 브라우저 콘솔에 Parse Error가 0건이어야 한다
#    (콘솔 로그는 .playwright-mcp/console-*.log 로 저장된다)
f=$(ls -t .playwright-mcp/console-*.log | head -1); grep -c "Parse Error\|SCRIPT ERROR" "$f"

# 2) 재패커 무결성 — 원본을 바이트 단위로 복원해야 한다
python3 tools/pack.py --verify

# 3) 주행 실측 — 연습 모드로 최소 6회, 도달 행 분포를 기록한다
f=$(ls -t .playwright-mcp/console-*.log | head -1); grep -E "\[run\]" "$f" | sed 's/.*\[run\] //'
```

★ 실서버로 검증하지 마라. 연습 모드가 같은 코드·같은 엔진이다.

## 완료 조건 (양쪽 공통)

1. 위 검증 3개가 통과한다
2. `git status`에 자기 지시서의 "만들 것" 표 밖의 파일이 없다
   (`patch/game.gd`·`patch/main.gd`·`_local/index.html`은 커밋하지 않는다)
3. 자기 지시서 맨 아래 "작업 기록"을 채운다 — 특히 **통합이 알아야 할 것**
4. 이 워크트리에서 커밋하고 **브랜치명과 커밋 해시를 보고한다**
5. 600점 등록에 성공했으면 **보드 조회 결과(캐시 우회)를 함께 보고한다**
