

# ---------------------------------------------------------------------------
# 자동 조종 (재패킹 패치 — 원본에 없는 코드)
#
# 원칙: **시뮬레이션 상태를 절대 건드리지 않는다.** 봇은 사람의 손가락과 똑같이
# `try_move()`로 `pending_input`만 세운다. `rng`를 한 번이라도 더 소모하거나
# `_gen_row()`를 직접 부르면 월드가 달라지고, 서버가 시드로 trace를 재현할 때
# 결과가 어긋나 제출이 거부된다. 관측은 전부 읽기 전용이다.
#
# 관측 가능한 것: `rows`에는 `int(cam_row)+14`까지 생성되어 있고 플레이어는
# 대략 `cam_row+3`에 있으므로 10행 앞까지 차량·기차·막힌 칸을 직접 읽을 수 있다.
#
# 시간 여유: 스크롤 사망은 `568 + (cam_row - row) * 64 > 1000`, 즉
# `cam_row - row > 6.75`다. 홉 직후 `cam_row ≈ max_row - 3`이므로 9.75행,
# 자동 스크롤 상한이 0.62행/초이니 **한 칸에서 약 15초를 기다릴 수 있다.**
# 그래서 봇은 "확실히 안전할 때만 전진"이라는 보수적 규칙을 쓸 수 있다.
# ---------------------------------------------------------------------------

var bot_on := false
var bot_target := 503
var bot_rows := 0          # 0이면 점수 기준으로만 멈춘다
var bot_name := ""
var bot_submit := false
var bot_done := false
var bot_submitted := false
var bot_waited := 0
var bot_bumps := 0
var bot_log_t := 0

# --- 근접 보너스 (`bfarm`) --------------------------------------------------
#
# `score() = max_row - start_row + bonus`이고 `bonus`는 `on_near_miss`로만 +2씩 오른다.
# 지금 실측은 466행에 보너스 34점(17건)뿐이다 — 점수의 7%다. 그런데 600점을 행으로만
# 채우려면 550행 = 청크 22가 필요하고 그 깊이는 한 번도 못 받았다. 보너스를 올리면
# **같은 600점을 430행 = 청크 17**로 만들 수 있고, 그 깊이는 세 번 받았다.
#
# 메커니즘 (`row.gd:356-380`, `game.gd:482`):
#   1. `e["near"] = true`  ← 플레이어가 **그 행에 있고** `|Δx| < NEAR_DIST(84)`일 때
#   2. `on_near_miss()`    ← 그 고라니가 **despawn할 때**(`|x-320| > 920`) 지급, 생존 조건
#   죽음은 `|Δx| < half+18 = 62`이므로 **62~84px가 안전 밴드**다.
#   ★ 그리고 `hazard_hit`은 `not player.hopping`일 때만 검사되고, `hop()`은 `row`/`x`를
#     **홉 시작 즉시** 갱신한다 → 착지 행의 고라니에게 깃발이 꽂히는 동안 8틱 무적이다.
#
# ★★ 그런데 봇이 초당 3~7행으로 달리면 행이 `cam_row - 8`에서 해제되어 **지급 자체가
#    사라진다.** 그래서 보너스가 낮은 원인이 (a) 깃발이 안 꽂혀서인지 (b) 꽂혔는데
#    정산 전에 버려져서인지 **먼저 계측한다.** 아래 두 카운터가 그 답을 준다.
var bot_farm := 0            # 0=끔, 1=정산 대기, 2=+근접 착지 선호 (`bfarm=N`)
var bot_farm_life := 8       # 깃발 꽂힌 행의 남은 수명(행)이 이 값 이하면 전진을 멈춘다
var bot_farm_held := 0       # 정산 대기로 보낸 틱
var bot_farm_seek := 0       # 깃발을 노려 이탈을 미룬 틱
var bot_farm_kmax := 90      # 깃발까지 이만큼(틱) 이내면 버틴다 (`bfkmax`)
var bot_near_seen: Dictionary = {}   # 깃발이 꽂힌 것을 본 고라니 id → 행 (계측 전용)

const BOT_STAY := 45      # 착지 후 이만큼(틱) 안전해야 전진한다 (0.75초)
const BOT_PASS := 14      # 강제 이동 시 최소 여유
const BOT_WATCH := 30     # 지금 칸에 계속 서 있어도 되는지 보는 창 (0.5초)
const BOT_MARGIN := 12.0  # 히트박스에 더하는 여유(px)
const BOT_SLACK_MIN := 2.0
const BOT_DEATH_ROW := 6.75

func _bot_qs(key: String) -> Variant:
	if not OS.has_feature("web"):
		return null
	return JavaScriptBridge.eval("new URLSearchParams(location.search).get('%s')" % key, true)

