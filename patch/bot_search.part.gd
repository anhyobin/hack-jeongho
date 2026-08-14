

# ---------------------------------------------------------------------------
# 체크포인트 탐색 하네스 (재패킹 패치 — 원본에 없는 코드)
#
# "550행을 한 번에 무사고 통과"를 "10~20행씩 여러 번 통과"로 바꾼다. 월드는 시드와
# 입력 시퀀스만의 함수이므로, 죽으면 죽은 지점 앞까지의 trace를 고속 재생해 상태를
# 복원하고 **다른 지터로** 이어서 주행한다. 좋은 접두사는 버리지 않는다.
#
# 왜 main에 있는가: `start_game`이 `game.queue_free()`를 부른다. Game 안에서 await로
# 기다리던 코루틴은 재시작과 함께 통째로 사라진다(제출이 사라진 사고가 있었다).
# main은 해제되지 않으므로 주행을 넘나드는 상태는 전부 여기 있어야 한다.
#
# 봇 판단(`_bot_decide`)은 **블랙박스로 둔다**. 여기서 쓰는 손잡이는 전부 원본
# `game.gd`의 공개 변수(`replay_mode`/`replay_inputs`/`input_trace`)이거나
# `bot_game.part.gd`가 이미 노출한 변수(`bot_on`/`bot_submit`/`bot_hop_t` …)다.
#
# URL 파라미터 (봇 파라미터 bot/bt/bn/bchar/bseed에 더해서)
#   ss=1         체크포인트 탐색
#   sv=1         재생 동일성 검증(첫 관문): 주행 -> 같은 시드로 재생 -> 변이 재생
#   sspd=<수>    Engine.time_scale (기본 25). 고속 재생이 없으면 탐색이 성립하지 않는다
#   sdrop=<행>   죽은 지점에서 되감는 기본 행수 (기본 6)
#   sttl=<초>    탐색 마감 (기본 1200 — 토큰 TTL 1579초 안쪽에서 끝낸다)
#   stok=<토큰>  제출에 쓸 실제 토큰. sseed와 함께 준다
#   sseed=<정수> 그 토큰의 시드. 이 시드로 탐색해야 제출이 의미를 가진다
# ---------------------------------------------------------------------------

# --- 계약 -------------------------------------------------------------------
var search_best: Array = []        # 지금까지 살아남은 최선의 trace [[tick, dircode], ...]
var search_best_rows := 0          # 그 trace가 도달한 행
var search_target := 600

# --- 내부 상태 --------------------------------------------------------------
const SEARCH_TICK_CAP := 8         # 원본 MAX_TICKS_PER_FRAME (탐색이 꺼져 있을 때)
const SEARCH_CAP_REPLAY := 6000    # 재생 중 프레임당 틱 상한 (판단 비용이 없어 싸다)
const SEARCH_CAP_LIVE := 1200      # 봇이 주행하는 동안의 상한

var search_mode := ""              # "" | "verify" | "search" | "submit" | "done"
var search_phase := ""             # 검증 단계 "v1" | "v2" | "v3"
var search_seed := 0               # 탐색과 제출이 공유하는 월드 시드
var search_token := ""             # 제출에 쓸 실제 토큰 (탐색 중 보존한다)
var search_name := ""
var search_char := "peccy"
var search_base: Array = []        # 이번 주행에서 재생할 접두사
var search_base_rows := 0          # 그 접두사가 도달하는 행
var search_hand_tick := -1         # 이 틱을 넘기면 재생을 끊고 봇에게 넘긴다. -1이면 안 넘긴다
var search_iter := 0
var search_fail := 0               # 최선을 갱신하지 못한 연속 횟수
var search_drop := 6               # 되감기 기본 행수
var search_speed := 25.0           # Engine.time_scale
var search_cap := 8                # `bot_tick_ok`가 돌려주는 프레임당 틱 상한
var search_over_seen := false      # 한 주행의 게임오버를 한 번만 처리한다
var search_drained := false        # 제출 주행에서 실시간으로 되돌렸는가
var search_t0 := 0.0
var search_deadline := 0.0
var search_best_ticks := 0         # 최선 trace의 사망 틱 (제출 전 대기 계산에 쓴다)
var search_min_age := -1.0         # 제출 시점의 최소 토큰 나이(초). -1이면 자동
var search_rows_log: Array = []    # 회차별 도달 행
var search_v1: Dictionary = {}     # 첫 관문 1차 주행 결과
var srng: RandomNumberGenerator = null   # 탐색용 난수 — 월드 rng와 무관하다

