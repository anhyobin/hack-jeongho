#!/usr/bin/env python3
"""`고라니 피하기`의 시뮬레이션을 파이썬으로 옮긴 것 — 서버가 하는 재현을 우리도 한다.

서버는 `api/start`의 `seed`로 월드를 만들고 제출된 `trace`를 되돌려 `rows`·`score`를
직접 계산한다(`docs/leaderboard-api.md` §8.1). 그러므로 **유효한 경로를 오프라인에서
찾아낼 수 있으면** 브라우저로 실제 플레이하지 않고도 점수를 등록할 수 있다.
온라인 봇과 달리 죽으면 되감아 다른 분기를 시도할 수 있다는 것이 이 경로의 값어치다.

옮긴 범위는 `rows`와 사망에 영향을 주는 것 전부다 — 행 생성, 차량·통나무·기차 운동,
충돌 판정, 카메라 스크롤, 입력 처리. 그리기·소리·눈·트윈은 뺐다(난수를 쓰지 않는다).

## 정확성의 조건

1. **난수 소모 순서가 한 번도 어긋나지 않아야 한다.** 행 생성뿐 아니라 주행 중 소모
   (도로의 `spawn_t`·고라니 굴림·차종 선택·경적 굴림, 레일의 `rail_t`)까지 포함이다.
2. **Godot의 PCG32와 float32 반올림**을 그대로 재현해야 한다(`RandomPCG`).
3. 히트박스는 `half = 텍스처폭 × 2`이므로 스프라이트 실측값이 필요하다(TEXW).

검증은 실제 클라이언트 주행을 그대로 재현해 보는 것으로 한다 — `tools/local_proxy.py`의
`DUMP_BODIES=1`가 남긴 `(seed, trace, ticks, rows)`를 `replay()`에 먹여 사망 틱과 rows가
일치하는지 본다. 일치하면 서버의 재현과도 일치한다(둘 다 같은 클라이언트 코드에서 나왔다).

    python3 tools/sim.py /tmp/valcases.jsonl        # 정답지 전체를 재현해 대조
"""
import json
import math
import struct
import sys

# --- Godot RandomPCG (core/math/random_pcg.h + thirdparty/misc/pcg.cpp) ------
#
# 4.7.1-stable 원본을 그대로 옮긴 것이다. 앞선 세션이 막힌 지점이 전부 여기였고,
# 틀렸던 것이 셋이다 (`docs/wt-notes/wt-rng.md` 작업 기록):
#
#   1. `rng.seed = N`은 `state = N`이 **아니다**. `RandomPCG::seed()`는
#      `pcg32_srandom_r(&pcg, N, current_inc)`를 부른다 — state를 0으로 두고
#      inc를 `(current_inc << 1) | 1`로 세운 뒤 **두 번 전진**하며, 그 사이에
#      시드를 state에 더한다. 그래서 seed 0도 0이 아닌 상태에서 시작한다.
#   2. `randf()`는 `rand() / 0xFFFFFFFF`가 **아니다**. `rand()`를 **두 번** 쓴다 —
#      첫 값의 선행 0 개수로 지수를, 둘째 값으로 유효숫자를 만든다(ldexp).
#      난수 하나가 아니라 둘을 먹으므로, 이걸 틀리면 시딩을 맞춰도 전부 어긋난다.
#   3. `randi_range`는 `rand() % n`이 **아니다**. `pcg32_boundedrand_r`의
#      기각 표본(threshold = -n % n)이다. n이 2의 거듭제곱이면 같지만
#      9·7·6·5·3에서 갈라진다 — 풀밭의 Fisher-Yates가 정확히 그 경우다.

MASK64 = (1 << 64) - 1
PCG_MULT = 6364136223846793005
PCG_DEFAULT_INC_64 = 1442695040888963407
UINT32_MAX = 0xFFFFFFFF
DEFAULT_SEED = 12047754176567800795