func _bot_setup() -> void:
	var v = _bot_qs("bot")
	bot_on = v != null and str(v) == "1"
	if not bot_on:
		return
	var t = _bot_qs("bt")
	if t != null and str(t).is_valid_int():
		bot_target = int(str(t))
	var br = _bot_qs("br")
	if br != null and str(br).is_valid_int():
		bot_rows = int(str(br))
	var n = _bot_qs("bn")
	if n != null:
		bot_name = str(n)
	var s = _bot_qs("bsub")
	bot_submit = s != null and str(s) == "1"
	var fm = _bot_qs("bfarm")
	if fm != null and str(fm).is_valid_int():
		bot_farm = int(str(fm))
	var fl = _bot_qs("bflife")
	if fl != null and str(fl).is_valid_int():
		bot_farm_life = int(str(fl))
	var km = _bot_qs("bfkmax")
	if km != null and str(km).is_valid_int():
		bot_farm_kmax = int(str(km))
	# 지터용 난수는 반드시 별도 인스턴스를 쓴다. 월드는 `rng`만의 함수여야 하고,
	# 여기서 `rng`를 한 번이라도 소모하면 서버 재현과 어긋난다(vrng와 같은 이유).
	brng = RandomNumberGenerator.new()
	brng.randomize()
	bot_start_t = brng.randi_range(55, 150)
	bot_gap = brng.randi_range(8, 9)
	print("[bot] 사람 타이밍: 첫 입력 %d틱, 홉 간격 %d틱" % [bot_start_t, bot_gap])
	# [로컬 전용 · 커밋 금지] brep=1 → _local/trace.json 을 engine replay_mode 에 먹인다
	var rq = _bot_qs("brep")
	if rq != null and str(rq) == "1":
		var js := "(function(){var x=new XMLHttpRequest();x.open('GET','trace.json',false);x.send();return x.responseText;})()"
		var txt = JavaScriptBridge.eval(js, true)
		var arr = JSON.parse_string(str(txt))
		if arr is Array:
			replay_inputs = arr
			replay_idx = 0
			replay_mode = true
			print("[brep] replay_mode trace=%d seed=%d" % [arr.size(), main.ranking.active_seed])
		else:
			print("[brep] trace.json 파싱 실패")
	var dq = _bot_qs("bdump")
	if dq != null and str(dq) == "1":
		# **포팅 검증용.** 월드의 `rng`를 건드리지 않도록 별도 인스턴스를 쓴다.
		# 이러면 PCG32 재현(난수열)과 소모 순서(행 데이터)를 따로 검증할 수 있다.
		var dbg := RandomNumberGenerator.new()
		dbg.seed = main.ranking.active_seed
		var line := ""
		for i in 12:
			line += "%.9f " % dbg.randf()
		print("[rngdbg] seed=%d randf: %s" % [main.ranking.active_seed, line])
		var dbg2 := RandomNumberGenerator.new()
		dbg2.seed = main.ranking.active_seed
		var l2 := ""
		for i in 8:
			l2 += "%d " % dbg2.randi_range(3, 6)
		print("[rngdbg] randi_range(3,6): %s" % l2)
		# seed -> 첫 난수 대응을 직접 측정한다. state = seed 라면 seed 0은 0.0이 나온다.
		for sd in[0, 1, 2, 3, 255, 1000000919463405]:
			var d3 := RandomNumberGenerator.new()
			d3.seed = sd
			print("[seedmap] %d -> %.9f %.9f %d" % [sd, d3.randf(), d3.randf(),
					RandomNumberGenerator.new().randi()])
		for i in range(-6, 16):
			var r = rows.get(i)
			if r == null:
				continue
			var b := []
			for c in range(COLS):
				if r.is_blocked(c):
					b.append(c)
			print("[rowdbg] %d kind=%d blocked=%s dir=%d spd=%.4f spawn=%.4f railt=%.4f ent=%d ambush=%s pdir=%d" % [
					i, r.kind, str(b), r.lane_dir, r.lane_speed, r.spawn_t, r.rail_t,
					r.entities.size(), str(r.ambush_armed), r.pending_dir])
	print("[bot] target=%d name=%s submit=%s seed=%d token=%s" % [bot_target, bot_name,
			str(bot_submit), main.ranking.active_seed, main.ranking.active_token.substr(0, 12)])

# --- 예측 (모두 읽기 전용) --------------------------------------------------

func _bot_ent_hits(e: Dictionary, px: float, k0: int, k1: int) -> bool:
	var reach: float = float(e["half"]) + 18.0 + BOT_MARGIN
	var sp: float = float(e["speed"])
	for k in range(k0, k1 + 1):
		if absf(float(e["x"]) + sp * float(k) / 60.0 - px) < reach:
			return true
	return false

func _bot_log_at(r, px: float, k: int) -> Variant:
	# k틱 뒤 px를 덮는 통나무. 원본 판정(`half + 4`)보다 8px 보수적으로 본다.
	# 통나무의 화면 밖 랩어라운드는 무시한다 — 랩 직전/직후 위치는 항상 px에서 멀다.
	for e in r.entities:
		if not e["log"]:
			continue
		var x: float = float(e["x"]) + float(e["speed"]) * float(k) / 60.0
		if absf(x - px) <= float(e["half"]) + 4.0 - 8.0:
			return e
	return null

func _bot_rail_safe(r, px: float, k0: int, k1: int) -> bool:
	# 기차는 폭이 830px이라 좌우로 피할 수 없다. "언제 오는가"만 본다.
	# 등장 후 px까지 (px + 344)/950 초 ≈ 최대 30틱이므로 45틱을 유예로 둔다.
	# 이 가드가 없으면 `rail_phase`/`rail_t`의 기본값(idle/0.0) 때문에 모든 행이
	# 기차 위험으로 판정된다 — 첫 실행에서 봇이 한 칸도 못 간 원인이었다.
	if r.kind != Row.KIND_RAIL:
		return true
	match r.rail_phase:
		"run":
			for k in range(k0, k1 + 1):
				var tx: float = r.train_x + Row.TRAIN_SPEED * float(r.train_dir) * float(k) / 60.0
				if absf(px - tx) < r.train_half + 16.0 + 24.0:
					return false
			return true
		"warn":
			return r.rail_t * 60.0 > float(k1) + 45.0
		_:
			return (r.rail_t + 1.25) * 60.0 > float(k1) + 45.0

func _bot_spawn_safe(r, px: float, k0: int, k1: int) -> bool:
	# 아직 없는 차량: `spawn_t`가 0이 되는 시점을 알고 있으므로 그 차를 가정한다.
	# 폭은 가장 큰 차량보다 넉넉하게(half 80) 잡는다.
	if r.kind != Row.KIND_ROAD:
		return true
	var k_sp := int(ceil(r.spawn_t * 60.0))
	if k_sp > k1:
		return true
	var entry := -Row.SPAWN_MARGIN if r.lane_dir > 0 else 640.0 + Row.SPAWN_MARGIN
	var sp: float = r.lane_speed * float(r.lane_dir)
	for k in range(maxi(k0, k_sp), k1 + 1):
		if absf(entry + sp * float(k - k_sp) / 60.0 - px) < 80.0 + 18.0 + BOT_MARGIN:
			return false
	return true

func _bot_cell_safe(idx: int, px: float, k0: int, k1: int) -> bool:
	var r = rows.get(idx)
	if r == null:
		return false
	if r.kind == Row.KIND_RIVER:
		# 통나무 위에서는 차량 판정이 없다. 착지 순간 통나무가 있는지만 본다.
		return _bot_log_at(r, px, k0) != null
	for e in r.entities:
		if e["log"]:
			continue
		if _bot_ent_hits(e, px, k0, k1):
			return false
	if r.pending_gorani > 0.0 and _bot_gorani_arrival(r, px) <= float(k1) + 20.0:
		return false
	if r.kind == Row.KIND_GRASS and r.ambush_armed and not r.ambush_done and idx != player.row:
		# 착지가 매복을 깨운다: 0.45초 뒤 등장 + 도달 50틱. 통과만 하면 안전하다.
		# **머무는 시간(k1 - k0)** 으로 봐야 한다. 절대 틱(k1)으로 비교하면 구간 끝 행에서
		# 항상 거짓이 되어 계획이 영구히 성립하지 않는다 — 15행·81행 스크롤 사망의 원인.
		if k1 - k0 > 27 + 50:
			return false
	if not _bot_rail_safe(r, px, k0, k1):
		return false
	return _bot_spawn_safe(r, px, k0, k1)

