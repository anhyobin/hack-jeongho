# wt/search — 죽은 지점을 되감아 600점 경로를 구간별로 조립

> **이 파일부터 읽고, 이어서 `docs/wt-notes/wt-COMMON.md`를 읽어라** (빌드 명령·포트·금지
> 규칙·확정된 사실이 거기 있다). `docs/autopilot.md`는 **§2·§3·§5만** 읽으면 된다.
> `GAME_STRUCTURE.md`와 `tools/sim.py`는 읽지 않아도 된다(후자는 막힌 시도의 잔해다).

```
워크트리   .worktrees/search
브랜치     wt/search
포트       8782
닉네임     야호정호
목표       score 600 (= 실제 550행 안팎)
```

## 무엇을 만드는가 — 한 문장

**"550행을 한 번에 무사고 통과"를 "10~20행씩 40번 통과"로 바꾼다.** 월드가 시드만의
함수이므로, 죽으면 죽은 지점 앞까지의 trace를 고속 재생해 상태를 복원하고 **다른 지터로**
이어서 주행한다. 좋은 접두사는 버리지 않는다.

## 만들 것

| | |
|---|---|
| 신규 | `patch/bot_search.part.gd` ← 탐색 하네스 본체 |
| 수정 | `patch/bot_main.part.gd` ← 주행 시작/재시작 제어에서 하네스를 호출 |
| 수정 | `tools/make_bot_patch.py` ← 새 part 파일 등록 + 삽입점 1개 추가 |
| 수정 | `docs/wt-notes/wt-search.md` ← 맨 아래 "작업 기록" |

제안 시그니처(이름은 자유롭게 바꿔도 되지만 COMMON의 "계약" 표에 있는 이름은 유지한다):

```gdscript
# patch/bot_search.part.gd  (main.gd 뒤에 붙는다 — main이 Game 생성/파괴를 통제하므로)
var search_best: Array = []      # 지금까지 살아남은 최선의 trace [[tick, dircode], ...]
var search_best_rows := 0        # 그 trace가 도달한 행
var search_target := 600
func _search_begin() -> void     # 첫 주행 시작 (forced_seed = 실제 시드)
func _search_on_over(trace: Array, ticks: int, rows: int, score: int) -> void
                                 # 주행이 끝날 때마다 호출. 접두사를 잘라 다음 주행을 띄운다
func _search_prefix(trace: Array, drop_rows: int) -> Array
                                 # 죽은 지점에서 drop_rows 행만큼 앞의 trace를 돌려준다
func _search_submit() -> void    # 목표 달성 trace를 실제 토큰으로 재생해 제출한다
```

## ★ 이미 있는 것 (다시 만들지 마라)

### 1. 클라이언트에 재생 장치가 살아 있다 — 이 태스크의 전제다

`patch/game.gd`(= 복원된 원본)에 이미 있다. **새로 만들 필요가 없다.**

```gdscript
var replay_mode := false
var replay_inputs: Array = []      # [[tick, dircode], ...]
var replay_idx := 0

func _next_input() -> Vector2i:
    if replay_mode:
        if replay_idx < replay_inputs.size() and int(replay_inputs[replay_idx][0]) == tick_count:
            var d: Vector2i = DIRS[int(replay_inputs[replay_idx][1])]
            replay_idx += 1
            return d
        return Vector2i.ZERO
    ...
```

**규약 3가지 (여기서 실수하면 조용히 어긋난다):**

- 입력은 **틱이 정확히 일치할 때만** 소비된다. 어긋나면 그 입력은 **건너뛴다**(재시도 없음).
- `replay_mode`면 `_apply_move`가 **`input_trace.append`를 건너뛴다**(game.gd 283-284행).
  → 재생한 접두사는 기록되지 않으므로 **`input_trace`를 직접 채워 넣어야 한다.**
- `dircode`: `0=전진 1=후진 2=좌 3=우` (`_dircode`).

