# wt/rng — 난수를 바이너리에서 확인해 오프라인 솔버를 완성한다

> **이 파일부터 읽고, 이어서 `docs/wt-notes/wt-COMMON.md`를 읽어라** (빌드 명령·포트·금지
> 규칙·확정된 사실이 거기 있다). `docs/autopilot.md`는 **§3만** 읽으면 된다.
> `GAME_STRUCTURE.md`는 읽지 않아도 된다.

```
워크트리   .worktrees/rng
브랜치     wt/rng
포트       8783
닉네임     (등록까지 가면) 정호만세
목표       월드를 오프라인에서 재현 → 백트래킹 탐색으로 600점 trace 합성
```

## 무엇을 하는가 — 한 문장

서버는 시드로 월드를 재현해 `rows`·`score`를 계산한다. **우리도 재현할 수 있으면** 브라우저로
주행하지 않고 **탐색으로** 경로를 만들 수 있다 — 죽으면 되감아 다른 분기를 시도하므로 성공이
확률이 아니라 계산이 된다. 지금 막혀 있는 것은 딱 하나, **난수 재현**이다.

## ★ 어디까지 됐고 무엇이 막혔나

`tools/sim.py`(약 480줄)가 이미 있다. **행 생성과 주행 중 난수 소모 순서를 전부 전사해 둔
상태**이고, `replay(seed, trace, ticks)`로 재현을 돌려 볼 수 있다. 막힌 것은 `RandomPCG`
클래스 하나다.

실측한 정답지 (클라이언트에서 별도 `RandomNumberGenerator` 인스턴스로 뽑았다):

```
seed 0    -> randf() 0.202271849, 0.125359401
seed 1    -> 0.329559088, 0.276594847
seed 2    -> 0.702882349, 0.519367278
seed 3    -> 0.499491125, 0.714925110
seed 255  -> 0.105341010, 0.926077783
seed 1000000919463405 -> 0.321377069, 0.733824670, 0.787940502, 0.822309911,
                         0.200582966, 0.443908006, 0.284934878, 0.604507029,
                         0.958626449, 0.452899516, 0.534789681, 0.318720460
   같은 시드로 randi_range(3,6) 8회: 4 6 4 5 3 5 3 5
```

**`seed 0 -> 0.202271849`가 핵심 단서다.** 표준 PCG32에서 `state = seed`라면 `output(0) = 0`
이므로 정확히 `0.0`이 나와야 한다. 안 나왔으므로 시드가 상태로 그대로 들어가지 않는다.

배제한 것 (다시 하지 마라): `state=seed` / `pcg32_srandom_r(seed, inc)` / `inc<<1|1` /
출력을 전진 후 상태에서 뽑기 / 앞 1~2개 버리기 / 다른 스트림 상수(`0xda3e39cb94b95bdb`) —
**randf와 randi_range 양쪽 모두 불일치**했다.

## ★★ 첫 번째로 할 일 — 알고리즘부터 확정한다

앞선 세션의 실수는 **"PCG32인데 시딩만 다르다"를 검증 없이 가정한 것**이다. 알고리즘 자체가
다를 수 있다. 엔진 바이너리가 답을 갖고 있다.

```bash
python3 - <<'PY'
d = open('_local/index.wasm','rb').read()      # 39MB
def leb128_s(v):                                # wasm의 i64 상수는 signed LEB128이다
    out=bytearray()
    while True:
        b=v&0x7f; v>>=7
        if (v==0 and not b&0x40) or (v==-1 and b&0x40): out.append(b); return bytes(out)
        out.append(b|0x80)
for name,v in [('PCG_MULT',6364136223846793005),('PCG_INC',1442695040888963407),
               ('PCG_STREAM',0xda3e39cb94b95bdb),
               ('XOSHIRO_A',0x2545F4914F6CDD1D),('SPLITMIX',0x9E3779B97F4A7C15),
               ('MURMUR',0xff51afd7ed558ccd)]:
    for label,pat in (('LEB',leb128_s(v)),('LE64',v.to_bytes(8,'little'))):
        print(f"{name:11s} {label:5s} {d.count(pat)}건")
PY
```