func _bot_near_window() -> Array:
	# 지금 이 칸에서 **아직 깃발이 없는** 고라니가 근접 밴드(84px)에 드는 틱 `kf`와
	# 죽는 밴드(62px)에 드는 틱 `kk`를 잰다. 기회가 없으면 [-1, -1].
	#
	# ★ 왜 "버티다가 나간다"인가. `_step_entities`는 `_sim_tick`에서 `_bot_decide` **뒤에**
	#   돌고, `hop()`은 `row`/`x`를 홉 시작 즉시 갱신한다. 그래서 깃발이 꽂히는 그 틱에
	#   홉하면 이미 다음 행에 있는 것으로 판정되어 **깃발을 놓친다.** 한 틱은 반드시
	#   그 행에 서 있어야 한다. 그 뒤 62px까지 22px(≈7.5틱)가 남고, 홉 8틱은 무적이므로
	#   (`hazard_hit`은 `not player.hopping`일 때만 검사) 탈출할 시간이 있다.
	#
	# 틱 루프를 돌지 않고 1차식으로 푼다 — 60배속에서 프레임당 90틱 스캔은 비싸다.
	var r = rows.get(player.row)
	if r == null:
		return [-1, -1]
	var px := player.x
	var bf := -1
	var bk := -1
	for e in r.entities:
		if e["log"] or not bool(e["gorani"]) or bool(e["near"]):
			continue
		var v: float = float(e["speed"]) / 60.0     # px/틱
		if absf(v) < 0.001:
			continue
		var dx0: float = float(e["x"]) - px
		var kf := 0
		var kk := 999
		if absf(dx0) >= 84.0:
			# 다가오지 않으면 기회가 없다
			if (dx0 > 0.0) == (v > 0.0):
				continue
			kf = int(ceil((absf(dx0) - 84.0) / absf(v)))
			kk = int(floor((absf(dx0) - 62.0) / absf(v)))
		elif absf(dx0) >= 62.0:
			kf = 0                                   # 이미 밴드 안 — 이번 틱에 꽂힌다
			kk = 999 if (dx0 > 0.0) == (v > 0.0) else int(floor((absf(dx0) - 62.0) / absf(v)))
		else:
			continue                                 # 이미 죽는 거리다 (여기 오면 안 된다)
		if bf < 0 or kf < bf:
			bf = kf
			bk = kk
	# ★ **경고 중인 고라니(아직 스폰 전)가 진짜 기회다.**
	#   `_bot_cell_safe`는 `pending_gorani > 0`이면 도착 예정만 보고 이탈한다. 그래서
	#   고라니가 실제로 생길 때 봇은 이미 그 행에 없고, `r.entities`만 보는 위 루프는
	#   기회를 영원히 못 찾는다 — 첫 측정에서 `노림=0`이 나온 이유가 정확히 이것이다.
	#   `_bot_gorani_arrival`이 62px(죽는 거리) 도달 틱을 주므로, 거기서 22px만큼
	#   앞선 틱이 깃발이 꽂히는 틱이다.
	if r.pending_gorani > 0.0:
		var spd: float = 245.0 * (1.0 + r.diff * 0.18)
		if r.kind == Row.KIND_ROAD:
			spd = r.lane_speed * r.gorani_mult
		var kk2 := int(_bot_gorani_arrival(r, px))
		var kf2 := kk2 - int(22.0 / maxf(spd, 1.0) * 60.0)
		if kf2 >= 0 and (bf < 0 or kf2 < bf):
			bf = kf2
			bk = kk2
	return [bf, bk]

func _bot_farm_escape_ok(kf: int) -> bool:
	# 깃발이 꽂힌 **직후** 나갈 칸이 실제로 있는가. 없으면 버티면 안 된다 —
	# 기존 비상 로직은 "그 자리가 최선"이면 서 있기를 고른다(그러면 죽는다).
	for d in[Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1)]:
		var t := _bot_move_target(d)
		if t["ok"] and _bot_cell_safe(t["row"], t["x"], kf + 1, kf + 1 + BOT_WATCH):
			return true
	return false

func _bot_near_scan() -> int:
	# 깃발이 꽂힌 고라니를 세고 **가장 낮은 행**을 돌려준다(없으면 -1). 그 행이 먼저
	# 해제되므로 정산을 잃을 위험이 가장 큰 깃발이다. 전부 읽기 전용 — `rng`도, 엔티티도
	# 건드리지 않는다(§2 불변식). 살아 있는 행만 도는 것은 원본의 `step` 범위와 같다.
	var lo := -1
	for idx in range(int(cam_row) - 7, int(cam_row) + 15):
		var r = rows.get(idx)
		if r == null:
			continue
		for e in r.entities:
			if not e["gorani"] or not e["near"]:
				continue
			bot_near_seen[e["node"].get_instance_id()] = idx
			if lo < 0 or idx < lo:
				lo = idx
	return lo

func _bot_slack() -> float:
	# 남은 스크롤 여유(행). cam_row는 `max_row - 3`을 향해 4.5*dt로 당겨지므로
	# 우리가 max_row보다 뒤에 있으면 그 목표를 기준으로 봐야 보수적이다.
	var target := maxf(cam_row, float(max_row) - 3.0)
	return BOT_DEATH_ROW - (target - float(player.row))

func _bot_scroll_k() -> int:
	# 스크롤이 우리를 잡기까지 남은 틱. `_sim_tick`의 auto 식을 그대로 쓴다.
	var auto := 0.0
	if elapsed > 3.0:
		auto = minf(0.1 + float(max_row) * 0.004, 0.62)
	if auto <= 0.0:
		return 99999
	return int(maxf(_bot_slack(), 0.0) / auto * 60.0)

func _bot_kind(idx: int) -> int:
	var r = rows.get(idx)
	return -1 if r == null else int(r.kind)