# --- 틱 루프 게이트 ---------------------------------------------------------
#
# `game.gd`의 틱 루프 조건에서 매 틱 불린다(원본 159행을 치환한 것). 두 가지를 한다.
#
# 1. **프레임당 틱 상한**을 정한다. 원본은 8틱이라 12,000틱 접두사 재생에 200초가
#    걸린다 — 40회 반복하면 2시간이 넘어 탐색 자체가 성립하지 않는다. 상한을 올리고
#    `Engine.time_scale`로 dt를 키우면 같은 순서·같은 FIXED_DT로 수십 배 빨리 돌린다.
#    **시뮬레이션 의미는 바뀌지 않는다**(rng 소모 순서가 그대로다).
# 2. **사망 틱을 그 자리에서 잡는다.** 조건의 맨 앞에 있으므로 `state`가 "dead"가 된
#    직후에도 한 번 더 불린다. 여기서 즉시 다음 주행을 띄우면 `on_game_over`의 1초
#    타이머가 깨어날 때 `_over_token`이 이미 달라져 있어 그 뒤의
#    `ui.show_game_over` / `ranking.start_run()`이 실행되지 않는다.
#    → **주행마다 `api/start`가 한 번씩 새는 것을 막는 유일한 지점이다.** 실제 토큰과
#      시드도 그대로 보존된다(`start_run`이 둘을 비운다).
func bot_tick_ok(g, guard: int) -> bool:
	if search_mode == "" or search_mode == "done":
		return guard < SEARCH_TICK_CAP
	if g.state != "play":
		if not search_over_seen:
			search_over_seen = true
			_search_on_over(last_trace, last_ticks, g.rows_crossed(), g.score())
		return false
	if g.replay_mode:
		if search_hand_tick >= 0 and g.tick_count >= search_hand_tick:
			_search_handoff(g)
		elif not search_drained and search_mode == "submit" \
				and g.replay_idx >= g.replay_inputs.size():
			# 제출 주행의 재생이 끝났다. 남은 스크롤 사망과 제출 지연(7~18초)은
			# 사람의 시간이어야 하므로 실시간으로 되돌린다. `_sim_acc`에 쌓인
			# 빚을 버려야 배속이 실제로 떨어진다(틱 순서에는 영향이 없다).
			search_drained = true
			search_cap = SEARCH_TICK_CAP
			Engine.time_scale = 1.0
			g._sim_acc = 0.0
			print("[search] 재생 완료(%d건 소비) — 실시간으로 전환한다" % g.replay_idx)
	return guard < search_cap

func _search_handoff(g) -> void:
	g.replay_mode = false
	g.bot_on = true
	# 같은 접두사에서 **다른 갈래**를 보게 하는 손잡이. `_bot_decide` 내부는 wt/bot
	# 소유이므로 건드리지 않고, 첫 홉 시각만 흔든다(`can_hop`이 bot_hop_t를 본다).
	# 대기는 공짜다 — 한 칸에서 15초를 버틸 수 있으므로 12틱 지연은 손해가 없다.
	g.bot_hop_t = g.tick_count + srng.randi_range(0, 12)
	search_hand_tick = -1
	search_cap = SEARCH_CAP_LIVE

# --- 시작 -------------------------------------------------------------------