- **PCG 승수가 있으면** PCG32/PCG64는 맞고 **시딩만** 다르다. 그러면 남은 후보는 좁다:
  Godot의 `RandomPCG::seed()`가 `pcg.state`에 시드를 넣기 전에 섞거나, `randomize()`가
  이미 상태를 바꿔 놓은 뒤 `seed`가 그 위에 얹히는 형태다. **위 정답지 6개로 가설을 즉시
  판정할 수 있다** — 5개 시드가 전부 맞아야 한다.
- **PCG 승수가 없으면** 다른 알고리즘이다. `SPLITMIX`·`XOSHIRO` 상수를 찾아 그쪽으로 간다.
- 상수가 LEB128로 안 잡히면 함수가 상수를 데이터 섹션에 두었을 수 있다. `LE64` 카운트를 본다.

★ **`0.202271849`를 32비트 정수로 되돌리면** `rand()` 후보가 6~7개로 좁혀진다
(`v * 4294967295`, float32 반올림 때문에 범위가 생긴다). `seed 0`의 출력이 그 값이 되는
상태를 찾는 것이 목표다. 출력 함수는 상태의 상위 37비트만 쓰므로(하위 27비트는 다음 상태에만
영향) **rot(상위 5비트) 32가지를 훑으면 상위 비트가 유일하게 결정된다** — 역산이 가능하다.

## 만들 것

| | |
|---|---|
| 신규 | `tools/rng_probe.py` ← 위 상수 탐색 + 가설 판정(정답지 6개를 하드코딩해 자동 검사) |
| 수정 | `tools/sim.py` ← `RandomPCG` 클래스만. 나머지는 이미 전사돼 있다 |
| 신규 | `tools/solve.py` ← 안전 경로 탐색(백트래킹) + trace/ticks 출력 |
| 수정 | `docs/wt-notes/wt-rng.md` ← 맨 아래 "작업 기록" |

```python
# tools/sim.py 의 계약 — 이 시그니처는 이미 나머지 코드가 쓰고 있다. 바꾸지 마라
class RandomPCG:
    def __init__(self, seed: int)
    def rand(self) -> int              # uint32
    def randf(self) -> float           # float32 반올림까지 재현
    def randf_range(self, a, b) -> float
    def randi_range(self, a, b) -> int
replay(seed, trace, ticks, start_row=0) -> dict   # rows/score/bonus/ticks/cause/consumed
```

## ★★ 검증 — 이 순서를 지켜라

```bash
# 1) 난수 단독. 정답지 6개 시드가 전부 맞아야 한다
python3 tools/rng_probe.py

# 2) 월드 재현. 실제 주행을 그대로 되돌려 rows·score·소비된 입력 수가 일치해야 한다
python3 tools/sim.py /tmp/valcases.jsonl
```

**검증 데이터는 실서버 없이 공짜로 만든다.** 이미 구현돼 있다:

```bash
PORT=8783 MOCK_START=1 BLOCK_POST=1 DUMP_BODIES=/tmp/valcases.jsonl \
  python3 tools/local_proxy.py &
# 브라우저: http://127.0.0.1:8783/?bot=1&bt=40&bsub=1&bloop=1&bchar=peccy&bn=valcase
#   -> 주행마다 (seed, trace, ticks, rows, score)가 /tmp/valcases.jsonl 에 쌓인다
# 브라우저: http://127.0.0.1:8783/?bot=1&bdump=1&bchar=peccy
#   -> [rngdbg]/[seedmap]/[rowdbg] 가 콘솔에 찍힌다 (난수열·행 데이터 정답지)
```

★ **`[rowdbg]`가 2단계 디버깅의 핵심이다.** 난수가 맞는데 재현이 어긋나면 소모 **순서**가
틀린 것이다. 행별 `kind/blocked/lane_dir/lane_speed/spawn_t/rail_t/entities`를 대조하면
어느 행에서 처음 갈라지는지 한 번에 보인다.

★ **변이 검증**: `sim.py`의 `_build_grass`에서 장식 루프의 `randf_range` 2개 중 하나를 지워
보라. 그 뒤 행부터 전부 어긋나야 한다. 안 어긋나면 그 코드는 실행되지 않고 있다.