func _bot_ride_left() -> int:
	# 통나무가 우리를 화면 밖으로 밀어내기까지 남은 틱 (X_MIN/X_MAX에서 익사)
	if player.riding == null:
		return 99999
	var sp: float = float(player.riding["speed"])
	if absf(sp) < 0.001:
		return 99999
	var lim := X_MAX - 6.0 if sp > 0.0 else X_MIN + 6.0
	return int((lim - player.x) / sp * 60.0)

func _bot_armed(idx: int) -> bool:
	# 착지하면 고라니를 깨우는 풀밭 — 여기서 오래 기다리면 죽는다(`trigger_ambush`)
	var r = rows.get(idx)
	return r != null and r.kind == Row.KIND_GRASS and r.ambush_armed and not r.ambush_done

func _bot_gorani_arrival(r, px: float) -> float:
	# 경고 중인 고라니가 px에 닿는 시각(틱). 풀밭은 소환 시점에 속도가 정해지므로
	# `_step_grass`의 식을 그대로 쓴다. 도로는 차선 속도 × gorani_mult다.
	var spd: float = 245.0 * (1.0 + r.diff * 0.18)
	if r.kind == Row.KIND_ROAD:
		spd = r.lane_speed * r.gorani_mult
	var dir: int = r.pending_dir if r.kind == Row.KIND_GRASS else r.lane_dir
	var from_x := -Row.SPAWN_MARGIN if dir > 0 else 640.0 + Row.SPAWN_MARGIN
	var dist := absf(px - from_x) - (44.0 + 18.0)
	return r.pending_gorani * 60.0 + maxf(dist, 0.0) / maxf(spd, 1.0) * 60.0

func _bot_hit_tick(idx: int, px: float, k0: int, kmax: int) -> int:
	# [k0, kmax] 안에서 px가 처음 위험해지는 틱. 없으면 kmax.
	# 최후 수단 선택용이므로 여유(BOT_MARGIN)를 더하지 않고 원본 판정을 그대로 쓴다.
	var r = rows.get(idx)
	if r == null:
		return 0
	if r.kind == Row.KIND_RIVER:
		# 통나무가 없으면 즉사, 있으면 **밀려서 화면 밖으로 나가는 시각**이 마감이다.
		# 이걸 빼놓아서 "강은 150틱 안전"으로 보고 서 있다가 두 번 익사했다.
		var lg = _bot_log_at(r, px, k0)
		if lg == null:
			return 0
		var lsp: float = float(lg["speed"])
		if absf(lsp) < 0.001:
			return kmax
		var lim := X_MAX if lsp > 0.0 else X_MIN
		return mini(kmax, k0 + int((lim - px) / lsp * 60.0))
	var best := kmax
	for e in r.entities:
		if e["log"]:
			continue
		var reach: float = float(e["half"]) + 18.0
		var sp: float = float(e["speed"])
		for k in range(k0, best + 1):
			if absf(float(e["x"]) + sp * float(k) / 60.0 - px) < reach:
				best = k
				break
	if r.pending_gorani > 0.0:
		best = mini(best, int(_bot_gorani_arrival(r, px)))
	if r.kind == Row.KIND_ROAD:
		var k_sp := int(ceil(r.spawn_t * 60.0))
		var entry := -Row.SPAWN_MARGIN if r.lane_dir > 0 else 640.0 + Row.SPAWN_MARGIN
		var spd: float = r.lane_speed * float(r.lane_dir)
		best = mini(best, k_sp + int(maxf(absf(px - entry) - 98.0, 0.0)
				/ maxf(absf(spd), 1.0) * 60.0))
	if r.kind == Row.KIND_RAIL:
		var appear := 0.0
		match r.rail_phase:
			"run":
				for k in range(k0, best + 1):
					var tx: float = r.train_x + Row.TRAIN_SPEED * float(r.train_dir) * float(k) / 60.0
					if absf(px - tx) < r.train_half + 16.0:
						best = k
						break
			"warn":
				appear = r.rail_t * 60.0
			_:
				appear = (r.rail_t + 1.25) * 60.0
		if appear > 0.0:
			best = mini(best, int(appear + (px + 344.0) / Row.TRAIN_SPEED * 60.0))
	return maxi(best, k0)

# --- 판단 ------------------------------------------------------------------
#
# 핵심: **위험한 행에 서 있지 않는다.**
# `_sim_tick`은 홉 중에(`player.hopping`) hazard 검사를 건너뛴다. 8틱마다 끊김 없이
# 전진하면 중간 행은 **착지하는 한 틱만** 노출된다. 그래서 안전한 풀밭에서
# "다음 안전한 풀밭까지의 구간 전체"를 한 번에 검사해 통째로 건널 수 있고,
# 도로·강·레일 위에서 기다리다 갇히는 사망 경로가 아예 사라진다.
# (초기 정책은 행마다 '머물러도 되는가'를 물었고, 그 답이 어긋나는 지점에서
#  35~95행마다 죽었다 — 차에 치이거나, 통나무에 밀려 익사하거나, 스크롤에 깔렸다.)

const BOT_MAX_SEG := 9    # 한 번에 계획하는 최대 구간 길이(행)
const BOT_LOOKAHEAD := 12 # 열의 전방 통행 거리를 볼 범위(행)
const BOT_MAX_WAIT := 70  # 구간 안에서 한 행에 머물 수 있는 최대 대기(틱)

var bot_hops: Array = []  # 실행 중인 계획의 남은 홉 시각(절대 틱)
var bot_stuck := 0        # 계획이 서지 않은 연속 틱
var bot_br := 0           # 마지막 판단 분기 (진단용)
var bot_prog_row := -99999  # 마지막으로 전진한 행
var bot_prog_t := 0         # 그 시각
var bot_stay_need := 45     # 착지 지점에 요구하는 안전 창 (정체하면 낮춘다)
var bot_hop_t := -999       # 마지막 홉 시각
var bot_gap := 9            # 홉 간격(틱). 8이 엔진 최소값이다
var bot_start_t := 0        # 이 틱 전에는 입력하지 않는다 (사람의 반응 시간)
var brng: RandomNumberGenerator = null   # **월드 rng와 분리** — 시드를 오염시키면 안 된다
var bot_lat := 0          # 마지막 좌우 이동 방향
var bot_lat_t := -999     # 그 시각

func _bot_side(dd: int) -> bool:
	# 좌우 이동을 허가할지. 방금 간 방향으로 되돌아가는 것을 60틱 막는다.
	# 이 가드가 없으면 두 열 사이를 8틱마다 왕복하며 제자리에서 스크롤에 깔린다
	# (행이 바뀌지 않아 대기·비상 카운터도 늘지 않아 한동안 눈치채지 못했다).
	if dd == -bot_lat and tick_count - bot_lat_t < 60:
		return false
	return true