func _search_begin() -> void:
	srng = RandomNumberGenerator.new()
	srng.randomize()
	var ch = _bot_qs("bchar")
	search_char = str(ch) if ch != null and str(ch) != "" else "peccy"
	var nm = _bot_qs("bn")
	search_name = str(nm) if nm != null else ""
	var t = _bot_qs("bt")
	if t != null and str(t).is_valid_int():
		search_target = int(str(t))
	var dp = _bot_qs("sdrop")
	if dp != null and str(dp).is_valid_int():
		search_drop = maxi(int(str(dp)), 1)
	var sp = _bot_qs("sspd")
	if sp != null and str(sp).is_valid_float():
		search_speed = maxf(float(str(sp)), 1.0)
	var ttl = _bot_qs("sttl")
	var ttl_s := 1200.0
	if ttl != null and str(ttl).is_valid_float():
		ttl_s = float(str(ttl))
	var mn = _bot_qs("smin")
	if mn != null and str(mn).is_valid_float():
		search_min_age = float(str(mn))

	# 시드는 세 가지 출처가 있다. 어느 쪽이든 **탐색과 제출이 같은 시드**여야 한다.
	var tk = _bot_qs("stok")
	var sd = _bot_qs("sseed")
	if tk != null and str(tk) != "" and sd != null and str(sd).is_valid_int():
		search_token = str(tk)
		search_seed = int(str(sd))
		print("[search] 주입된 토큰/시드 seed=%d token=%s" % [search_seed,
				search_token.substr(0, 12)])
	else:
		var bs = _bot_qs("bseed")
		if bs != null and str(bs).is_valid_int():
			search_seed = int(str(bs))
			search_token = ""
			print("[search] 연습 시드 seed=%d (제출하지 않는다)" % search_seed)
		else:
			await _bot_wait_token()
			search_token = ranking.token
			search_seed = ranking.run_seed
			print("[search] 발급 토큰 seed=%d token=%s" % [search_seed,
					search_token.substr(0, 12)])
	if search_seed <= 0:
		print("[search] 시드를 얻지 못했다 — 중단한다")
		return

	# 고속 주행에서 소리는 의미가 없고 비용만 든다. 제출 주행에서 되돌린다.
	sfx.set_muted(true)
	search_t0 = Time.get_unix_time_from_system()
	search_deadline = search_t0 + ttl_s
	Engine.time_scale = search_speed
	if _bot_flag("sv"):
		search_mode = "verify"
		search_phase = "v1"
		print("[gate] 재생 동일성 검증 시작 seed=%d 배속=%.0f" % [search_seed, search_speed])
	else:
		search_mode = "search"
		print("[search] 탐색 시작 target=%d seed=%d 배속=%.0f 마감=%.0fs" % [
				search_target, search_seed, search_speed, ttl_s])
	_search_launch([], -1)

# --- 한 주행 띄우기 ---------------------------------------------------------
#
# `start_game(char, forced_seed)`는 `claim_run(forced_seed)`를 통해 active_token을
# "TEST"로 둔다 → `Ranking.submit`이 "offline"으로 즉시 빠지므로 **탐색 중 실수로
# 제출될 수 없다.** `ranking.token`(실제 토큰)은 건드리지 않는다.
func _search_launch(base: Array, hand: int) -> void:
	search_base = base
	search_base_rows = _search_rows_of(base)
	search_hand_tick = hand
	search_over_seen = false
	search_iter += 1
	start_game(search_char, search_seed)
	game.bot_target = search_target
	game.bot_submit = false          # 탐색 주행은 절대 제출하지 않는다
	game.bot_name = ""
	if base.is_empty():
		search_cap = SEARCH_CAP_LIVE
		return
	game.replay_mode = true
	game.replay_inputs = base
	game.replay_idx = 0
	# ★ 재생은 기록되지 않는다(`_apply_move`가 replay_mode면 append를 건너뛴다).
	#   접두사를 직접 채워 넣어야 이어 주행한 뒤의 trace가 온전해진다.
	game.input_trace = base.duplicate(true)
	# 재생 중에는 판단을 끈다. `_bot_decide`는 계획 탐색이 비싼데 재생 중에는 아무
	# 효과도 없다(`try_move`가 replay_mode에서 즉시 빠진다). 인계 시점에 다시 켠다.
	game.bot_on = false
	search_cap = SEARCH_CAP_REPLAY