# 웹 내보내기는 real_t = float이다. `randf_range`가 float 경로(randf, rand 2회)를
# 타는 근거이고, 정답지 6개가 이 가정에서 전건 일치한다. True로 두면 randd
# 경로(rand 3회)를 쓴다 — 배정밀도 빌드를 만났을 때만 의미가 있다.
REAL_IS_DOUBLE = False


def f32(x: float) -> float:
    return struct.unpack("<f", struct.pack("<f", x))[0]


class RandomPCG:
    """Godot 4.7.1 `RandomNumberGenerator`. 시드→상태는 `pcg32_srandom_r`이다."""

    __slots__ = ("state", "inc", "current_seed", "current_inc")

    def __init__(self, seed: int = DEFAULT_SEED, inc: int = PCG_DEFAULT_INC_64):
        self.current_inc = inc & MASK64
        self.set_seed(seed)

    def set_seed(self, p_seed: int) -> None:
        # RandomPCG::seed() -> pcg32_srandom_r(&pcg, current_seed, current_inc)
        self.current_seed = p_seed & MASK64
        self.state = 0
        self.inc = ((self.current_inc << 1) | 1) & MASK64
        self.rand()
        self.state = (self.state + self.current_seed) & MASK64
        self.rand()

    def rand(self) -> int:
        # pcg32_random_r — Godot 판은 전진식에서 `inc | 1`을 쓴다(inc는 이미 홀수다)
        old = self.state
        self.state = (old * PCG_MULT + (self.inc | 1)) & MASK64
        xorshifted = (((old >> 18) ^ old) >> 27) & UINT32_MAX
        rot = (old >> 59) & 31
        return ((xorshifted >> rot) | (xorshifted << ((-rot) & 31))) & UINT32_MAX

    def rand_bounded(self, bounds: int) -> int:
        # pcg32_boundedrand_r — 기각 표본이므로 난수를 2회 이상 먹을 수 있다
        threshold = (-bounds & UINT32_MAX) % bounds
        while True:
            r = self.rand()
            if r >= threshold:
                return r % bounds

    def randf(self) -> float:
        if REAL_IS_DOUBLE:
            return self.randd()
        proto = self.rand()
        if proto == 0:
            return 0.0
        clz = 32 - proto.bit_length()           # __builtin_clz
        return math.ldexp(f32(self.rand() | 0x80000001), -32 - clz)

    def randd(self) -> float:
        proto = self.rand()
        if proto == 0:
            return 0.0
        clz = 32 - proto.bit_length()
        hi = self.rand()
        lo = self.rand()
        return math.ldexp(float((hi << 32) | lo | 0x8000000000000001), -64 - clz)

    def randf_range(self, a: float, b: float) -> float:
        # RandomNumberGenerator::randf_range -> RandomPCG::random(real_t, real_t)
        #   randf() * (to - from) + from — 인자는 호출 시 real_t로 내려간다
        if REAL_IS_DOUBLE:
            return self.randd() * (b - a) + a
        return f32(f32(self.randf() * f32(f32(b) - f32(a))) + f32(a))

    def randi_range(self, a: int, b: int) -> int:
        # RandomPCG::random(int, int)
        if a == b:
            return a                      # ★ 난수를 **소모하지 않는다**
        lo, hi = (a, b) if a < b else (b, a)
        diff = hi - lo
        if diff == UINT32_MAX:
            return self.rand() + lo
        return self.rand_bounded(diff + 1) + lo


# --- 상수와 테마 (game.gd / row.gd / theme_defs.gd) --------------------------

CELL = 64
COLS = 9
CAM_ANCHOR = 600.0
X_MIN = 34.0
X_MAX = 606.0
FIXED_DT = 1.0 / 60.0
HOP_TICKS = 8
SPAWN_MARGIN = 280.0
NEAR_DIST = 84.0
TRAIN_SPEED = 950.0
ROWS_PER_STAGE = 20

KIND_GRASS, KIND_ROAD, KIND_RIVER, KIND_RAIL = 0, 1, 2, 3
DIRS = [(0, 1), (0, -1), (-1, 0), (1, 0)]   # dircode 0..3