## 뚫린 뒤 — 탐색은 이렇게 짠다

`replay()`가 정확해지면 `solve.py`는 순수 계산이다.

- 상태 복제가 필요하다. `Game`은 순수 파이썬이므로 `copy.deepcopy`로 체크포인트를 뜬다
  (틱 되감기보다 훨씬 싸다).
- 그리디로 전진하다 죽으면 마지막 체크포인트로 돌아가 **다른 선택**을 시도한다
  (전진/좌/우/대기, 대기 틱수도 분기다).
- 목표는 `score() >= 600`. 그 시점의 `input_trace`와 `tick_count`가 그대로 제출값이다.
- **제출 전에 엔진으로 한 번 확인해라** — `?bseed=<시드>`로 그 trace를 `replay_mode`에
  먹여 같은 점수가 나오는지 본다. `wt/search`가 그 배관을 만들고 있으니, 없으면
  `python3 tools/sim.py`의 재현 일치로만 판단하고 제출은 사용자에게 확인을 받아라.

제출은 `tools/board_probe.py`가 아니라 **Godot과 같은 바디 형태**로 보내야 한다
(`docs/leaderboard-api.md` §6의 `godot_json`: 키 정렬 + 공백 없음 + `v:3`·`ticks`·`trace`).
`tools/local_proxy.py`가 클라이언트 요청을 그대로 중계하므로, 직접 POST할 때는
`tools/submit_target.py`의 `godot_json()`을 재사용해라.

## ★★★ 절대 건드리지 않는 파일 (이 태스크 고유)

```
patch/bot_game.part.gd    wt/bot 소유. 덤프를 더 뽑으려고 고쳐야 하면 **로컬에서만** 고치고
                          커밋하지 마라 (git checkout -- 로 되돌린 뒤 커밋한다)
patch/bot_main.part.gd    wt/search 소유
tools/make_bot_patch.py   wt/search 소유
```

COMMON의 금지 목록도 그대로 적용된다.

## 완료 조건

1. **알고리즘 판정 결과를 먼저 보고한다** (wasm에서 어떤 상수를 찾았는지). 뚫리지 않아도
   이것 자체가 결론이다 — "무엇이 아니었는지"를 기록하면 다음 시도가 그만큼 짧아진다
2. `python3 tools/rng_probe.py`가 정답지 6개 시드를 전부 맞춘다
3. `python3 tools/sim.py /tmp/valcases.jsonl`이 **전건 일치**한다
4. `git status`에 "만들 것" 표 밖의 파일이 없다
5. 아래 "작업 기록"을 채운다 — 특히 **시드→상태 함수가 무엇이었는지**
6. `wt/rng`에서 커밋하고 브랜치명·커밋 해시를 보고한다

**막히면 3시간 안에 중단하고 보고해라.** 이건 뚫리면 판을 뒤집지만 안 뚫려도 다른 두
워크트리가 목표를 노리고 있다. 매몰비용을 늘리지 마라.

---

## 작업 기록

**뚫렸다.** 알고리즘은 PCG32가 맞았지만 **시딩만 다른 것이 아니었다.** 틀린 것이 셋이고,
막힘의 진짜 원인은 시딩이 아니라 `randf()`였다. 아래 근거는 전부 추측이 아니라
`godotengine/godot` **`4.7.1-stable` 태그의 원본**이다.

### 1. 알고리즘 판정 — wasm 상수 (완료 조건 1)

```
PCG_MULT   (6364136223846793005)  LEB128 143건, LE64 0건   ★
PCG_INC    (1442695040888963407)  LEB128   6건, LE64 1건   ★
PCG_STREAM / XOSHIRO_A / SPLITMIX / MURMUR      전부 0건
```

→ **PCG32 계열이 맞다.** 그래서 남은 문제는 시딩과 출력 함수뿐이고, 실제로 둘 다 달랐다.
`tools/rng_probe.py` 1단계가 이 스캔이다.

### 2. 시드→상태 함수 (완료 조건 5)

`RandomPCG::seed()`는 `pcg.state = p_seed`가 **아니다.** `pcg32_srandom_r(&pcg, seed, current_inc)`를
부르고, `current_inc`는 `RandomNumberGenerator`의 기본값 `PCG_DEFAULT_INC_64`다.