### 2. 토큰을 태우지 않고 같은 월드를 반복 재생할 수 있다

```gdscript
main.start_game(char_id, forced_seed)   # forced_seed >= 0
# -> ranking.claim_run(forced_seed): active_token = "TEST", active_seed = forced_seed
#    ranking.token 은 **건드리지 않는다** — 실제 토큰이 그대로 남는다
```

`active_token == "TEST"`면 `Ranking.submit`이 "offline"으로 즉시 빠지므로 **탐색 중 실수로
제출될 위험이 없다.** 최종 제출만 `forced_seed` 없이(`-1`) 실제 토큰으로 한다.

실제 시드는 `main.ranking.run_seed`(발급된 토큰의 시드)에서 읽는다. `_bot_wait_token()`이
토큰을 기다리는 함수이고 이미 `bot_main.part.gd`에 있다.

### 3. 봇 정책은 그대로 쓴다

`_bot_decide()`가 매 틱 판단한다(`wt/bot`이 개선 중이다). **내부를 건드리지 마라** —
블랙박스로 두고, 재생이 끝난 뒤 `game.replay_mode = false`로 넘기면 정책이 이어받는다.
지터가 `brng.randomize()`로 주행마다 다르므로 **같은 상태에서 다른 선택**이 나온다.

### 4. 이미 있는 재시작 배관

`bot_main.part.gd`에 있다: `_bot_autostart()`(토큰 대기 후 시작), `_bot_after_over(cause)`
(게임오버 후 재시작), `bot_seed`(고정 시드), `bot_did_submit`/`bot_pending_submit`(중복 제출 방지).
`main.last_trace`/`main.last_ticks`가 `on_game_over`에서 채워진다(원본 55-56행).

## ★ 왜 이 모양인가

파이썬으로 월드를 포팅하는 길은 막혔다(COMMON 5번 — Godot 4.7의 시드→상태 함수가 표준
PCG32가 아니다). **엔진 자신을 오라클로 쓰면 난수 재현 위험이 0이다.** 그리고 최종 trace가
실제 클라이언트가 만든 것이라 제출 경로도 검증 없이 그대로 통한다.

접두사를 재생으로 복원하는 것이 정당한 이유: 월드는 `rng`(시드)와 입력 시퀀스만의 함수다.
화면 흔들림용 `vrng`는 `randomize()`되지만 게임 상태에 영향이 없다(`world.position.x`만 바꾼다).

## ★★ 함정

### 고속 재생이 없으면 쓸 수 없다

12,000틱 접두사를 60틱/초로 재생하면 200초다. 40회 반복하면 2시간이 넘는다.
`_process`의 `guard < MAX_TICKS_PER_FRAME`(=8)이 프레임당 틱 수를 묶고 있다.

```gdscript
# patch/game.gd 원본 159행
while _sim_acc >= FIXED_DT and state == "play" and guard < MAX_TICKS_PER_FRAME:
```

**시뮬레이션 의미는 바뀌지 않는다**(같은 `FIXED_DT`, 같은 순서). 재생 중에만 상한을 올린다.
`tools/make_bot_patch.py`의 `INSERTS` 표로 이 줄을 치환하는 항목을 추가하면 된다 —
앵커가 정확히 1회만 나타나야 하고, 스크립트가 그것을 검사한다.

```python
# tools/make_bot_patch.py 의 INSERTS 구조 (이미 있는 형식)
INSERTS = {
    "game": [
        ("after",  "\t_apply_stage_visuals(stage_idx, true)\n", "\t_bot_setup()\n"),
        ("before", "\t_consume_input()\n",                      "\t_bot_decide()\n"),
        ...
    ],
    "main": [...],
}
```

`_sim_acc`도 함께 키워야 한다(dt가 프레임 시간이므로 그대로면 틱이 안 쌓인다).
`Engine.time_scale`을 올리는 방법이 가장 간단하다 — `_process(dt)`의 dt가 배로 들어온다.

