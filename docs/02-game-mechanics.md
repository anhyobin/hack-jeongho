# 02. 복원한 게임 로직

복원 소스는 [`decompiled/`](../decompiled) 에 있어요. 여기서는 점수와 난이도, 사망 판정처럼
"점수를 어떻게 만들 수 있는가"에 직접 연결되는 부분만 정리했어요.

## 좌표계

| 상수 | 값 | 의미 |
|---|---|---|
| `CELL` | 64 | 한 칸 크기(px). 한 번 점프 = 1칸 |
| `COLS` | 9 | 가로 칸 수, `center_x(col) = col * 64 + 64` |
| `X_MIN` / `X_MAX` | 34 / 606 | 통나무 탑승 중 이 범위를 벗어나면 익사 |
| `CAM_ANCHOR` | 600 | 카메라 기준선. 플레이어는 화면 y ≈ 600 부근에 머무름 |
| `HOP_T` | 0.13초 | 한 칸 점프 시간 (`player.gd`) |

행 종류는 grass / road / river / rail 네 가지예요.

## 점수 산식

```gdscript
# game.gd
func score() -> int:
	return max_row - start_row + bonus

func rows_crossed() -> int:
	return max_row - start_row

func on_near_miss(_row_idx: int) -> void:
	bonus += 2
```

- 점수 = **전진한 칸수 + 니어미스 보너스**, 보너스는 고라니 1회당 +2
- 니어미스 판정: 플레이어가 그 행에 있는 동안 고라니와 x거리 84px 이내(`NEAR_DIST`)로 스친 뒤,
  그 고라니가 화면 밖으로 나갈 때 +2 (`row.gd` `_step_entities`)
- 보너스는 이론상 칸당 여러 번도 가능하지만 현실적으로 칸당 최대 +2 수준
  → **서버의 `score ≤ rows × 2` 검사와 정확히 맞물리는 지점이에요**
- 전부 클라이언트 계산이고, 서버로는 최종 `score` 와 `rows` 만 전송돼요

### `?s=` 파라미터 (점수 이득 없음)

```gdscript
# game.gd setup()
var v = JavaScriptBridge.eval("new URLSearchParams(location.search).get('s')", true)
if v != null and str(v).is_valid_int():
	start_row = clampi(int(str(v)), 0, 500) * ThemeDefs.ROWS_PER_STAGE
```

`?s=30` 처럼 붙이면 스테이지 30부터 시작해요. 후반 스테이지 연습용으로는 쓸모가 있지만,
`score()` 가 `start_row` 를 빼기 때문에 점수 이득은 0이에요. 오히려 처음부터 어려운 난이도로 시작합니다.

## 난이도 곡선 — 상한이 있다

```gdscript
# theme_defs.gd
const ROWS_PER_STAGE:= 20          # 스테이지 = row / 20, 테마 5종 순환

static func difficulty(row: int) -> float:
	return minf(1.0 + float(row) / 140.0, 2.2)      # row 168 에서 상한

static func loop_count(row: int) -> int:
	return int(floor(float(row) / (ROWS_PER_STAGE * stages().size())))   # 100칸 = 1루프

static func gorani_p(row, base)  -> min(base * (1 + 0.40 * loop), 0.45)
static func ambush_p(row, base)  -> min(base * (1 + 0.25 * loop), 0.50)
static func rush_lane_p(row)     -> loop <= 0 ? 0.0 : min(0.1 + 0.04 * (loop - 1), 0.30)
```

- 차 속도와 생성 간격은 `difficulty` 에 비례 → **row 168 이후 더 빨라지지 않음**
- 고라니/기습/러시 차선 확률도 각각 0.45 / 0.50 / 0.30 에서 상한
- 테마별 기본값이 가장 낮은 새벽 도심(`p_gorani 0.07`) 기준으로도 **row 1100 쯤이면 모든 수치가 상한**
- 즉 **row 1100 이후로는 게임 난이도가 완전히 고정**돼요. 생존 확률이 칸마다 일정하다는 뜻이라,
  이론상 점수 상한이 없어요