```
INC2   = (1442695040888963407 << 1) | 1 = 0x280AF6FDEECF029F   ← inc 레지스터 값
state0 = ((INC2 + seed) * 6364136223846793005 + INC2) mod 2^64
```

`pcg32_srandom_r`이 state=0에서 한 번 전진(→ state=INC2)하고, 시드를 **더한 뒤**, 다시 한 번
전진하기 때문이다. 그래서 `seed 0`의 초기 상태가 `0x8C63D050560A5992`
(10116158231463745938)이고 첫 `randf()`가 0.0이 아니다 — 지시서가 지목한 그 단서다.

### 3. ★ 진짜 원인 — `randf()`가 `rand()`를 **두 번** 먹는다

```c
proto = rand();  if (proto == 0) return 0;
return ldexp((float)(rand() | 0x80000001), -32 - clz32(proto));
```

`rand() / 0xFFFFFFFF`가 아니다. **난수 소비 개수가 2배로 다르다.** 그래서 시딩을 정확히
맞춰도 두 번째 값부터 전부 어긋난다. 지시서의 "배제한 것" 목록에 `pcg32_srandom_r(seed, inc)`와
`inc<<1|1`이 이미 있었지만 그 판정을 **틀린 randf로** 했기 때문에 통과할 수가 없었다.
`tools/rng_probe.py` 3단계가 시딩 7종 × randf 3종 격자를 전부 돌린다 — 21칸 중 통과는
`(srandom(inc<<1|1), ldexp)` **한 칸**뿐이다. 이 표가 "무엇이 아니었는지"의 정본이다.

### 4. `randi_range`는 기각 표본이다

`pcg32_boundedrand_r`: `threshold = -n % n`, `r < threshold`면 **버리고 다시 뽑는다.**
`rand() % n`이 아니다. n이 2의 거듭제곱이면 같지만 **9·7·6·5·3에서 갈라지고**, 풀밭의
Fisher-Yates가 `randi_range(0, i)`(i=8..1)로 정확히 그 경우를 쓴다.

### 5. ★★ `recovered/` 는 낡았다 — 통합이 반드시 알아야 할 것

`recovered/*.gd` ≠ `_dl/extracted/scripts/*.decompiled.gd`. CLAUDE.md는 둘이 바이트
동일이라고 하지만 **지금은 아니다. 현행 게임은 `_dl/extracted/` 쪽이다.**
(`tools/make_bot_patch.py`는 이미 `_dl/extracted/`를 읽으므로 빌드는 영향 없다.)

차이가 이 태스크의 성패를 갈랐다. 현행 빌드는 운영자가 **재현 가능하게** 고친 버전이다:

- `rng.seed = main.ranking.active_seed` — 낡은 쪽은 `rng.randomize()`라 시드와 무관했다
- `FIXED_DT = 1/60` 고정 틱 루프 + `tick_count`/`input_trace`/`replay_mode`
- 화면 흔들림이 `vrng`(별도 인스턴스)로 분리돼 월드 rng를 오염시키지 않는다
- `_update_snow`가 `_sim_tick` **밖으로** 나갔다 — 프레임 시간 의존이 시뮬레이션에서 빠졌다
- ★ `cols_pool.shuffle()`이 `rng.randi_range(0, i)` Fisher-Yates로 **교체됐다**

마지막 항목이 특히 중요하다. `Array.shuffle()`은 Godot의 **전역** RNG(`Math::rand()`)를 쓰므로
시드로 재현할 수 없다. 낡은 `recovered/`만 보면 "오프라인 재현은 원리적으로 불가능"이라는
**잘못된 결론**에 이른다. 현행 빌드에서 전역 RNG 소비자는 눈(snow)과 효과음 피치뿐이고 둘 다
시뮬레이션 밖이다. 그래서 **월드는 시드만의 함수다.**

### 6. `sim.py`에서 고친 것 — RandomPCG 외 2건 (둘 다 재현을 깨뜨리는 버그였다)