### `start_game`은 Game 노드를 해제한다 — 대기 중인 코루틴이 함께 사라진다

`main.start_game`이 `game.queue_free()`를 부른다. `game.gd` 안에서 `await`로 기다리던
코루틴은 그때 통째로 없어진다. **실제로 제출 지연 8초를 기다리다 재시작에 먹혀 POST가
아예 나가지 않은 사고가 있었다.** 그래서 `bot_pending_submit` 가드가 있다.

→ 탐색 하네스는 **`main.gd` 쪽(= `bot_search.part.gd`)에 두어라.** main은 해제되지 않는다.

### 최종 제출 경로

```
1. start_game(char)                      # forced_seed 없이 → 실제 토큰·실제 시드
2. game.replay_mode = true
   game.replay_inputs = found_trace
   game.input_trace = found_trace.duplicate(true)     # ★ 재생은 기록되지 않는다
3. 재생이 끝나면 입력이 없으므로 스크롤로 사망 → on_game_over → _bot_after_death()가 제출
```

`_bot_after_death()`는 `score() < bot_target`이면 제출을 건너뛴다. 재생이 정확하면
`score()`가 탐색 때와 같아야 한다 — **다르면 재생이 어긋난 것이므로 제출하지 말고 원인을 찾아라.**

### 실제 시드로 탐색해야 한다

임의 시드로 찾은 경로는 실제 토큰의 월드에서 무의미하다. 순서는:
**토큰 발급 대기 → `run_seed` 읽기 → 그 시드로 탐색 → 같은 토큰으로 제출.**
토큰 TTL은 1,579초는 확실히 유효하고 3,976초는 만료였다. **탐색이 길어지면 TTL을 넘긴다** —
탐색 시간을 재고, 넘길 것 같으면 새 토큰을 받아 시드를 갱신하고 탐색을 다시 시작해야 한다.
(이것이 이 방법의 가장 큰 실무 리스크다. 고속 재생이 그래서 필수다.)

## ★★★ 절대 건드리지 않는 파일 (이 태스크 고유)

```
patch/bot_game.part.gd    wt/bot 소유다. 판단 로직을 고치면 통합에서 충돌한다
                          필요한 훅은 전부 main 쪽에서 만들 수 있다 (game.replay_mode 등은
                          원본 game.gd의 공개 변수라 main에서 그냥 대입하면 된다)
```

COMMON의 금지 목록도 그대로 적용된다.

## 검증

```bash
python3 tools/pack.py --verify        # 재패커 무결성 (make_bot_patch.py를 고쳤으니 특히)
python3 tools/make_bot_patch.py && python3 tools/pack.py -o _local/index.241563a7.pck \
  --text scripts/game.gd=patch/game.gd --text scripts/main.gd=patch/main.gd
# index.html fileSizes 갱신 (COMMON "빌드와 실행")
PORT=8782 MOCK_START=1 BLOCK_POST=1 python3 tools/local_proxy.py &
f=$(ls -t .playwright-mcp/console-*.log | head -1); grep -c "Parse Error\|SCRIPT ERROR" "$f"
```

**★ 첫 관문 — 이것부터 통과시켜라(탐색보다 먼저다):**

> 고정 시드(`?bseed=<정수>`)로 한 주행의 trace를 얻고, **같은 시드로 그 trace를 재생**해
> `rows`·`score`·사망 틱이 **정확히 같은지** 확인한다.

같지 않으면 재생 규약을 잘못 쓴 것이고(틱 일치·`input_trace` 채우기·`replay_idx`),
그 상태로 탐색을 만들면 전부 헛수고다. 검증 데이터는 연습 모드가 공짜로 만들어 준다 —
`DUMP_BODIES=/tmp/valcases.jsonl`을 켜고 `?bsub=1&bt=30`으로 돌리면 제출 바디
(`seed`·`trace`·`ticks`·`rows`)가 파일에 쌓인다.