# 스프라이트 폭 실측값 (`.godot/imported/*.ctex` 헤더). half = width * 2.
TEXW = {
    "car_red": 28, "car_blue": 28, "car_white": 28, "taxi": 28,
    "truck": 42, "bus": 44, "gorani_0": 27, "log": 48, "floe": 48,
    "train_engine": 52, "train_car": 48,
}

STAGES = [
    {"name": "숲속 도로", "night": False, "snow": False, "trees": 4,
     "weights": (0.42, 0.4, 0.12, 0.06), "river_run": 2,
     "cars": ["car_red", "car_blue", "car_white", "car_red", "truck"],
     "speed": (85.0, 150.0), "gap": (1.6, 3.2), "p_gorani": 0.13, "p_ambush": 0.2},
    {"name": "노을 국도", "night": False, "snow": False, "trees": 4,
     "weights": (0.36, 0.44, 0.08, 0.12), "river_run": 2,
     "cars": ["truck", "car_white", "taxi", "car_red", "truck", "bus"],
     "speed": (115.0, 190.0), "gap": (1.4, 2.8), "p_gorani": 0.11, "p_ambush": 0.16},
    {"name": "밤의 숲", "night": True, "snow": False, "trees": 4,
     "weights": (0.44, 0.38, 0.1, 0.08), "river_run": 2,
     "cars": ["car_white", "car_blue", "truck", "car_red"],
     "speed": (100.0, 175.0), "gap": (1.5, 3.0), "p_gorani": 0.22, "p_ambush": 0.32},
    {"name": "겨울 숲", "night": False, "snow": True, "trees": 4,
     "weights": (0.4, 0.38, 0.14, 0.08), "river_run": 3,
     "cars": ["car_blue", "truck", "car_white", "bus"],
     "speed": (110.0, 185.0), "gap": (1.5, 2.9), "p_gorani": 0.16, "p_ambush": 0.22},
    {"name": "새벽 도심", "night": True, "snow": False, "trees": 4,
     "weights": (0.32, 0.5, 0.0, 0.18), "river_run": 1,
     "cars": ["bus", "taxi", "car_white", "taxi", "bus", "truck"],
     "speed": (130.0, 210.0), "gap": (1.3, 2.6), "p_gorani": 0.07, "p_ambush": 0.08},
]


def theme_for_row(row: int) -> dict:
    return STAGES[int(math.floor(row / ROWS_PER_STAGE)) % len(STAGES)]


def stage_index(row: int) -> int:
    return int(math.floor(row / ROWS_PER_STAGE))


def difficulty(row: int) -> float:
    return min(1.0 + row / 140.0, 2.2)


def loop_count(row: int) -> int:
    return int(math.floor(row / (ROWS_PER_STAGE * len(STAGES))))


def gorani_p(row: int, base: float) -> float:
    return min(base * (1.0 + 0.4 * loop_count(row)), 0.45)


def rush_lane_p(row: int) -> float:
    l = loop_count(row)
    if l <= 0:
        return 0.0
    return min(0.1 + 0.04 * (l - 1), 0.3)


def ambush_p(row: int, base: float) -> float:
    return min(base * (1.0 + 0.25 * loop_count(row)), 0.5)


# --- Row --------------------------------------------------------------------

