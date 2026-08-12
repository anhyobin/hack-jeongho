extends RefCounted
class_name ThemeDefs
const ROWS_PER_STAGE:= 20
static func stages() -> Array:
	return [
		{
			"name": "숲속 도로",
			"grass": [Color("7ec850"), Color("74bd49")],
			"deco_tint": Color(1, 1, 1),
			"road": Color("4a4a52"), "line": Color("e8e4d8"),
			"river": Color("4a90c2"), "rail": Color("9a8a72"),
			"ambient": Color(1, 1, 1), "night": false, "snow": false,
			"trees": ["tree", "tree", "bush", "rock"],
			"weights": { "grass": 0.42, "road": 0.4, "river": 0.12, "rail": 0.06},
			"river_run": 2,
			"cars": ["car_red", "car_blue", "car_white", "car_red", "truck"],
			"speed": [85.0, 150.0], "gap": [1.6, 3.2],
			"p_gorani": 0.13, "p_ambush": 0.2,
		},
		{
			"name": "노을 국도",
			"grass": [Color("a8b04a"), Color("9ca644")],
			"deco_tint": Color(1.0, 0.92, 0.8),
			"road": Color("4e4a50"), "line": Color("e8d8b8"),
			"river": Color("5a84b8"), "rail": Color("a08a68"),
			"ambient": Color(1.0, 0.86, 0.72), "night": false, "snow": false,
			"trees": ["tree", "bush", "rock", "bush"],
			"weights": { "grass": 0.36, "road": 0.44, "river": 0.08, "rail": 0.12},
			"river_run": 2,
			"cars": ["truck", "car_white", "taxi", "car_red", "truck", "bus"],
			"speed": [115.0, 190.0], "gap": [1.4, 2.8],
			"p_gorani": 0.11, "p_ambush": 0.16,
		},
		{
			"name": "밤의 숲",
			"grass": [Color("3e6b38"), Color("376233")],
			"deco_tint": Color(0.75, 0.8, 0.95),
			"road": Color("3a3a44"), "line": Color("c8c4b8"),
			"river": Color("2a5080"), "rail": Color("6e6252"),
			"ambient": Color(0.52, 0.58, 0.78), "night": true, "snow": false,
			"trees": ["tree", "tree", "tree", "rock"],
			"weights": { "grass": 0.44, "road": 0.38, "river": 0.1, "rail": 0.08},
			"river_run": 2,
			"cars": ["car_white", "car_blue", "truck", "car_red"],
			"speed": [100.0, 175.0], "gap": [1.5, 3.0],
			"p_gorani": 0.22, "p_ambush": 0.32,
		},
		{
			"name": "겨울 숲",
			"grass": [Color("e8eef2"), Color("dde6ec")],
			"deco_tint": Color(0.95, 0.98, 1.0),
			"road": Color("565a62"), "line": Color("f0ece0"),
			"river": Color("7ab8d8"), "rail": Color("8a8478"),
			"ambient": Color(0.88, 0.93, 1.0), "night": false, "snow": true,
			"trees": ["pine_snow", "pine_snow", "rock", "pine_snow"],
			"weights": { "grass": 0.4, "road": 0.38, "river": 0.14, "rail": 0.08},
			"river_run": 3,
			"cars": ["car_blue", "truck", "car_white", "bus"],
			"speed": [110.0, 185.0], "gap": [1.5, 2.9],
			"p_gorani": 0.16, "p_ambush": 0.22,
		},
		{
			"name": "새벽 도심",
			"grass": [Color("9aa0a8"), Color("90969e")],
			"deco_tint": Color(0.9, 0.92, 1.0),
			"road": Color("42444c"), "line": Color("d8d4c8"),
			"river": Color("4a7898"), "rail": Color("7a7268"),
			"ambient": Color(0.8, 0.84, 0.98), "night": true, "snow": false,
			"trees": ["bush", "rock", "bush", "rock"],
			"weights": { "grass": 0.32, "road": 0.5, "river": 0.0, "rail": 0.18},
			"river_run": 1,
			"cars": ["bus", "taxi", "car_white", "taxi", "bus", "truck"],
			"speed": [130.0, 210.0], "gap": [1.3, 2.6],
			"p_gorani": 0.07, "p_ambush": 0.08,
		},
	]
static func theme_for_row(row: int) -> Dictionary:
	var s:= stages()
	var idx:= int(floor(float(row) / ROWS_PER_STAGE)) % s.size()
	return s[idx]
static func stage_index(row: int) -> int:
	return int(floor(float(row) / ROWS_PER_STAGE))
static func difficulty(row: int) -> float:
	return minf(1.0 + float(row) / 140.0, 2.2)
static func loop_count(row: int) -> int:
	return int(floor(float(row) /(ROWS_PER_STAGE * stages().size())))
static func gorani_p(row: int, base: float) -> float:
	return minf(base *(1.0 + 0.4 * loop_count(row)), 0.45)
static func rush_lane_p(row: int) -> float:
	var l:= loop_count(row)
	if l <= 0:
		return 0.0
	return minf(0.1 + 0.04 *(l - 1), 0.3)
static func ambush_p(row: int, base: float) -> float:
	return minf(base *(1.0 + 0.25 * loop_count(row)), 0.5)