★ **변이 검증**: 재생할 trace의 한 항목의 틱을 1 늘려 보라. 그 입력은 건너뛰어지므로
`rows`가 **줄어야** 한다. 안 줄면 재생이 실제로는 적용되지 않고 있다는 뜻이다.

## 완료 조건

1. 위 "첫 관문"(재생 동일성)을 통과했고 그 로그를 작업 기록에 남겼다
2. 탐색이 실제로 접두사를 이어붙여 도달 행을 늘리는 것을 보였다(회차별 도달 행 기록)
3. `git status`에 "만들 것" 표 밖의 파일이 없다
4. 아래 "작업 기록"을 채운다
5. `wt/search`에서 커밋하고 브랜치명·커밋 해시를 보고한다
6. `야호정호 600` 등록에 성공하면 캐시 우회 보드 조회 결과를 함께 보고한다

---

## 작업 기록

<!-- 세션이 채운다. 공유 문서(docs/leaderboard-api.md 등)에 쓰지 마라 — 100% 충돌한다. -->

### 결과 — `야호정호 602` 보드 1위 등록 (2026-08-14 16:00:46 KST)

```
POST /api/scores -> 200 {"ok": true, "rank": 1, ...
  {"name":"야호정호","score":602,"rows":562,"stage":28,"char":"peccy",
   "ts":1786690846,"elapsed":253.4,"verified":true,"rep":0,"rep_why":"정상 ...
캐시 우회 조회 (GET api/scores?cb=...):
  1. 야호정호  score=602 rows=562 stage=28 elapsed=253.4 verified=True  08-14 16:00:46
  2. 호호호    score=502 rows=502 stage=25 elapsed=107.5 verified=True
```

실서버 접촉은 **`api/start` GET 1회 + POST 1회**뿐이다(그 뒤 게임오버 화면이 보드를
1회 조회한다). 나머지는 전부 `MOCK_START=1` 프록시(포트 8782)에서 돌았다.

### 첫 관문 — 재생 동일성 (탐색보다 먼저 통과시켰다)

`?bot=1&sv=1&bseed=777001` 한 방으로 세 주행이 자동으로 이어진다(1차 주행 → 같은
시드로 그 trace 재생 → 변이 재생).

```
[gate] 1차 주행 rows=67 score=71 ticks=2236 trace=78건
[gate] 2차 재생 rows=67/67 score=71/71 ticks=2236/2236 -> 동일 PASS
[gate] 변이: 1번째 항목 tick 118 -> 119 (앞 항목과의 간격 8)
[gate] 변이 재생 rows=2 (원본 67) -> 줄었다 PASS
```

변이 검증은 **앞 홉과의 간격이 정확히 8틱인 항목**을 골라 +1 한다. 그러면 늘린 틱에
플레이어가 홉 중이라 `_consume_input`이 아예 불리지 않고 `replay_idx`가 그 항목에
걸려 뒤 입력이 전부 버려진다. 간격 9인 항목을 고르면 **1틱 지연으로 끝나 rows가 줄지
않는다** — "한 항목 +1이면 건너뛴다"는 무조건 참이 아니다.

### 회차별 도달 행 (접두사 이어붙이기가 실제로 프런티어를 밀어 올린다)

```
연습 seed 777001  [108, 108, 108, 108, 548]                        5회차 / 7초  -> score 600
연습 seed 424242  [256, 319, 318, 310, 478, 478, 556]              7회차 / 20초 -> score 600
실서버 seed 2284936702885992
                  [22, 22, 22, 22, 58, 58, 58, 58, 108, 190, 413, 562]
                                                                  12회차 / 15초 -> score 602
```

한 회차가 약 1~3초다(60배속). 도달 행은 **단조 증가**한다 — 최선 trace를 버리지 않기
때문이다. 봇의 사망은 국소적이어서, 같은 지점에서 몇 번 막히다가 되감기가 깊어지는
순간 수십~수백 행이 한꺼번에 열린다(190 -> 413 -> 562).