func _bot_go_side(dd: int) -> void:
	bot_lat = dd
	bot_lat_t = tick_count
	_bot_move(Vector2i(dd, 0))

func _bot_move(dir: Vector2i) -> void:
	bot_hop_t = tick_count
	try_move(dir)

func _bot_move_target(dir: Vector2i) -> Dictionary:
	# `_apply_move`와 같은 규칙으로 목적지를 구한다. bump가 될 이동은 ok=false.
	var to_row: int = player.row + dir.y
	if to_row < 0:
		return { "ok": false}
	var to_x: float = player.x
	if dir.x != 0:
		if player.riding != null:
			to_x = player.x + float(dir.x) * CELL
			if to_x < X_MIN or to_x > X_MAX:
				return { "ok": false}
		else:
			var to_col: int = col_of(player.x) + dir.x
			if to_col < 0 or to_col >= COLS:
				return { "ok": false}
			to_x = center_x(to_col)
	var target = rows.get(to_row)
	if target == null:
		return { "ok": false}
	if target.kind == Row.KIND_GRASS and target.is_blocked(col_of(to_x)):
		return { "ok": false}
	return { "ok": true, "row": to_row, "x": to_x}

func _bot_col_reach(from_row: int, col: int) -> int:
	# from_row 다음 행부터 **나무에 막히지 않고 지날 수 있는 연속 행수**.
	# `blocked`는 생성 시 고정이라 시간과 무관하고 계산이 싸다. 봇의 사망 1순위가
	# "이 열로는 앞으로 갈 수 없는데 좌우도 막힌" 함정이므로, 열 선택의 기준이 된다.
	var n := 0
	for m in range(1, BOT_LOOKAHEAD + 1):
		var r = rows.get(from_row + m)
		if r == null:
			break
		if r.kind == Row.KIND_GRASS and r.is_blocked(col):
			break
		n += 1
	return n

func _bot_seg_end(x: float) -> int:
	# x 열로 전진할 때 **멈춰도 되는 첫 앞 행**까지의 거리. 0이면 이 열로는 못 나간다.
	for m in range(1, BOT_MAX_SEG + 1):
		var r = rows.get(player.row + m)
		if r == null:
			return 0
		if r.kind == Row.KIND_GRASS:
			if r.is_blocked(col_of(x)):
				return 0          # 나무: 이 열로는 통과도 정지도 불가
			return m
	return 0

func _bot_col_dir() -> int:
	# **전방 통행 거리가 가장 긴 열** 쪽 방향(±1). 같으면 가까운 쪽, 없으면 0.
	# 앞 행의 나무만 보면 안 된다 — 실제로 막는 나무는 구간 안쪽에 있을 수 있고,
	# 그걸 놓쳐서 엉뚱한 방향으로 갔다가 갇혔다(20행·60행 스크롤 사망).
	var col := col_of(player.x)
	var mine := _bot_col_reach(player.row, col)
	var best := mine
	var dir := 0
	for d in range(1, COLS):
		for sgn in[1, -1]:
			var c2: int = col + sgn * d
			if c2 < 0 or c2 >= COLS:
				continue
			var n := _bot_col_reach(player.row, c2)
			if n > best:
				best = n
				dir = sgn
	return dir

func _bot_not_dead_end(idx: int, x: float) -> bool:
	# 착지 지점에서 **나갈 길이 있어야** 한다. 앞이 나무로 막혔는데 좌우까지 막힌 칸에
	# 들어가면 스크롤에 깔릴 때까지 갇힌다 — 합법적인 수가 하나도 없어 비상 분기도
	# 손을 쓸 수 없다(159행 사망: col 4, 앞·좌·우 전부 나무).
	var r = rows.get(idx)
	if r == null:
		return true
	var col := col_of(x)
	# 앞으로 2행 이상 나갈 수 있으면 충분하다. 1행만 열려 있으면 그 다음에 또 갇힐 수 있다.
	if _bot_col_reach(idx, col) >= 1:
		return true
	# 앞이 막혔다면 좌우로 옮길 수 있고, 그 열이 앞으로 나갈 수 있어야 한다
	for dd in[1, -1]:
		var c2: int = col + dd
		if c2 < 0 or c2 >= COLS or r.is_blocked(c2):
			continue
		if _bot_col_reach(idx, c2) >= 1:
			return true
	return false

func _bot_plan_chain(m: int, x: float) -> Array:
	# **행마다 머무는 시간을 유동적으로 잡는 구간 계획.** 반환값은 홉 시각(지금 기준 상대 틱)
	# 목록이고, 실패하면 빈 배열이다.
	#
	# 고정 간격 계획은 구간의 모든 행이 **동시에** 열리는 창을 요구한다. 4행 이상이면 그런
	# 창이 거의 없어 봇이 몇 초씩 정지하다 스크롤에 깔렸다. 사람은 빈틈으로 뛰어들어 잠깐
	# 기다리고 다시 뛴다 — 그 자유도를 준다. 각 행의 **점유 구간 전체**를 검사하므로
	# 검증되지 않은 정지는 여전히 없다.
	var hops := []
	var h_prev := 0                       # 지금(0틱)에 첫 홉
	for i in range(1, m + 1):
		var r = rows.get(player.row + i)
		if r == null:
			return []
		if r.kind == Row.KIND_GRASS and r.is_blocked(col_of(x)):
			return []                     # 나무: 통과 불가
		var land := h_prev + 8
		if i == m:
			# 계획이 끝난 뒤에는 검증 없이 서 있게 되므로, 정지 지점에는 넉넉한 창을
			# 요구한다. 도로·레일에 앉았다가 창이 만료되고 치인 것이 사망 1순위였다.
			# 풀밭이 아니면 두 배를 요구해 사실상 풀밭까지 건너게 만든다.
			var need: int = bot_stay_need
			if r.kind != Row.KIND_GRASS:
				need *= 2
			if not _bot_cell_safe(player.row + i, x, land, land + need):
				return []
			hops.append(h_prev)
			return hops
		# 나갈 시각을 찾는다. 이 행에 [land, h] 동안 머물 수 있고, 다음 행에 h+8에
		# 들어갈 수 있어야 한다 — 두 행을 함께 봐야 계획이 중간에 끊기지 않는다.
		var found := -1
		var h := maxi(land, h_prev + bot_gap)
		while h <= land + BOT_MAX_WAIT:
			if _bot_cell_safe(player.row + i, x, land, h + 1) \
					and _bot_cell_safe(player.row + i + 1, x, h + 8, h + 10):
				found = h
				break
			h += 2
		if found < 0:
			return []
		hops.append(h_prev)
		h_prev = found
	return hops