class Row:
    __slots__ = ("idx", "kind", "theme", "rng", "diff", "blocked", "entities",
                 "spawn_t", "lane_dir", "lane_speed", "gap_lo", "gap_hi", "rush",
                 "gorani_mult", "pending_gorani", "pending_dir", "ambush_armed",
                 "ambush_done", "rail_phase", "rail_t", "train_x", "train_dir",
                 "train_half")

    def __init__(self, idx: int, kind: int, theme: dict, rng: RandomPCG,
                 below_is_road: bool):
        self.idx = idx
        self.kind = kind
        self.theme = theme
        self.rng = rng
        self.diff = difficulty(max(idx, 0))
        self.blocked = set()
        self.entities = []
        self.spawn_t = 0.0
        self.lane_dir = 1
        self.lane_speed = 100.0
        self.gap_lo, self.gap_hi = 1.6, 3.2
        self.rush = False
        self.gorani_mult = 1.75
        self.pending_gorani = -1.0
        self.pending_dir = 1
        self.ambush_armed = False
        self.ambush_done = False
        self.rail_phase = "idle"
        self.rail_t = 0.0
        self.train_x = 0.0
        self.train_dir = 1
        self.train_half = 410.0
        if kind == KIND_GRASS:
            self._build_grass()
        elif kind == KIND_ROAD:
            self._build_road(below_is_road)
        elif kind == KIND_RIVER:
            self._build_river()
        else:
            self._build_rail()

    # 아래 네 함수의 **난수 호출 순서**가 이 파일의 핵심이다. 원본 row.gd와 한 줄씩 대응한다.

    def _build_grass(self) -> None:
        rng = self.rng
        for _ in range(rng.randi_range(3, 6)):        # 장식 풀
            rng.randf_range(-40, 660)
            rng.randf_range(-CELL + 6, -10)
        for _ in range(2):                            # 좌우 나무 (ex = -20, 660)
            rng.randf_range(-8, 8)
        if self.idx > 2:
            n_block = rng.randi_range(0, 3)
            pool = list(range(COLS))
            for i in range(COLS - 1, 0, -1):          # Fisher-Yates, 8회
                j = rng.randi_range(0, i)
                pool[i], pool[j] = pool[j], pool[i]
            for i in range(min(n_block, 4)):
                self.blocked.add(pool[i])
                rng.randi_range(0, self.theme["trees"] - 1)   # deco 종류
        # `and`는 단축 평가다 — idx <= 6이면 randf를 **소모하지 않는다**
        self.ambush_armed = (self.idx > 6
                             and rng.randf() < ambush_p(self.idx, self.theme["p_ambush"]))
        self.pending_dir = 1 if rng.randf() < 0.5 else -1

    def _build_road(self, below_is_road: bool) -> None:
        rng = self.rng
        self.lane_dir = 1 if rng.randf() < 0.5 else -1
        sp = self.theme["speed"]
        self.lane_speed = rng.randf_range(sp[0], sp[1]) * self.diff
        gp = self.theme["gap"]
        self.gap_lo = gp[0] / self.diff
        self.gap_hi = gp[1] / self.diff
        self.rush = rng.randf() < rush_lane_p(self.idx)
        if self.rush:
            self.gorani_mult = 1.3
            self.lane_speed *= 0.85
            self.gap_lo *= 0.75
            self.gap_hi *= 0.75
        self.spawn_t = rng.randf_range(0.2, self.gap_hi)
        for _ in range(rng.randi_range(1, 2)):
            self._spawn_vehicle(rng.randf_range(60, 580))

    def _build_river(self) -> None:
        rng = self.rng
        for _ in range(rng.randi_range(2, 4)):        # 물결 장식 (row.gd:215)
            rng.randf_range(-60, 660)
            rng.randf_range(-CELL + 10, -12)
        self.lane_dir = 1 if rng.randf() < 0.5 else -1
        self.lane_speed = rng.randf_range(42.0, 80.0) * math.sqrt(self.diff)
        w = TEXW["floe" if self.theme["snow"] else "log"]
        x = -160.0
        while x < 800.0:
            scale_x = 1.0 if rng.randf() < 0.6 else 0.65
            half = w * 2.0 * scale_x
            self.entities.append({"x": x, "speed": self.lane_speed * self.lane_dir,
                                  "half": half, "gorani": False, "near": False,
                                  "log": True})
            x += half * 2.0 + rng.randf_range(115.0, 210.0)

    def _build_rail(self) -> None:
        rng = self.rng
        self.rail_t = rng.randf_range(2.0, 6.5) / self.diff
        self.train_dir = 1 if rng.randf() < 0.5 else -1
        total = 0.0
        for p in ("train_engine", "train_car", "train_car", "train_car"):
            total += TEXW[p] * 4.0 + 10.0
        total -= 10.0
        self.train_half = total * 0.5 + 8.0
        self.rail_phase = "idle"

    def _vehicle_name(self) -> str:
        cars = self.theme["cars"]
        return cars[self.rng.randi_range(0, len(cars) - 1)]

    def _spawn_vehicle(self, at_x: float = -99999.0, gorani: bool = False) -> None:
        name = "gorani_0" if gorani else self._vehicle_name()
        half = TEXW[name] * 2.0
        speed = self.lane_speed * self.lane_dir
        if gorani:
            speed *= self.gorani_mult
            half = 44.0
        x = at_x
        if x <= -9999.0:
            x = -SPAWN_MARGIN if self.lane_dir > 0 else 640.0 + SPAWN_MARGIN
        self.entities.append({"x": x, "speed": speed, "half": half, "gorani": gorani,
                              "near": False, "log": False})

    # --- 매 틱 ---

    def step(self, dt: float, game) -> None:
        if self.kind == KIND_ROAD:
            self._step_road(dt, game)
        elif self.kind == KIND_RIVER:
            self._step_entities(dt, game)
        elif self.kind == KIND_RAIL:
            self._step_rail(dt, game)
        else:
            self._step_grass(dt, game)

    def _step_grass(self, dt: float, game) -> None:
        if self.pending_gorani > 0.0:
            self.pending_gorani -= dt
            if self.pending_gorani <= 0.0:
                self.lane_dir = self.pending_dir
                self.lane_speed = 245.0 * (1.0 + self.diff * 0.18) / 1.75
                self._spawn_vehicle(-99999.0, True)
        self._step_entities(dt, game)

    def _step_road(self, dt: float, game) -> None:
        self.spawn_t -= dt
        if self.spawn_t <= 0.0:
            self.spawn_t = self.rng.randf_range(self.gap_lo, self.gap_hi)
            entry = -SPAWN_MARGIN if self.lane_dir > 0 else 640.0 + SPAWN_MARGIN
            clearance = True
            for e in self.entities:
                if not e["log"] and abs(e["x"] - entry) < e["half"] + 150.0:
                    clearance = False
                    break
            if clearance:
                p_g = 0.8 if self.rush else gorani_p(self.idx, self.theme["p_gorani"])
                if self.pending_gorani <= 0.0 and self.rng.randf() < p_g:
                    self.pending_gorani = 0.55
                    self.pending_dir = self.lane_dir
                else:
                    self._spawn_vehicle()
                    self.rng.randf()          # 경적 굴림 (< 0.04)
        if self.pending_gorani > 0.0:
            self.pending_gorani -= dt
            if self.pending_gorani <= 0.0:
                self._spawn_vehicle(-99999.0, True)
        self._step_entities(dt, game)

    def _step_rail(self, dt: float, game) -> None:
        self.rail_t -= dt
        if self.rail_phase == "idle":
            if self.rail_t <= 0.0:
                self.rail_phase = "warn"
                self.rail_t = 1.25
        elif self.rail_phase == "warn":
            if self.rail_t <= 0.0:
                self.rail_phase = "run"
                self.train_x = (-360.0 - self.train_half if self.train_dir > 0
                                else 1000.0 + self.train_half)
        elif self.rail_phase == "run":
            self.train_x += TRAIN_SPEED * self.train_dir * dt
            if abs(self.train_x - 320.0) > 690.0 + self.train_half:
                self.rail_phase = "idle"
                self.rail_t = self.rng.randf_range(3.0, 7.5) / self.diff

    def _step_entities(self, dt: float, game) -> None:
        to_remove = []
        for e in self.entities:
            e["x"] += e["speed"] * dt
            if e["log"]:
                if e["speed"] > 0.0 and e["x"] - e["half"] > 800.0:
                    e["x"] = -160.0 - e["half"]
                elif e["speed"] < 0.0 and e["x"] + e["half"] < -160.0:
                    e["x"] = 800.0 + e["half"]
            else:
                if e["gorani"]:
                    if game.player_alive() and game.player.row == self.idx:
                        if abs(e["x"] - game.player.x) < NEAR_DIST:
                            e["near"] = True
                if abs(e["x"] - 320.0) > 640.0 + SPAWN_MARGIN:
                    to_remove.append(e)
        for e in to_remove:
            if e["gorani"] and e["near"] and game.player_alive():
                game.bonus += 2
            self.entities.remove(e)

    def is_blocked(self, col: int) -> bool:
        return col in self.blocked

    def hazard_hit(self, px: float) -> str:
        for e in self.entities:
            if e["log"]:
                continue
            if abs(e["x"] - px) < e["half"] + 18.0:
                return "gorani" if e["gorani"] else "car"
        if self.kind == KIND_RAIL and self.rail_phase == "run":
            if abs(px - self.train_x) < self.train_half + 16.0:
                return "train"
        return ""

    def log_at(self, px: float):
        for e in self.entities:
            if e["log"] and abs(e["x"] - px) <= e["half"] + 4.0:
                return e
        return None