### 통합이 알아야 할 것

1. **`tools/make_bot_patch.py`에 `replace` 모드가 생겼다.** `game.gd` 원본 159행의
   `guard < MAX_TICKS_PER_FRAME`을 `main.bot_tick_ok(self, guard)`로 치환한다. 앵커는
   여전히 1회만 나타나야 하고 스크립트가 검사한다. `PARTS` 표도 새로 생겼다 —
   `main.gd`는 이제 `bot_main.part.gd` + `bot_search.part.gd`를 이어 붙인다.
2. **`bot_tick_ok`이 조건의 맨 앞에 있는 것이 설계다.** `state != "play"`가 된 직후에도
   한 번 더 불리는 것이 **사망 틱 훅**이고, 거기서 즉시 다음 주행을 띄우면
   `on_game_over`의 1초 타이머가 깨어날 때 `_over_token`이 이미 달라져 있어
   `ui.show_game_over`와 그 뒤의 **`ranking.start_run()`이 실행되지 않는다.**
   → 주행마다 `api/start`가 한 번씩 새는 것을 막는 유일한 지점이다. 순서를 바꾸면
   40회 주행에 40번 실서버 토큰을 발급하게 되고 실제 토큰·시드도 날아간다.
   탐색이 꺼져 있으면 `guard < 8`을 그대로 돌려주므로 원본과 동일하게 동작한다.
3. **`bot_game.part.gd`는 한 줄도 건드리지 않았다.** 하네스가 쓰는 손잡이는 원본
   `game.gd`의 공개 변수(`replay_mode`/`replay_inputs`/`replay_idx`/`input_trace`/
   `_sim_acc`)와 `bot_game.part.gd`가 이미 노출한 변수(`bot_on`/`bot_submit`/
   `bot_name`/`bot_target`/`bot_hop_t`)뿐이다. 전부 main에서 대입한다.
4. **되감기는 "몇 개를 버리는가"가 아니라 "어느 행으로 돌아가는가"다.** 처음에
   `_search_prefix`를 "뒤에서 전진 홉 N개를 버린다"로 썼더니 **34회 연속 제자리**였다
   (`접두사=62행 -> rows=62(+0)`). 봇은 죽기 전에 비상 분기로 앞뒤로 진동하므로 꼬리의
   전진 홉을 버려도 최고 도달 행이 그대로 남는다. 지금은 최고점에서 `drop_rows`행
   아래에 **처음 닿는 지점**에서 자른다.
5. **되감기 폭은 훑어야 한다.** 실패가 쌓일 때 단조 증가시키면 한 번 깊어진 뒤 얕고
   싼 되감기를 다시 못 본다. `search_drop + rand(0,3) + (search_fail % 12) * 4`로
   6~53행을 순환한다.
6. **같은 접두사에서 다른 갈래를 보게 하는 손잡이는 `bot_hop_t` 하나다.** 인계 시점에
   `g.bot_hop_t = g.tick_count + rand(0,12)`로 첫 홉 시각만 흔든다. `_bot_decide`
   내부는 블랙박스로 두었다. `brng`의 `bot_gap ∈ {8,9}`와 합쳐 갈래가 갈린다.
   trace에 합성 입력을 끼워 넣는 방식은 **쓰지 않았다** — 서버가 trace의 각 항목을
   어떻게 보는지 모르는데 bump가 될 수도 있는 가짜 입력을 넣을 이유가 없다.
7. **고속 재생은 시뮬레이션을 바꾸지 않는다.** `Engine.time_scale`이 `_process(dt)`의
   dt를 키우고 틱 상한이 그것을 소화한다. `FIXED_DT`·틱 순서·`rng` 소모가 그대로이므로
   재생 동일성(첫 관문)이 60배속에서도 정확히 성립한다. 실측 재생 속도는
   `time_scale × 60`틱/초 그대로였다(2,236틱 = 1.5초 @ 25배속).
