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

<!-- 세션이 채운다. 공유 문서(docs/leaderboard-api.md 등)에 쓰지 마라 — 100% 충돌한다. -->