# --- 주행 종료 --------------------------------------------------------------

func _search_on_over(trace: Array, ticks: int, rows: int, score: int) -> void:
	var el := Time.get_unix_time_from_system() - search_t0
	if search_mode == "verify":
		_search_verify_step(trace, ticks, rows, score)
		return
	if search_mode == "submit":
		print("[search] 제출 주행 종료 rows=%d score=%d ticks=%d (탐색: rows=%d ticks=%d)" % [
				rows, score, ticks, search_best_rows, search_best_ticks])
		if rows != search_best_rows or ticks != search_best_ticks:
			print("[search] ★ 재생이 어긋났다 — 제출은 `_bot_after_death`의 목표 가드가 막는다")
		_search_finish()
		return

	search_rows_log.append(rows)
	print("[search] iter=%d 접두사=%d행 -> rows=%d(+%d) score=%d best=%d 경과=%.0fs" % [
			search_iter, search_base_rows, rows, rows - search_base_rows, score,
			maxi(search_best_rows, rows), el])
	if rows > search_best_rows:
		search_best = trace
		search_best_rows = rows
		search_fail = 0
	else:
		search_fail += 1
	if score >= search_target:
		# 목표에 닿은 trace를 그대로 제출한다. 부풀리지 않는다.
		search_best = trace
		search_best_rows = rows
		search_best_ticks = ticks
		await _search_submit()
		return
	if Time.get_unix_time_from_system() > search_deadline:
		print("[search] 마감 초과 — 중단한다. best_rows=%d 회차=%s" % [
				search_best_rows, str(search_rows_log)])
		_search_finish()
		return
	# 되감기 폭을 **훑는다.** 실패가 쌓일수록 깊이 되감다가 다시 얕게 돌아온다.
	# 단조 증가로 두면 한 번 깊어진 뒤 얕은(싸고 값진) 되감기를 다시 못 본다.
	var drop: int = search_drop + srng.randi_range(0, 3) + (search_fail % 12) * 4
	drop = mini(drop, maxi(search_best_rows - 2, 1))
	var base := _search_prefix(search_best, drop)
	_search_launch(base, (int(base[base.size() - 1][0]) + 1) if not base.is_empty() else -1)

# --- 접두사 자르기 ----------------------------------------------------------
#
# 최고 도달 행에서 `drop_rows`행 아래에 **처음 닿는 순간**까지의 trace를 돌려준다.
#
# 처음에는 "뒤에서 전진 홉 drop_rows개를 버린다"로 썼는데 그것은 틀렸다. 봇은 죽기 전에
# 비상 분기로 앞뒤로 진동하는 일이 많고(후퇴도 후보다), 그러면 꼬리의 전진 홉을 버려도
# **최고 도달 행이 그대로 남는다** — 접두사가 62행이고 이어 주행도 62행인 상태로 34회를
# 헛돌았다. 되감기는 "몇 개를 버리는가"가 아니라 "어느 행으로 돌아가는가"여야 한다.
func _search_prefix(trace: Array, drop_rows: int) -> Array:
	if trace.is_empty():
		return []
	if drop_rows <= 0:
		return trace.duplicate(true)
	var want := _search_rows_of(trace) - drop_rows
	if want <= 0:
		return []
	var r := 0
	var cut := trace.size()
	for i in range(trace.size()):
		var c := int(trace[i][1])
		if c == 0:
			r += 1
		elif c == 1:
			r -= 1
		if r > want:
			cut = i          # 이 홉이 want를 넘게 만든다 → 그 앞까지가 접두사다
			break
	if cut <= 0:
		return []
	var out: Array = []
	for j in range(cut):
		out.append([int(trace[j][0]), int(trace[j][1])])
	return out