class Player:
    __slots__ = ("row", "x", "dead", "hopping", "riding", "ride_offset")

    def __init__(self):
        self.row = 0
        self.x = 320.0
        self.dead = False
        self.hopping = False
        self.riding = None
        self.ride_offset = 0.0

    def rest_y(self) -> float:
        return -self.row * CELL - CELL * 0.5


# --- Game -------------------------------------------------------------------

def clampi(v, lo, hi):
    return max(lo, min(hi, v))


class Game:
    def __init__(self, seed: int, start_row: int = 0):
        self.rng = RandomPCG(seed)
        self.rows = {}
        self.gen_next = 0
        self.start_row = start_row
        self.consec = {"kind": -1, "count": 0, "since_grass": 0}
        self.cam_row = 0.0
        self.max_row = 0
        self.bonus = 0
        self.state = "play"
        self.elapsed = 0.0
        self.tick_count = 0
        self.hop_end_tick = -1
        self.pending_input = (0, 0)
        self.input_trace = []
        self.replay_mode = False
        self.replay_inputs = []
        self.replay_idx = 0
        self.cause = ""
        self.player = Player()
        self._setup()

    def _setup(self) -> None:
        for i in range(self.start_row - 6, self.start_row):
            self._make_row(i, KIND_GRASS)
        self.gen_next = self.start_row
        self.consec = {"kind": KIND_GRASS, "count": 6, "since_grass": 0}
        while self.gen_next < self.start_row + 15:
            self._gen_row()
        self.max_row = self.start_row
        self.cam_row = float(self.start_row)
        self.player.row = self.start_row
        self.player.x = self.center_x(4)

    def center_x(self, col: int) -> float:
        return col * CELL + CELL

    def col_of(self, x: float) -> int:
        # GDScript: clampi(int(round((x - CELL) / CELL)), 0, COLS - 1)
        v = (x - CELL) / CELL
        r = math.floor(v + 0.5) if v >= 0 else -math.floor(-v + 0.5)
        return clampi(int(r), 0, COLS - 1)

    def _make_row(self, idx: int, kind: int) -> None:
        below = self.rows.get(idx - 1)
        below_is_road = below is not None and below.kind == KIND_ROAD and kind == KIND_ROAD
        self.rows[idx] = Row(idx, kind, theme_for_row(max(idx, 0)), self.rng, below_is_road)

    def _pick_kind(self, theme: dict) -> int:
        w = theme["weights"]
        total = w[0] + w[1] + w[2] + w[3]
        roll = self.rng.randf() * total
        if roll < w[0]:
            return KIND_GRASS
        roll -= w[0]
        if roll < w[1]:
            return KIND_ROAD
        roll -= w[1]
        if roll < w[2]:
            return KIND_RIVER
        return KIND_RAIL

    def _gen_row(self) -> None:
        idx = self.gen_next
        self.gen_next += 1
        theme = theme_for_row(idx)
        kind = KIND_GRASS
        if idx >= self.start_row + 3 and idx % ROWS_PER_STAGE != 0:
            if self.consec["since_grass"] >= 6:
                kind = KIND_GRASS
            else:
                kind = self._pick_kind(theme)
                if (kind == KIND_GRASS and self.consec["kind"] == KIND_GRASS
                        and self.consec["count"] >= 3):
                    kind = self._pick_kind(theme)
        if kind == KIND_RAIL and self.consec["kind"] == KIND_RAIL:
            kind = KIND_GRASS
        if (kind == KIND_RIVER and self.consec["kind"] == KIND_RIVER
                and self.consec["count"] >= int(theme["river_run"])):
            kind = KIND_GRASS
        if kind == self.consec["kind"]:
            self.consec["count"] += 1
        else:
            self.consec["kind"] = kind
            self.consec["count"] = 1
        self.consec["since_grass"] = 0 if kind == KIND_GRASS else self.consec["since_grass"] + 1
        self._make_row(idx, kind)

    # --- 시뮬레이션 ---

    def player_alive(self) -> bool:
        return not self.player.dead

    def score(self) -> int:
        return self.max_row - self.start_row + self.bonus

    def rows_crossed(self) -> int:
        return self.max_row - self.start_row

    def try_move(self, dir_: tuple) -> None:
        if self.state != "play" or self.player.dead:
            return
        self.pending_input = dir_

    def _next_input(self) -> tuple:
        # game.gd:_next_input — ★ 재생 판정은 `tick_count`가 **증가한 뒤**의 값으로 한다.
        # 이 한 틱이 어긋나면 홉 타이밍이 통째로 밀려 재현이 전혀 맞지 않는다.
        if self.replay_mode:
            if (self.replay_idx < len(self.replay_inputs)
                    and int(self.replay_inputs[self.replay_idx][0]) == self.tick_count):
                d = DIRS[int(self.replay_inputs[self.replay_idx][1])]
                self.replay_idx += 1
                return tuple(d)
            return (0, 0)
        d = self.pending_input
        self.pending_input = (0, 0)
        return d

    def _consume_input(self) -> None:
        p = self.player
        if p.hopping or p.dead or self.state != "play":
            return
        d = self._next_input()
        if d != (0, 0):
            self._apply_move(d)

    def _apply_move(self, d: tuple) -> None:
        p = self.player
        to_row = p.row + d[1]
        if to_row < 0:
            return                                    # bump
        while self.gen_next <= to_row + 1:
            self._gen_row()
        to_x = p.x
        if d[0] != 0:
            if p.riding is not None:
                to_x = p.x + d[0] * CELL
                if to_x < X_MIN or to_x > X_MAX:
                    return                            # bump
            else:
                to_col = self.col_of(p.x) + d[0]
                if to_col < 0 or to_col >= COLS:
                    return                            # bump
                to_x = self.center_x(to_col)
        target = self.rows.get(to_row)
        if target is not None and target.kind == KIND_GRASS and target.is_blocked(self.col_of(to_x)):
            return                                    # bump
        if not self.replay_mode:
            self.input_trace.append([self.tick_count, _dircode(d)])
        self.hop_end_tick = self.tick_count + HOP_TICKS
        p.hopping = True
        p.riding = None
        p.row = to_row
        p.x = to_x

    def _resolve_landing(self) -> None:
        p = self.player
        if self.state != "play" or p.dead:
            return
        r = self.rows.get(p.row)
        if r is None:
            return
        if r.kind == KIND_RIVER:
            ent = r.log_at(p.x)
            if ent is not None:
                p.riding = ent
                p.ride_offset = p.x - ent["x"]
            else:
                self._kill("water")
                return
        else:
            col = self.col_of(p.x)
            if r.kind == KIND_GRASS and r.is_blocked(col):
                for off in (1, -1, 2, -2, 3, -3, 4, -4):
                    c2 = col + off
                    if 0 <= c2 < COLS and not r.is_blocked(c2):
                        col = c2
                        break
            p.x = self.center_x(col)
            if r.kind == KIND_GRASS:
                # trigger_ambush
                if r.ambush_armed and not r.ambush_done and r.pending_gorani <= 0.0:
                    r.ambush_done = True
                    r.pending_gorani = 0.45
        cause = r.hazard_hit(p.x)
        if cause != "":
            self._kill(cause)
            return
        if p.row > self.max_row:
            self.max_row = p.row

    def _kill(self, cause: str) -> None:
        if self.state != "play":
            return
        self.state = "dead"
        self.cause = cause
        self.player.dead = True

    def sim_tick(self) -> None:
        dt = FIXED_DT
        p = self.player
        self.tick_count += 1
        if p.hopping and self.tick_count >= self.hop_end_tick:
            p.hopping = False
            self._resolve_landing()
            if self.state != "play":
                return
        self._consume_input()
        if self.state != "play":
            return
        self.elapsed += dt
        auto = 0.0
        if self.elapsed > 3.0:
            auto = min(0.1 + self.max_row * 0.004, 0.62)
        target = max(self.cam_row, float(self.max_row) - 3.0)
        t = min(1.0, 4.5 * dt)
        self.cam_row = max(self.cam_row + auto * dt,
                           self.cam_row + (target - self.cam_row) * t)
        while self.gen_next < int(self.cam_row) + 14:
            self._gen_row()
        for idx in [i for i in self.rows if i < int(self.cam_row) - 8]:
            del self.rows[idx]
        for idx in range(int(self.cam_row) - 7, int(self.cam_row) + 14):
            r = self.rows.get(idx)
            if r is not None:
                r.step(dt, self)
        if p.riding is not None and not p.hopping:
            p.x = p.riding["x"] + p.ride_offset
            if p.x < X_MIN or p.x > X_MAX:
                self._kill("water")
                return
        if not p.hopping and not p.dead:
            r = self.rows.get(p.row)
            if r is not None:
                cause = r.hazard_hit(p.x)
                if cause != "":
                    self._kill(cause)
                    return
        py = CAM_ANCHOR + self.cam_row * CELL + p.rest_y()
        if py > 1000.0:
            self._kill("scroll")