func _bot_plan_ok(m: int, x: float) -> bool:
	if _bot_plan_chain(m, x).is_empty():
		return false
	return _bot_not_dead_end(player.row + m, x)

func _bot_plan_m() -> int:
	# **갈 수 있는 가장 먼 정지 지점.** 풀밭까지 한 번에 건너는 것이 최선이지만,
	# 위험 구간이 5~6행이면 모든 행이 동시에 열리는 창이 거의 없다. 중간의 빈 차선에
	# 멈추는 것을 허용하지 않으면 진행이 막힌다(354행에서 600틱 정지 후 스크롤 압박).
	# 강 위에서는 통나무에 밀려 나가므로 정지 지점이 될 수 없다.
	var goal := _bot_seg_end(player.x)
	var hi: int = goal if goal > 0 else BOT_MAX_SEG
	for m in range(hi, 0, -1):
		var r = rows.get(player.row + m)
		if r == null:
			continue
		if r.kind == Row.KIND_RIVER:
			# 강에서는 통나무에 밀리므로, 화면 밖으로 나가기까지 2초 이상 남을 때만
			# 정지 지점으로 쓴다. 이걸 막아 두면 강을 포함한 긴 구간이 통째로 계획
			# 불가가 되어 봇이 강 앞에서 정지한다.
			if _bot_hit_tick(player.row + m, player.x, 8, 200) < 120:
				continue
		if _bot_plan_ok(m, player.x):
			return m
	return 0