1. `_build_river`에 **물결 장식 루프가 빠져 있었다** (`row.gd:215`: `randi_range(2,4)` +
   회당 `randf_range` 2개). 난수 소모 순서가 강 행부터 어긋난다.
2. `replay()`가 trace 입력을 **한 틱 일찍** 넣었다. 엔진은 `_consume_input`에서
   `tick_count`가 **증가한 뒤**의 값으로 판정한다(`_next_input`). 이 한 틱 때문에 첫 검증이
   rows 40 대신 **24**로 나왔다. `_next_input()`을 그대로 옮겨 해결했다.

### 7. 검증 (완료 조건 2·3)

```
python3 tools/rng_probe.py            → 정답지 6개 시드 randf 전건 + randi_range 일치, exit 0
python3 tools/sim.py /tmp/valcases.jsonl → 6/6 일치, exit 0
python3 tools/pack.py --verify        → 바이트 동일 ✓
콘솔 Parse Error / SCRIPT ERROR       → 0건
```

`[rowdbg]` 대조로 초기 21행(-6..14)의 `kind/blocked/lane_dir/lane_speed/spawn_t/rail_t/
entities/ambush/pending_dir`이 **전부** 일치하는 것을 먼저 확인했고, 그 뒤 주행 재현이 맞았다.
정답지 6건은 **사망 틱까지 정확히** 일치한다(2881·2039·3401·3340·4387·2677) — 사망 틱이 맞으면
그 앞의 모든 틱이 맞은 것이다. 그래서 `sim.py`의 판정 조건에 `ticks`를 넣었다.
사인도 scroll/train/gorani/car 4종이 모두 들어갔고, 니어미스 보너스가 붙은 건(150=144+6,
152=150+2)도 포함이라 보너스 경로까지 검증됐다.

**변이 검증**도 했다: `_build_grass`의 장식 `randf_range` 하나를 지우면 6건 전부 rows 3에서
어긋나고, 되돌리면 6/6으로 복귀한다. 우연히 맞은 것이 아니다.

### 8. `tools/solve.py` — 탐색

`replay()`가 정확해졌으므로 경로 찾기는 순수 계산이다. 행동 단위는 복합이다:
`("move", 방향)`은 착지까지, `("wait", k)`는 k틱. 위험 판정은 **시뮬레이터 자신**에게
맡긴다(상태를 복제해 실제로 굴려 본다) — 별도 예측식이 본 시뮬레이션과 어긋날 여지를 없앤다.

**결과: 600점을 오프라인에서 합성했고, 그 trace를 엔진이 채점해 600점을 확인했다.**

```
python3 tools/solve.py <시드> --target 600 --width 8          (기본 mode=beam)

시드 1000000919842726 → score 600 rows 570 bonus 30 ticks 7914 trace 590개  261초
시드 1000000919874402 → score 600 rows 584 bonus 16 ticks 6897 trace 595개  274초
```

둘 다 `verify.ok = true`(만든 trace를 `sim.replay()`에 다시 먹여 자체 검산). 정체 구간 없이
**단계당 약 1행**으로 진행한다(deepcopy 0.305ms, sim_tick 0.0108ms 실측).

여기까지 오는 데 탐색 쪽에서 함정이 둘 있었고, 둘 다 **정체의 원인이 게임 난이도가 아니라
탐색 버그**였다:

1. **`--mode dfs`는 프런티어에 갇힌다.** 막힌 행에서 12^k 부분나무를 다 뒤지느라 위로
   못 올라간다 — 359행에서 6분 넘게 정체하며 노드 37만 개를 태웠다. 체크포인트를 동시에
   여러 개 살리는 빔으로 바꾸니 같은 행을 정체 없이 지났다. `--mode dfs`는 비교용으로 남겼다.
2. ★ **막힌 이동(bump)을 후보로 두면 안 된다.** `player.bump()`는 시계만 1틱 흘리고 아무
   상태도 바꾸지 않으므로 `("wait", 1)`과 **같다.** 그런데 "가장 싼 행동"이라서 동점
   정렬(`-cam_slack`, 즉 시간을 덜 쓴 쪽)에서 항상 이긴다. 그래서 8행의 4·5열이 막힌
   국면에서 **4열에 선 채로 전진만 무한 반복**했다 — 9틱을 쓰는 좌/우 이동(막힌 열을
   벗어나는 유일한 수)이 1틱짜리 bump에 계속 밀린 것이다. `do_move`가 bump를 False로
   보고하고 후보에서 빼자 즉시 풀렸다(7행 영구 정체 → 60초에 137행).