8. **탐색은 벽시계보다 빠르다 — 그래서 제출 전에 토큰을 늙힌다.** 12,478틱은 208
   시뮬레이션초인데 25초에 돈다. 서버가 나이로 판정하는 규칙이 있으므로(`rows <=
   elapsed*9.5`, 그 밖의 나이 검사가 더 있어도 이상하지 않다) 제출 직전에
   `max(rows/9.4, ticks/60) + 45`초까지 기다린다. 토큰의 **첫 필드가 발급 epoch**이라
   나이를 클라이언트가 직접 알 수 있다(`_search_token_age`). 실측 `elapsed 253.4`.
9. **서버 응답에 `verified: true`와 `rep`/`rep_why: "정상 …"`이 새로 있다.**
   (`docs/leaderboard-api.md`는 건드리지 않았다 — 정본 갱신은 통합이 판단할 일이다.)
10. 오제출 4중 가드: 탐색 주행은 `claim_run(forced_seed)`로 `active_token == "TEST"`
    (submit이 "offline"으로 빠진다) + `game.bot_submit = false` + `game.bot_name = ""`,
    그리고 최종 제출은 `bsub=1`·닉네임·실제 토큰 3개가 모두 있어야 나간다.
11. `patch/game.gd`·`patch/main.gd`·`_local/index.html`은 COMMON 지시대로 **커밋하지
    않았다**(빌드 산출물). `git status`에 수정 상태로 남아 있는 것이 정상이다.

### 새 URL 파라미터 (`docs/autopilot.md` §5의 표에 더해서)

| 파라미터 | 뜻 |
|---|---|
| `ss=1` | 체크포인트 탐색 |
| `sv=1` | 재생 동일성 검증(첫 관문) 3연속 주행 |
| `sspd=<수>` | `Engine.time_scale` (기본 25). 60까지 실측 안정 |
| `sdrop=<행>` | 되감기 기본 행수 (기본 6) |
| `sttl=<초>` | 탐색 마감 (기본 1200) |
| `smin=<초>` | 제출 시점 최소 토큰 나이. 생략하면 자동 계산 |
| `stok=<토큰>` `sseed=<정수>` | 제출에 쓸 실제 토큰과 그 시드를 주입한다 |

```bash
# 첫 관문
http://127.0.0.1:8782/?bot=1&sv=1&bseed=777001&bt=99999&sspd=25
# 연습 탐색 (MOCK_START=1 BLOCK_POST=1)
http://127.0.0.1:8782/?bot=1&ss=1&bseed=777001&bt=600&sspd=60&sdrop=6&sttl=300
# 실서버 1회 — 토큰은 curl로 미리 발급하고 프록시는 MOCK_START=1로 둔다
curl -s "https://d15csla760jzen.cloudfront.net/api/start"
http://127.0.0.1:8782/?bot=1&ss=1&bsub=1&bn=<닉>&bchar=peccy&bt=600&sspd=60&sttl=600 \
  &stok=<token>&sseed=<seed>
```

### 남은 일 / 한계

- 실서버 시드 1개(2284936702885992)에서만 제출을 검증했다. 다른 시드에서도 12회차
  이내에 600점이 나오는지는 표본 3개(연습 2 + 실서버 1)뿐이다.
- 사망 원인별 되감기 전략은 없다. `[dead] kind=` 로그가 있으니 강(익사)·레일(기차)에
  따라 되감기 폭을 다르게 주면 회차가 더 줄 것이다.
- 토큰 나이 대기(약 3.5분)가 전체 시간의 대부분이다. 나이 검사가 실제로 `rows`만
  본다면 `smin`을 `rows/9.4 + 여유`로 낮춰 1분으로 줄일 수 있다(미검증).