func _bot_decide() -> void:
	if not bot_on or player.dead or player.hopping or state != "play":
		return
	pending_input = Vector2i.ZERO
	if tick_count - bot_log_t >= 300:
		bot_log_t = tick_count
		print("[bot] t=%d row=%d col=%d cam=%.1f score=%d r/s=%.2f 대기=%d 비상=%d br=%d m=%d hops=%d stuck=%d stall=%d reach=%d" % [
				tick_count, player.row, col_of(player.x), cam_row, score(),
				float(max_row - start_row) / maxf(elapsed, 0.001), bot_waited, bot_bumps,
				bot_br, _bot_seg_end(player.x), bot_hops.size(), bot_stuck,
				tick_count - bot_prog_t, _bot_col_reach(player.row, col_of(player.x))])
	if bot_done:
		return
	if score() >= bot_target or (bot_rows > 0 and rows_crossed() >= bot_rows):
		bot_done = true
		print("[bot] 목표 도달 score=%d rows=%d bonus=%d tick=%d 대기=%d 비상=%d" % [
				score(), rows_crossed(), bonus, tick_count, bot_waited, bot_bumps])
		return

	# 정체 감시자. 봇의 전략은 "검증된 완전 통과" 하나뿐이라, 그것이 성립하지 않는
	# 지형(나무로 막힌 열 등)에서는 스크롤 여유 9.75행을 전부 대기로 쓰다 죽는다.
	# 전진이 멈춘 시간에 따라 기준을 단계적으로 풀고, 9초를 넘기면 비상 판단으로 넘긴다.
	if player.row > bot_prog_row:
		bot_prog_row = player.row
		bot_prog_t = tick_count
	var stall := tick_count - bot_prog_t
	# **여유는 자원이다.** 좋은 계획을 기다리며 여유를 다 쓰면, 막힌 열에 갇혔을 때
	# 후퇴할 여지가 없어 회복이 불가능해진다(93행 col 8 사망). 그래서 정체 시간과
	# 남은 여유 **둘 다** 기준을 낮추는 방향으로 쓴다.
	var sl := _bot_slack()
	if stall < 240 and sl > 5.0:
		bot_stay_need = BOT_STAY
	elif stall < 480 and sl > 3.0:
		bot_stay_need = 20
	else:
		bot_stay_need = 10

	# 사람의 반응 시간. 1틱에 첫 키가 들어가는 트레이스는 기계임이 자명하다.
	if tick_count < bot_start_t:
		return
	# ★ 근접 보너스: **계측은 항상, 개입은 `bfarm`이 있을 때만.** 원인을 모르는 채로
	#   행동을 바꾸면 무엇이 효과가 있었는지 알 수 없다.
	var farm_hold := false
	if bot_farm > 0 or tick_count % 3 == 0:
		var pr := _bot_near_scan()
		if bot_farm > 0 and pr >= 0:
			# 행 pr은 `pr < int(cam_row) - 7`이 되면 step을 멈추고 정산이 사라진다.
			# 남은 수명(행) = pr - (int(cam_row) - 7). 얕아지면 전진을 멈춘다.
			# 전진을 멈춰도 cam_row는 auto(최대 0.62행/s)로 계속 오므로 무한정은 아니다 —
			# 고라니의 despawn까지 3.1~6.4초가 필요하고 그 사이 cam은 4행쯤 온다.
			if pr - (int(cam_row) - 7) <= bot_farm_life:
				farm_hold = true
				bot_farm_held += 1
				bot_hops.clear()     # 진행 중인 전진 계획도 멈춘다
	# ★★ `bfarm>=2`: 근접 보너스를 **노린다.**
	#
	#   봇은 `BOT_WATCH=30틱` 창으로 안전을 보므로 고라니가 약 161px일 때 이미 자리를
	#   뜬다 — 근접 밴드 84px에 들어갈 일이 없다(실측 깃발 4건/149행, 보너스는 점수의 7%).
	#   그래서 **깃발이 꽂히는 틱까지만 이탈을 미룬다.** 탈출은 기존 비상 분기가 한다:
	#   깃발이 꽂히면 그 고라니는 `near=true`가 되어 다음 틱부터 `_bot_near_window`에서
	#   빠지고, `farm_seek`이 풀려 `urgent`가 살아나 비상 분기가 즉시 뛴다.
	#
	#   버티는 조건을 좁게 잡는다 — 죽으면 그 회차가 통째로 날아가고, 앵커 때문에
	#   되감기 여지도 없다(§앵커). 탈출 칸이 실제로 있는지까지 확인한다.
	var farm_seek := false
	if bot_farm >= 2 and not farm_hold and not bot_done:
		var w := _bot_near_window()
		var kf: int = int(w[0])
		var kk: int = int(w[1])
		if kf >= 0 and kf <= bot_farm_kmax and kk - kf >= 5 \
				and tick_count + kf + 1 - bot_hop_t >= bot_gap \
				and _bot_scroll_k() > kf + 300 \
				and _bot_ride_left() > kf + 90 \
				and _bot_farm_escape_ok(kf):
			farm_seek = true
			bot_farm_seek += 1
			bot_hops.clear()
	# 홉 간격 유지. 8틱(엔진 최소)을 연속으로 내는 것도 사람이 할 수 없는 일이다.
	# 단 비상 분기는 이 제한을 받지 않는다 — 사람도 위험하면 즉시 반응한다.
	var can_hop := tick_count - bot_hop_t >= bot_gap

	var fwd := Vector2i(0, 1)
	var f := _bot_move_target(fwd)

	# 계획 실행 중: 다음 홉 시각까지는 기다린다. 다만 위험은 계속 감시한다.
	if not bot_hops.is_empty():
		if tick_count < int(bot_hops[0]):
			# `_bot_cell_safe`는 강의 표류를 모른다. 계획대로 기다리는 동안 통나무에
			# 밀려 X_MAX를 넘어 익사한 적이 있다.
			if _bot_cell_safe(player.row, player.x, 0, 14) and _bot_ride_left() > 20:
				return
			bot_hops.clear()          # 예상 못한 위험 → 계획 파기

	# 1. 계획 실행 중이면 착지 즉시 다시 뛴다. 단 새로 스폰된 차가 있을 수 있으므로
	#    착지 지점만 다시 확인하고, 어긋나면 계획을 버리고 비상 판단으로 넘긴다.
	if not bot_hops.is_empty():
		if f["ok"] and _bot_cell_safe(f["row"], f["x"], 8, 11):
			bot_hops.remove_at(0)
			bot_br = 1
			_bot_move(fwd)
			return
		bot_hops.clear()

	# 2. 구간 계획. 지금 이 틱에 출발할 수 있는지만 본다 — 안 되면 다음 틱에 다시
	#    물으므로 출발 시각 탐색을 따로 할 필요가 없다.
	var m := 0
	if can_hop and not farm_hold and not farm_seek:
		# 구간마다 간격을 새로 뽑는다. 계획 중에만 바꾸므로 실행 중 타이밍은 고정된다.
		# 8틱은 엔진 최소값이지만 보드의 검증된 상위 항목들도 3.8행/초를 내므로
		# 연사 자체는 문제가 아니다. 완전히 고정된 8틱만 피한다.
		bot_gap = brng.randi_range(8, 9)
		m = _bot_plan_m()
	if m > 0:
		var chain := _bot_plan_chain(m, player.x)
		if not chain.is_empty():
			bot_hops = []
			for i in range(1, chain.size()):     # 첫 홉은 지금 하므로 제외
				bot_hops.append(tick_count + int(chain[i]))
			bot_stuck = 0
			bot_br = 2
			_bot_move(fwd)
			return
	bot_stuck += 1

	# 3. 이 열로는 나갈 수 없거나(나무) 오래 막혀 있으면 열을 옮긴다.
	var col := col_of(player.x)
	var goal := _bot_seg_end(player.x)
	var reach := _bot_col_reach(player.row, col)
	if can_hop and (goal == 0 or bot_stuck > 90 or stall > 240):
		for dd in[1, -1]:
			var c2: int = col + dd
			if c2 < 0 or c2 >= COLS:
				continue
			var m2 := _bot_seg_end(center_x(c2))
			if m2 == 0 or (goal > 0 and not _bot_plan_ok(m2, center_x(c2))):
				continue
			if not _bot_side(dd):
				continue
			var s := _bot_move_target(Vector2i(dd, 0))
			if s["ok"] and _bot_cell_safe(s["row"], s["x"], 8, 8 + BOT_WATCH):
				bot_stuck = 0
				bot_br = 31
				_bot_go_side(dd)
				return
		if goal == 0:
			# **전방이 트인 열로 옮긴다.** 갇힌 뒤에는 손쓸 수 없다.
			# 그 방향이 현재 행의 나무로 막히면 **반대쪽도** 시도하고,
			# 둘 다 막히면 뒤로 물러나 우회한다.
			var want := _bot_col_dir()
			for dd2 in[want, -want]:
				if dd2 == 0 or not _bot_side(dd2):
					continue
				var s2 := _bot_move_target(Vector2i(dd2, 0))
				if s2["ok"] and _bot_cell_safe(s2["row"], s2["x"], 8, 8 + BOT_WATCH):
					bot_br = 32
					_bot_go_side(dd2)
					return
			if _bot_slack() > 3.5:
				var bk := _bot_move_target(Vector2i(0, -1))
				if bk["ok"] and _bot_cell_safe(bk["row"], bk["x"], 8, 8 + BOT_WATCH):
					bot_br = 33
					_bot_move(Vector2i(0, -1))
					return

	# 4. 지금 칸이 안전하고 스크롤도 멀면 기다린다. 대기는 공짜다 — 한 칸에서
	#    최대 15초를 버틸 수 있다(`_bot_slack`).
	var urgent: bool = not _bot_cell_safe(player.row, player.x, 0, BOT_WATCH) \
			or _bot_ride_left() < 90 or _bot_scroll_k() < 420 or stall > 420
	# ★ 깃발을 노리는 동안만 조기 이탈을 막는다. `farm_seek`은 위에서 스크롤·통나무·
	#   탈출칸·홉간격을 모두 확인한 뒤에만 켜지고, 깃발이 꽂히는 즉시 풀린다.
	if farm_seek:
		urgent = false
	if not urgent:
		bot_br = 4
		bot_waited += 1
		if bot_waited % 240 == 0:
			print("[wait] t=%d row=%d col=%d m=%d stuck=%d slack=%.2f scroll=%d f=%s" % [
					tick_count, player.row, col, m, bot_stuck, _bot_slack(),
					_bot_scroll_k(), str(f["ok"])])
		return

	# 5. 비상. 후보마다 **첫 충돌 틱**을 재서 가장 늦은 칸으로 뛴다. 정지도 후보이므로
	#    서 있는 게 최선이면 서 있는다. 전진에 동점 보너스를 줘 진행을 잃지 않는다.
	# 탐색 상한이 스크롤 마감보다 작으면 "여기가 제일 안전"이 영원히 이겨 갇힌 자리에서
	# 못 나온다 — 상한을 300으로 올린다(78행에서 611회 정지 후 사망).
	var stay_k := mini(_bot_hit_tick(player.row, player.x, 0, 300), _bot_scroll_k())
	var best_k := stay_k
	var best_dir := Vector2i.ZERO
	# 정체가 길어질수록 전진에 가중치를 준다. 비상 판단은 한 홉만 보므로 갇힌 자리에서는
	# 정지가 계속 최선으로 뽑힌다. 나가야 살아난다.
	var push: int = mini(stall / 8, 80)
	# 후퇴는 여유를 1행 더 깎으므로 값을 낮게 주되, **금지하지는 않는다.** 좌우가 나무로
	# 막힌 자리에서는 후퇴가 유일한 탈출로다(-999로 막아 두고 20행에서 죽었다).
	var back_w := -4 if _bot_slack() > 3.0 else (-50 if _bot_slack() > 1.2 else -999)
	for c in[[fwd, 8 + push], [Vector2i(-1, 0), push / 2], [Vector2i(1, 0), push / 2],
			[Vector2i(0, -1), back_w]]:
		var t := _bot_move_target(c[0])
		if not t["ok"]:
			continue
		var k: int = _bot_hit_tick(t["row"], t["x"], 8, 300) + int(c[1])
		if not _bot_not_dead_end(t["row"], t["x"]):
			k -= 40          # 갇히는 칸으로 도망가면 스크롤에 깔린다 (159행 사망)
		var ec := col_of(t["x"])
		if ec == 0 or ec == COLS - 1:
			k -= 10          # 끝 열은 탈출구가 하나뿐이고 한쪽 차선의 진입 지점이다
		if k > best_k:
			best_k = k
			best_dir = c[0]
	if best_dir != Vector2i.ZERO:
		bot_br = 5
		if best_dir.x != 0:
			_bot_go_side(best_dir.x)
		else:
			_bot_move(best_dir)
	else:
		bot_br = 6
		bot_bumps += 1