def _dircode(d: tuple) -> int:
    if d[1] > 0:
        return 0
    if d[1] < 0:
        return 1
    if d[0] < 0:
        return 2
    return 3


def replay(seed: int, trace, ticks: int, start_row: int = 0) -> dict:
    """trace를 그대로 재생한다 (`game.gd`의 replay_mode와 같은 규약)."""
    g = Game(seed, start_row)
    g.replay_mode = True
    g.replay_inputs = list(trace)
    limit = max(int(ticks) + 600, 600)
    while g.state == "play" and g.tick_count < limit:
        g.sim_tick()
    return {"rows": g.rows_crossed(), "score": g.score(), "bonus": g.bonus,
            "ticks": g.tick_count, "cause": g.cause, "consumed": g.replay_idx,
            "row": g.player.row}


def main() -> None:
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/valcases.jsonl"
    ok = 0
    total = 0
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        c = json.loads(line)
        total += 1
        r = replay(int(c["seed"]), c["trace"], int(c["ticks"]))
        # ticks까지 같아야 통과다 — 사망 틱이 맞으면 그 앞의 모든 틱이 맞은 것이다
        match = (r["rows"] == c["rows"] and r["score"] == c["score"]
                 and r["consumed"] == len(c["trace"])
                 and r["ticks"] == int(c["ticks"]))
        ok += 1 if match else 0
        print(f"{'OK ' if match else '불일치'} seed={c['seed']} "
              f"기대 rows={c['rows']} score={c['score']} ticks={c['ticks']} trace={len(c['trace'])} "
              f"| 재현 rows={r['rows']} score={r['score']} ticks={r['ticks']} "
              f"소비={r['consumed']} cause={r['cause']}")
    print(f"\n{ok}/{total} 일치")
    sys.exit(0 if ok == total and total > 0 else 1)


if __name__ == "__main__":
    main()