빔의 확장 단위는 **행 단위 복합 행동**이다: `k틱 대기 후 이동`(k는 0~254틱, 6틱 격자).
행동을 하나씩 확장하면 빔 24칸이 전부 "같은 자리에서 2~3틱씩 다르게 기다린 상태"로 채워져
**다양성이 붕괴**하고 시간이 한 단계에 2틱씩만 흐른다(실측). 대기를 확장 안으로 넣으면
한 번의 확장이 타이밍 공간을 다 덮으므로 그 함정이 사라진다.

### 8.1 ★ 엔진 교차 검증 — 합성 trace를 엔진이 600점으로 채점했다

`sim.py`가 클라이언트와 일치한다는 것과 **합성한 trace가 엔진에서 정말 600점이 된다**는 것은
다른 주장이다. 후자를 실제로 확인했다. `game.gd`에 이미 있는 `replay_mode`/`replay_inputs`에
trace를 먹이는 훅을 `patch/bot_game.part.gd`에 **로컬 전용으로** 넣고(`brep=1`,
`_local/trace.json`을 동기 XHR로 읽는다) 돌린 뒤 `git checkout`으로 되돌렸다 — 커밋에 없다.

```
우리 예측(sim.replay) : rows 590  score 600  bonus 10  ticks 7259  cause car  consumed 631
엔진 [run] 실측        : rows 590  score 600  bonus 10  ticks 7259  row 590
```

**사망 틱(7259)과 사인(car)까지 전부 일치한다.** trace가 끝난 뒤 입력이 없어 차에 치이는
것까지 같다. 이 훅은 원래 `patch/bot_main.part.gd`(= `wt/search` 소유) 자리이므로
통합 때 그쪽에 넣으면 상시 검증 수단이 된다.

정확히 말해 두면, 엔진에 먹인 trace는 **bump 수정 전** 빔이 만든 것이다(rows 590). 그 뒤
`solve.py`는 바뀌었지만 `sim.py`는 바뀌지 않았고, `trace → 점수`를 계산하는 것은 `sim.py`다.
즉 이 실험이 보증하는 것은 **`sim.py`의 재현이 600점 규모에서도 엔진과 정확히 일치한다**는
것이고, 그것이 무게를 지는 주장이다. 수정 후 solve.py가 낸 두 trace는 `sim.replay()`로
자체 검산만 했다(엔진 재확인은 하지 않았다) — 제출 전에는 §8.1 훅으로 한 번 더 돌려라.

### 9. 남은 것 / 통합이 알아야 할 것

- **제출용 trace를 엔진으로 확인하는 배관이 아직 없다.** `game.gd`에 `replay_mode`/
  `replay_inputs`가 이미 있으니 URL로 trace를 먹이는 훅 하나면 되는데, 그 자리는
  `patch/bot_main.part.gd`(= `wt/search` 소유)다. 그래서 손대지 않았다. 그 배관이 생기면
  `?bseed=<시드>` + trace로 같은 점수가 나오는지 한 번에 확인할 수 있다.
- 서버는 자기 재현으로 `rows`·`score`를 다시 계산한다. 우리 재현이 클라이언트와 **틱 단위로**
  일치하므로 서버와도 일치할 것으로 보지만 **실측되지 않았다(추정).** 그래서 이 세션은
  **제출하지 않았다** — 제출은 사용자 확인을 받아야 한다.
- 제출 시 `rows <= elapsed * 9.5`를 지켜야 한다. 600점(약 590행)이면 토큰 나이 **63초 이상**이
  필요하다. 오프라인 합성은 주행 시간이 들지 않으니 시드를 받고 그냥 기다리면 된다.
- `sim.py`는 `REAL_IS_DOUBLE = False`(웹 = real_t float)를 전제한다. 배정밀도 빌드를 만나면
  True로 두면 `randd`(rand 3회) 경로를 탄다.