func _search_rows_of(trace: Array) -> int:
	# trace가 도달하는 행. 전진 +1 / 후진 -1의 최대 누적값이다(bump는 기록되지 않는다).
	var r := 0
	var mx := 0
	for e in trace:
		var c := int(e[1])
		if c == 0:
			r += 1
		elif c == 1:
			r -= 1
		if r > mx:
			mx = r
	return mx

# --- 제출 -------------------------------------------------------------------
#
# 찾은 trace를 **실제 토큰의 시드로** 다시 재생해 클라이언트가 스스로 점수를 계산하게
# 한다. 그래서 제출 경로는 사람이 주행한 것과 구별되지 않는다.
func _search_submit() -> void:
	print("[search] 목표 도달 rows=%d trace=%d건 회차=%s" % [
			search_best_rows, search_best.size(), str(search_rows_log)])
	# 제출은 세 가지가 모두 있을 때만 한다: 실제 토큰(연습 시드면 비어 있다), 닉네임,
	# 그리고 명시적인 `bsub=1`. 보드에 되돌릴 수 없는 항목이 남는 일이므로 우연히
	# 나가는 경로를 만들지 않는다.
	if search_token == "" or search_name == "" or not _bot_flag("bsub"):
		print("[search] 제출하지 않는다 (token=%s name=%s bsub=%s)" % [
				str(search_token != ""), search_name, str(_bot_flag("bsub"))])
		_search_finish()
		return
	# **토큰을 충분히 늙힌 뒤에 제출한다.** 탐색이 수십 배속이라 벽시계 경과가 주행의
	# 시뮬레이션 시간보다 짧다(12,478틱 = 208초를 25초에 돌린다). 서버는 토큰 나이를
	# 재서 `rows <= elapsed * 9.5`를 검사하고, 그 밖의 나이 기반 검사가 더 있어도
	# 이상하지 않다. 토큰의 첫 필드가 발급 epoch이므로 나이를 직접 알 수 있다.
	var need := search_min_age
	if need < 0.0:
		need = maxf(float(search_best_rows) / 9.4, float(search_best_ticks) / 60.0) + 45.0
	var age := _search_token_age()
	if age >= 0.0 and need > 0.0:
		Engine.time_scale = 1.0
		while age < need:
			print("[search] 토큰 나이 %.0fs / 필요 %.0fs — 기다린다" % [age, need])
			await get_tree().create_timer(15.0).timeout
			age = _search_token_age()
		print("[search] 토큰 나이 %.0fs — 제출 주행을 시작한다" % age)
		Engine.time_scale = search_speed
	search_mode = "submit"
	search_drained = false
	# 탐색 중 `ranking.start_run()`이 한 번이라도 새어 나갔다면 token/run_seed가
	# 비어 있다. 제출 직전에 되돌린다 — `claim_run(-1)`이 이 둘을 집어간다.
	ranking.token = search_token
	ranking.run_seed = search_seed
	sfx.set_muted(false)
	search_iter += 1
	search_over_seen = false
	search_hand_tick = -1
	start_game(search_char)            # forced_seed 없음 → 실제 토큰·실제 시드
	game.replay_mode = true
	game.replay_inputs = search_best
	game.replay_idx = 0
	game.input_trace = search_best.duplicate(true)
	game.bot_on = true                 # `_bot_after_death`가 제출한다
	game.bot_submit = true
	game.bot_name = search_name
	game.bot_target = search_target
	search_cap = SEARCH_CAP_REPLAY
	print("[search] 제출 주행 시작 name=%s token=%s seed=%d" % [
			search_name, ranking.active_token.substr(0, 12), ranking.active_seed])

