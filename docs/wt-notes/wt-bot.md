# wt/bot — 온라인 봇을 강하게 만들어 한 주행으로 600점

> **이 파일부터 읽고, 이어서 `docs/wt-notes/wt-COMMON.md`를 읽어라** (빌드 명령·포트·금지
> 규칙·확정된 사실이 거기 있다). `docs/autopilot.md`는 **§3·§4·§5만** 읽으면 된다.
> `GAME_STRUCTURE.md`는 읽지 않아도 된다.

```
워크트리   .worktrees/bot
브랜치     wt/bot
포트       8781
닉네임     정호야호
목표       score 600 (= 실제 550행 안팎)
```

## 만들 것

| | |
|---|---|
| 수정 | `patch/bot_game.part.gd` ← **판단 로직만.** 이 파일 하나가 네 소유다 |
| 수정 | `docs/wt-notes/wt-bot.md` ← 맨 아래 "작업 기록" |

최종 산출물은 코드가 아니라 **보드에 올라간 `정호야호 600`** 이다.

## ★ 이미 있는 것 (다시 만들지 마라)

`patch/bot_game.part.gd`에 완성된 봇이 있다. 구조는 이렇다 — 읽고 이어서 고치면 된다.

```
_bot_setup()          URL 파라미터 읽기 + brng(지터 난수) 초기화
_bot_decide()         매 틱 판단. 아래 5단계 구조
  1  bot_hops 실행 중이면 계획된 홉 시각에 전진 (위험하면 계획 파기)
  2  _bot_plan_m() -> _bot_plan_chain() 으로 구간 계획을 세워 출발
  3  goal==0(열이 막힘) 또는 정체면 열을 옮긴다 (_bot_col_dir)
  4  안전하고 스크롤도 멀면 대기
  5  비상: 후보마다 _bot_hit_tick으로 첫 충돌 틱을 재서 가장 늦은 칸으로
_bot_after_death()    목표 도달 시 제출 (score() < bot_target 이면 스킵)
```

핵심 함수:

```gdscript
_bot_cell_safe(idx, px, k0, k1) -> bool     # k0..k1틱 사이 그 칸이 안전한가 (여유 BOT_MARGIN=12px)
_bot_hit_tick(idx, px, k0, kmax) -> int     # 처음 위험해지는 틱 (여유 없이 원본 판정)
_bot_plan_chain(m, x) -> Array              # 행마다 대기를 넣은 홉 시각 목록. 실패면 []
_bot_plan_m() -> int                        # 갈 수 있는 가장 먼 정지 지점까지의 거리
_bot_col_reach(from_row, col) -> int        # 그 열로 나무에 막히지 않고 갈 수 있는 연속 행수
_bot_seg_end(x) -> int                      # 멈춰도 되는 첫 앞 행까지의 거리 (0이면 막힘)
_bot_slack() -> float                       # 남은 스크롤 여유(행). 6.75 - (cam_target - row)
_bot_scroll_k() -> int                      # 스크롤이 잡기까지 남은 틱
```

**이미 고친 함정 11개가 `docs/autopilot.md` §4 표에 있다.** 같은 것을 다시 겪지 마라 —
특히 "절대 틱 vs 지속 시간", "기본값이 유효 상태처럼 보이는 필드", "좌우 왕복".

## ★ 왜 이 모양인가

`_sim_tick`이 홉 중에 hazard 검사를 건너뛰므로(COMMON 3번), 8틱마다 끊김 없이 전진하면
중간 행은 착지 한 틱만 노출된다. 그래서 **"도로에서 안전하게 기다릴 수 있는가"를 묻지 않고
"풀밭에서 다음 풀밭까지 구간 전체를 검증해 통째로 건넌다"** 로 설계했다. 이 구조로 바꾼 뒤
도달 행이 20~90행에서 240~354행으로 뛰었다. **이 전제를 버리지 마라.**

`_bot_plan_chain`은 그 위에 **행마다 대기 시간**을 얹은 것이다(고정 간격이면 4행 이상 구간에서
모든 행이 동시에 열리는 창을 요구해 거의 성립하지 않는다).

## 남은 약점 — 여기가 600점을 막고 있다

측정된 도달 행: **87, 96, 116, 119, 121, 136, 139, 166, 188, 192, 250**. 550행이 필요하다.

1. **막힌 열 함정이 사인 1순위다.** `reach=0`(앞 행이 나무) + 좌우도 나무 + 스크롤 여유 소진 →
   합법적인 수가 하나도 없어 비상 분기도 손을 못 쓴다. 실측: 78행 col 0, 93행 col 8, 159행 col 4.
   → `_bot_not_dead_end`가 **착지 지점 한 칸만** 본다. 2구간 앞까지 보게 하는 것이 유력하다.