# --- 제출 ------------------------------------------------------------------

func _bot_after_death() -> void:
	if not bot_on:
		return
	# ★ `깃발`은 `near`가 꽂힌 것을 관측한 고라니 수, `정산`은 실제로 지급된 건수
	#   (`bonus/2`). 둘의 비가 이 변경의 판정 근거다 —
	#     깃발 ≈ 정산  → 깃발이 애초에 안 꽂힌다 (착지 선호 `bfarm=2`가 필요하다)
	#     깃발 ≫ 정산  → 꽂히는데 행이 먼저 버려진다 (정산 대기 `bfarm=1`이 답이다)
	print("[run] score=%d rows=%d bonus=%d ticks=%d row=%d cam=%.1f 대기틱=%d bump=%d 깃발=%d 정산=%d 보류=%d 노림=%d" % [
			score(), rows_crossed(), bonus, tick_count, player.row, cam_row, bot_waited,
			bot_bumps, bot_near_seen.size(), bonus / 2, bot_farm_held, bot_farm_seek])
	var dr = rows.get(player.row)
	if dr != null:
		var info := ""
		for e in dr.entities:
			var tag := "log" if e["log"] else ("고라니" if e["gorani"] else "차")
			info += " [%s x=%.0f v=%.0f h=%.0f]" % [tag, e["x"], e["speed"], e["half"]]
		print("[dead] kind=%d x=%.0f rail=%s/%.2f pend=%.2f armed=%s/%s ent:%s" % [
				dr.kind, player.x, dr.rail_phase, dr.rail_t, dr.pending_gorani,
				str(dr.ambush_armed), str(dr.ambush_done), info])
	if not bot_submit or bot_submitted or bot_name == "":
		return
	# 프로토콜 v4: 청크 시드를 서버에서 못 받아 로컬 대체 시드로 만든 월드를 달린
	# 주행이다. 서버는 그 월드를 재현할 수 없으므로 제출은 반드시 거부되고, 토큰만
	# 태우면서 그 닉네임에 "위조 시도 이력"을 남긴다(`leaderboard-api.md` §9.2).
	if unranked:
		print("[bot] 제출 안 함: 맵을 서버에서 못 받은 판이다(unranked)")
		return
	var rows_v := rows_crossed()
	var sc := score()
	if sc < bot_target:
		# 목표에 못 미치는 주행은 올리지 않는다. **점수를 부풀려 보내지도 않는다** —
		# 240행 주행에 503점을 실어 보냈더니 `rejected`(hint 없음)였다. 서버가 트레이스
		# 재현으로 점수까지 계산하는 것으로 보이므로, 클라이언트가 계산한 값을 그대로 낸다.
		print("[bot] 제출 안 함: score=%d rows=%d — 목표 %d에 못 미친다" % [
				sc, rows_v, bot_target])
		return
	bot_submitted = true
	# 사람은 게임오버 화면에서 닉네임을 입력하고 버튼을 누른다. 1.1초 만의 제출은
	# 그 자체로 기계 지표다(서버는 ticks와 토큰 나이 차이로 이를 볼 수 있다).
	main.bot_pending_submit = true
	var wait := brng.randf_range(7.0, 18.0)
	print("[bot] %0.1f초 뒤 제출한다 (사람의 입력 시간)" % wait)
	await get_tree().create_timer(wait).timeout
	print("[bot] 제출 name=%s score=%d rows=%d ticks=%d trace=%d건" % [
			bot_name, sc, rows_v, main.last_ticks, main.last_trace.size()])
	# 성공만 재시도 중단으로 취급한다 — 거부됐다면 다음 주행으로 다시 시도해야 한다
	main.ranking.submitted.connect(func (ok: bool, rank: int, _list: Array):
		print("[bot] 응답 ok=%s rank=%d reason=%s" % [str(ok), rank,
				main.ranking.submit_reason])
		main.bot_pending_submit = false
		if ok:
			main.bot_did_submit = true
		elif main._bot_flag("bloop"):
			print("[bot] 거부됐다 — 다시 주행한다")
			main.retry()
	, CONNECT_ONE_SHOT)
	main.ranking.submit(bot_name, sc, rows_v, main.last_char, main.last_ticks,
			main.last_trace, main.last_unranked)