func _search_token_age() -> float:
	# 토큰은 `<epoch>.<hex16>.<hex16>`이다. 첫 필드가 서버가 재는 나이의 기준점이다.
	var parts := search_token.split(".")
	if parts.size() < 2 or not str(parts[0]).is_valid_int():
		return -1.0
	return Time.get_unix_time_from_system() - float(int(str(parts[0])))

func _search_finish() -> void:
	search_mode = "done"
	search_cap = SEARCH_TICK_CAP
	Engine.time_scale = 1.0
	sfx.set_muted(false)

# --- 첫 관문: 재생 동일성 ---------------------------------------------------
#
# 고정 시드로 한 주행의 trace를 얻고, **같은 시드로 그 trace를 재생**해 rows·score·
# 사망 틱이 정확히 같은지 본다. 여기가 어긋난 상태로 탐색을 만들면 전부 헛수고다.
# 이어서 변이 검증: 한 항목의 틱을 1 늘리면 그 입력이 홉 중에 걸려 버려지므로
# rows가 **줄어야** 한다. 안 줄면 재생이 실제로는 적용되지 않고 있다는 뜻이다.
func _search_verify_step(trace: Array, ticks: int, rows: int, score: int) -> void:
	match search_phase:
		"v1":
			search_v1 = { "trace": trace, "ticks": ticks, "rows": rows, "score": score}
			print("[gate] 1차 주행 rows=%d score=%d ticks=%d trace=%d건" % [
					rows, score, ticks, trace.size()])
			if trace.size() < 4:
				print("[gate] trace가 너무 짧다 — 검증 불가")
				_search_finish()
				return
			search_phase = "v2"
			_search_launch(trace.duplicate(true), -1)
		"v2":
			var a: Dictionary = search_v1
			var same: bool = rows == int(a["rows"]) and score == int(a["score"]) \
					and ticks == int(a["ticks"])
			print("[gate] 2차 재생 rows=%d/%d score=%d/%d ticks=%d/%d -> %s" % [
					rows, int(a["rows"]), score, int(a["score"]), ticks, int(a["ticks"]),
					"동일 PASS" if same else "어긋남 FAIL"])
			if not same:
				print("[gate] ★ 재생 규약이 틀렸다. 탐색을 만들지 마라")
				_search_finish()
				return
			search_phase = "v3"
			_search_launch(_search_mutate(a["trace"]), -1)
		"v3":
			var a2: Dictionary = search_v1
			var dropped: bool = rows < int(a2["rows"])
			print("[gate] 변이 재생 rows=%d (원본 %d) -> %s" % [rows, int(a2["rows"]),
					"줄었다 PASS" if dropped else "안 줄었다 FAIL"])
			if not dropped:
				print("[gate] ★ 재생이 실제로 적용되지 않고 있다")
			print("[gate] 끝 — 두 검사 모두 통과해야 탐색을 쓸 수 있다")
			_search_finish()

func _search_mutate(trace: Array) -> Array:
	# 한 항목의 틱을 1 늘린다. 앞 홉과 간격이 정확히 8틱인 항목을 고른다 — 그러면
	# 늘린 틱에 플레이어가 홉 중이라 `_consume_input`이 아예 불리지 않고, `replay_idx`가
	# 그 항목에 걸려 그 뒤 입력이 전부 버려진다(간격 9면 1틱 지연으로 끝난다).
	var out: Array = []
	for e in trace:
		out.append([int(e[0]), int(e[1])])
	var pick := out.size() / 2
	for i in range(1, out.size()):
		if int(out[i][0]) - int(out[i - 1][0]) == 8:
			pick = i
			break
	var gap: int = int(out[pick][0]) - int(out[pick - 1][0]) if pick > 0 else -1
	out[pick][0] = int(out[pick][0]) + 1
	print("[gate] 변이: %d번째 항목 tick %d -> %d (앞 항목과의 간격 %d)" % [
			pick, int(out[pick][0]) - 1, int(out[pick][0]), gap])
	return out