최대 난이도에서의 실제 수치:

| 항목 | 최대값 |
|---|---|
| 차 속도 | 210 × 2.2 = **462 px/s** (새벽 도심) |
| 차 생성 간격 | 1.3 / 2.2 ≈ **0.59초** (러시 차선은 ×0.75) |
| 고라니 속도 | 245 × (1 + 2.2×0.18) ≈ **342 px/s**, 경고 표시 후 0.55초 뒤 진입 |
| 기차 속도 | **950 px/s** 고정, 경고등 점멸 1.25초 |
| 통나무 속도 | 42~80 × √2.2 ≈ **62~119 px/s** |

## 사망 판정

```gdscript
# row.gd
func hazard_hit(px: float) -> String:
	for e in entities:
		if e["log"]: continue
		if absf(e["x"] - px) < e["half"] + 18.0:
			return "gorani" if e["gorani"] else "car"
	if kind == KIND_RAIL and rail_phase == "run":
		if absf(px - train_x) < train_half + 16.0:
			return "train"
	return ""
```

- **차/고라니**: 중심 거리가 `차 반폭 + 18px` 이내면 사망. 착지 순간과 매 프레임 모두 검사
- **기차**: `rail_phase == "run"` 동안 `train_half + 16px` 이내면 사망
- **강**: 착지 지점에 통나무(`half + 4px` 이내)가 없으면 익사, 탑승 중 화면 밖으로 밀려도 익사
- **뒤처짐**: `world.position.y + player.position.y > 1000` → `"scroll"` 사망.
  전개하면 `cam_row - player_row > 6.75` 이므로 **카메라보다 6.75칸까지 뒤처질 수 있어요**

## 자동 스크롤 여유

```gdscript
# game.gd _process()
if elapsed > 3.0:
	auto = minf(0.1 + float(max_row) * 0.004, 0.62)     # 초당 전진 칸수, 상한 0.62
var target:= maxf(cam_row, float(max_row) - 3.0)
cam_row = maxf(cam_row + auto * dt, lerpf(cam_row, target, minf(1.0, 4.5 * dt)))
```

- 카메라는 최대 **0.62 rows/s** 로만 밀어붙여요
- 평소엔 `max_row - 3` 을 따라오므로, 최전선에 서 있으면 뒤처짐 여유는 약 9.75칸
- 즉 한 자리에서 **약 15초까지 차 간격을 기다릴 수 있어요**. 봇 입장에서는 매우 관대한 조건

## 정직하게 10000점을 만들 수 있나

| 제약 | 계산 |
|---|---|
| 점프 시간 | 10000칸 × 0.13초 = **21.7분** (대기 0초, 무실수 가정) |
| 난이도 | row 1100 이후 고정 → 이론상 생존 확률이 칸마다 일정, 상한 없음 |
| 카메라 | 0.62 rows/s 로만 압박, 15초 대기 허용 → 안전한 타이밍만 골라 갈 수 있음 |
| 서버 검사 | 약 4.8 rows/s 상한 → 10000점은 **어차피 35분 이상** 필요 |

봇을 만들 경우 유리한 규칙도 여러 개 있어요.

- `idx % 20 == 0` 인 행은 항상 grass (스테이지 경계마다 안전한 줄)
- 비-grass 행은 최대 6줄 연속, grass 도 3줄 연속 이상은 강제로 다른 종류로 교체
- grass 행 장애물은 최대 4칸, 착지 시 막힌 칸이면 옆칸으로 자동 보정
- 고라니는 진입 0.55초 전에 경고 아이콘, 기차는 1.25초 전에 경고등 점멸 → 예고 없는 죽음이 없음

정리하면 10000점은 "봇으로 35~40분 무실수"거나 "토큰 받고 35분 대기" 둘 중 하나예요.
결국 두 경로 모두 대기 시간이 지배하는 구조라서, 이번 작업은 후자로 진행했어요.
