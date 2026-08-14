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