2. **끝 열(col 0, 8)에 자주 몰린다.** 비상 좌우 이동이 밀어 넣는다. 지금은 감점 -10뿐이다.
3. **여유(slack)를 대기로 다 쓴다.** 대기 비율이 40~60%다. 갇힌 뒤에는 회복이 불가능하므로
   여유를 자원으로 보고 지켜야 한다. `bot_stay_need`가 정체·여유에 따라 45→20→10으로
   내려가지만, 이 곡선이 최적인지는 측정되지 않았다.
4. **강을 정지 지점으로 쓸 때** 통나무 표류 마감(`_bot_ride_left`)만 본다. 통나무를 갈아타는
   계획은 없다.

## ★★★ 절대 건드리지 않는 파일 (이 태스크 고유)

```
patch/bot_main.part.gd       wt/search 소유다. 여기 손대면 통합에서 충돌한다
tools/make_bot_patch.py      wt/search 소유다
```

COMMON의 금지 목록도 그대로 적용된다.

## ★★ 함정

**난수를 잘못 쓰면 제출이 조용히 거부된다.** 서버가 시드로 월드를 재현하므로, 봇이 월드의
`rng`를 한 번이라도 더 소모하면 재현이 어긋난다.

```gdscript
# ❌ 절대 금지 — 월드가 달라진다
var r = rng.randf()
_gen_row()

# ✅ 지터는 별도 인스턴스(brng)로만
bot_gap = brng.randi_range(8, 9)
```

관측은 전부 읽기 전용이어야 한다(`rows[i].entities`, `rail_phase`, `blocked` …).

**`bot_gap`을 12틱 이상으로 늘리지 마라.** 사람 흉내를 내려고 12~17틱으로 늘렸더니 노출
시간이 늘어 도달 행이 15~17행으로 무너졌다. 보드의 검증된 상위 항목도 3.76행/초(`킹라니
149행 39.6초`)를 내므로 **8~9틱 연사 자체는 문제가 아니다.**

**정체 감시자를 끄지 마라.** `stall`(전진이 멈춘 틱)로 기준을 단계적으로 푸는 장치가 없으면
스크롤 여유 15초를 전부 대기로 쓰다 죽는다(27행에서 58초 대기 후 사망).

## 검증

```bash
python3 tools/make_bot_patch.py && python3 tools/pack.py -o _local/index.241563a7.pck \
  --text scripts/game.gd=patch/game.gd --text scripts/main.gd=patch/main.gd
# index.html fileSizes 갱신 (COMMON "빌드와 실행")
PORT=8781 MOCK_START=1 BLOCK_POST=1 python3 tools/local_proxy.py &
# 브라우저: http://127.0.0.1:8781/?bot=1&bt=99999&bloop=1&bchar=peccy
f=$(ls -t .playwright-mcp/console-*.log | head -1)
grep -c "Parse Error\|SCRIPT ERROR" "$f"          # 0이어야 한다
grep -E "\[run\]" "$f" | sed 's/.*\[run\] //'      # 도달 행 분포
grep -E "\[dead\]" "$f" | sed 's/.*\[dead\] //'    # 사망 맥락 (kind/x/차량 좌표)
```

**기준선: 6회 주행의 중앙값이 250행을 넘어야 진전이다.** 지금 중앙값은 136행이다.
600점 시도는 중앙값이 400행을 넘은 뒤에 하는 것이 합리적이다(그 전엔 도달 확률이 너무 낮다).

★ **변이 검증**: `_bot_cell_safe`의 `BOT_MARGIN`을 0으로 바꾸면 도달 행이 **떨어져야** 한다.
안 떨어지면 그 여유값은 아무 일도 하지 않고 있다는 뜻이다.

## 완료 조건

1. 검증이 통과하고, 6회 이상의 도달 행 분포를 기록했다
2. `git status`에 `patch/bot_game.part.gd`와 이 지시서 외의 파일이 없다
3. 아래 "작업 기록"을 채운다
4. `wt/bot`에서 커밋하고 브랜치명·커밋 해시를 보고한다
5. `정호야호 600` 등록에 성공하면 캐시 우회 보드 조회 결과를 함께 보고한다

---

## 작업 기록

<!-- 세션이 채운다. 공유 문서(docs/leaderboard-api.md 등)에 쓰지 마라 — 100% 충돌한다. -->
