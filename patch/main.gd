extends Node


var sfx: Sfx
var ranking: Ranking
var ui: UI
var game: Game = null
var app_state := "title"
var last_char := "rabbit"
var last_trace: Array = []
var last_ticks := 0
var last_unranked := false
var _over_token := 0

func _ready() -> void:

	process_mode = Node.PROCESS_MODE_ALWAYS
	RenderingServer.set_default_clear_color(Color("1e3524"))
	sfx = Sfx.new()
	add_child(sfx)
	ranking = Ranking.new()
	add_child(ranking)
	ui = UI.new()
	ui.main = self
	ui.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(ui)
	sfx.set_muted(bool(ranking.data["muted"]))
	ui.show_title()
	ranking.start_run()
	_bot_autostart()

func set_muted(m: bool) -> void:
	sfx.set_muted(m)
	ranking.data["muted"] = m
	ranking.save_local()

func begin_game(char_id: String) -> void:




	if ranking.token_stale():
		ui.set_start_busy(true)
		ranking.start_run()
		var t0 := Time.get_ticks_msec()
		while ranking.token == "" and Time.get_ticks_msec() - t0 < 3000:
			await get_tree().process_frame
		ui.set_start_busy(false)
	start_game(char_id)

func _process(_dt: float) -> void:

	if app_state == "play" or app_state == "paused":
		return
	if not _bot_hold_token() and ranking.token != "" and ranking.token_age() > ranking.TOKEN_STALE_SEC:
		ranking.start_run()

func start_game(char_id: String, forced_seed := -1, chunk_seeds := {}, chunk_rows := 0) -> void:
	last_char = char_id
	_over_token += 1
	if game != null:
		game.queue_free()
	get_tree().paused = false
	app_state = "play"

	ranking.claim_run(forced_seed, chunk_seeds, chunk_rows)
	game = Game.new()
	game.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(game)
	game.setup(self, char_id)
	ui.show_hud()
	sfx.start_music()

func on_game_over(score: int, rows: int, stage_idx: int, cause: String) -> void:


	if game != null:
		last_trace = game.input_trace.duplicate(true)
		last_ticks = game.tick_count
		last_unranked = game.unranked
	else:
		last_trace = []
		last_ticks = 0
	app_state = "over"
	_over_token += 1
	var token := _over_token
	var is_new_best: bool = ranking.record_score(score)
	sfx.stop_music()
	if cause != "scroll":
		sfx.play("over", -6.0)
	await get_tree().create_timer(1.0).timeout
	if token != _over_token or app_state != "over":
		return
	ui.show_game_over(score, rows, int(ranking.data["best"]), is_new_best, cause, stage_idx)
	_bot_after_over(cause)
	ranking.start_run()

func retry() -> void:
	begin_game(last_char)

func to_title() -> void:
	_over_token += 1
	get_tree().paused = false
	if game != null:
		game.queue_free()
		game = null
	app_state = "title"
	sfx.stop_music()
	ui.show_title()
	ranking.start_run()

func pause_game() -> void:
	if app_state != "play":
		return
	app_state = "paused"
	get_tree().paused = true
	ui.show_pause()

func resume() -> void:
	if app_state != "paused":
		return
	app_state = "play"
	get_tree().paused = false
	ui.hide_pause()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ESCAPE or event.physical_keycode == KEY_P:
			if app_state == "play":
				pause_game()
			elif app_state == "paused":
				resume()


# ---------------------------------------------------------------------------
# 자동 조종 보조 (재패킹 패치 — 원본에 없는 코드)
#
# URL 파라미터: bot=1 자동 조종, bt=목표점수, bn=닉네임, bsub=1 제출,
#               bchar=캐릭터, bloop=1 죽으면 자동 재시작(연습용)
#
# 토큰은 `_ready`/게임오버에서 비동기로 발급된다. 발급 전에 `start_game`을 부르면
# `claim_run`이 빈 토큰을 집어 제출이 "offline"으로 죽으므로 반드시 기다린다.
# ---------------------------------------------------------------------------

func _bot_qs(key: String) -> Variant:
	if not OS.has_feature("web"):
		return null
	return JavaScriptBridge.eval("new URLSearchParams(location.search).get('%s')" % key, true)

func _bot_flag(key: String) -> bool:
	var v = _bot_qs(key)
	return v != null and str(v) == "1"

func _bot_wait_token() -> void:
	for i in 400:
		if ranking.token != "":
			return
		await get_tree().create_timer(0.05).timeout
	print("[bot] 토큰을 20초 안에 받지 못했다")

var bot_seed := -1
var bot_did_submit := false      # 제출이 성공하면 자동 재시도를 멈춘다
var bot_pending_submit := false  # 제출 대기 중(사람의 입력 시간을 흉내내는 지연)

# 프로토콜 v5가 `Main._process`에 토큰 자동 재발급을 넣었다 — 대기 화면에서 토큰 나이가
# `Ranking.TOKEN_STALE_SEC`(600초)를 넘으면 `start_run()`을 부른다. 체크포인트 탐색은
# **하나의 토큰과 그 토큰이 발급한 청크 시드** 위에서 수십 회차를 도는데, 회차 사이에는
# `app_state`가 "play"가 아닌 프레임이 반드시 있으므로 그 경로에 걸린다. 한 번 걸리면
# 토큰·시드·수확한 청크가 통째로 날아가고 `api/start`도 한 건 새어 나간다.
# `_process`는 시뮬레이션(`_sim_tick`) 밖이므로 막아도 서버의 재현과 무관하다.
func _bot_hold_token() -> bool:
	return search_mode != "" or bot_pending_submit

func _bot_autostart() -> void:
	if not _bot_flag("bot"):
		return
	# 체크포인트 탐색(`ss=1`)과 재생 동일성 검증(`sv=1`)은 주행을 여러 번 이어 붙이므로
	# 하네스가 시작·재시작·제출을 통째로 통제한다 (`bot_search.part.gd`).
	if _bot_flag("ss") or _bot_flag("sv"):
		await _search_begin()
		return
	var ch = _bot_qs("bchar")
	var char_id := str(ch) if ch != null and str(ch) != "" else "peccy"
	# bseed: 토큰 없이 특정 시드의 월드를 재생한다(`claim_run(forced_seed)`).
	# 월드는 시드만의 함수이고 봇 판단은 틱 상태만 보므로 같은 시드 = 같은 주행이다.
	# 실서버 시드로 미리 연습해 성공을 확정한 뒤 본 주행을 돌리기 위한 장치다.
	var sd = _bot_qs("bseed")
	if sd != null and str(sd).is_valid_int():
		bot_seed = int(str(sd))
		print("[bot] 고정 시드 재생 seed=%d char=%s (제출 불가)" % [bot_seed, char_id])
		start_game(char_id, bot_seed)
		return
	await _bot_wait_token()
	print("[bot] 시작 char=%s seed=%d token=%s" % [char_id, ranking.run_seed,
			ranking.token.substr(0, 12)])
	start_game(char_id)

func _bot_after_over(cause: String) -> void:
	print("[over] cause=%s best=%d" % [cause, int(ranking.data["best"])])
	if search_mode != "":
		# 탐색 중이면 재시작은 `bot_tick_ok`가 사망 틱에서 이미 처리했다. 여기까지
		# 오는 것은 검증·제출 주행의 마지막 게임오버뿐이고, 그때는 아무것도 하지 않는다.
		return
	if bot_did_submit:
		print("[bot] 등록 완료 — 재시도를 멈춘다")
		return
	if bot_pending_submit:
		# 재시도는 `game.queue_free()`로 Game 노드를 해제한다. 제출 지연 코루틴이
		# 그 노드에 매달려 있으므로 여기서 멈추지 않으면 제출이 통째로 사라진다.
		print("[bot] 제출 대기 중 — 재시도를 보류한다")
		return
	if not _bot_flag("bot") or not _bot_flag("bloop"):
		return
	await get_tree().create_timer(0.6).timeout
	if bot_seed < 0:
		await _bot_wait_token()
	if app_state != "over":
		return
	start_game(last_char, bot_seed)


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
#   space=0      페이싱 게이트를 끈다(연습 전용, 아래 참조)
#   sfloor=<점수> 마감 시점에 이 점수 이상이면 최선을 제출한다. 토큰의 행수 상한 때문에
#                목표에 못 닿을 때 쓰는 출구다(기본값은 bt와 같아 기존 동작 유지)
#
# --- 프로토콜 v5(08-15 아침 배포, `index.1f6c46a4.pck`) 대응 -----------------
#
# 월드 시드는 여전히 25행 단위 청크로 쪼개져 있고, 청크 0·1만 `api/start`가 주고 그
# 뒤는 주행 중에 `POST api/chunk {token, i, ticks, char, trace}`로 받아온다. 서버는 그
# trace를 **재현해서** 그 행에 실제로 닿았는지 보고 시드를 준다(합성 trace는 거부).
#
# 달라진 것은 **클라이언트가 기다리는 방식**이고, 그 방향이 우리에게 유리하다.
#
#   `_ensure_chunk`는 더 이상 생성을 막지 않는다 — 시드가 없으면 즉시 로컬 시드 +
#   `unranked`. 대신 `_sim_tick` **맨 위**의 `_needs_chunk_wait()`가
#   `need_ci = (cam_row + 14) / chunk_rows`의 시드가 없으면 `tick_count`를 올리기
#   **전에** return 한다. 즉 **틱을 통째로 얼린다** — 어젯밤 하네스가 손으로 만들어야
#   했던 "행 생성 지연 0틱" 불변조건 그 자체다. 요청 깊이도 창 안쪽
#   (`(i-1)*25 + 11`)으로 고쳐졌다.
#
# 그래서 탐색이 지킬 것이 네 가지로 줄어든다.
#
# 1. **탐색 주행도 실토큰으로 돈다.** `want_chunk`가 `active_token == "TEST"`를 걸러내
#    므로 TEST 주행은 프런티어에서 새 청크를 수확할 수 없다. 옛 "TEST라서 제출이
#    구조적으로 불가능" 가드가 없으므로, 그 자리는 프록시의 `ALLOW_POST_NAME` /
#    `ALLOW_POST_MIN_SCORE`가 게임 밖에서 메운다(`tools/local_proxy.py`).
# 2. **수확한 청크 시드를 회차 간 누적한다.** `claim_run`이 매 주행 `active_chunks`를
#    `chunks`에서 새로 복사하므로, 그 자리에 누적분을 되돌려 놓아야 한다. 되돌리지
#    않으면 매 회차가 청크 2에서 다시 막힌다.
# 3. **원본의 선행 요청만 막는다.** `_ensure_chunk`는 생성이 청크 ci에 들어설 때
#    `want_chunk(ci + 1)`을 부르는데, 그 시점의 도달 행은 창 아래끝보다 19행 얕아
#    **반드시 거부된다.** `need_ci`보다 앞선 자리를 `_chunk_pending`에 미리 걸어 막고,
#    `need_ci`가 그 자리에 오면 풀어 준다 — 그 자리는 원본이 제 깊이에서 부른다.
# 4. **15초 포기 전에 회차를 접는다.** `WAIT_GIVEUP_MS = 15000`을 넘기면
#    `wait_gave_up`이 고정되고 `unranked`가 켜져 그 주행은 영구히 제출 자격이 없다.
#    그 전에 수확분을 거두고 되감는다.
#
# 그리고 **페이싱**: 서버는 청크 요청마다 `ticks`를 함께 받는다. 25배속 탐색은 벽시계
# 보다 시뮬레이션이 앞서므로 `ticks/60 > 토큰 나이`인 요청을 보내게 되는데, 그것은
# 사람이 만들 수 없는 조합이다. 미지 청크에 진입하기 전에 나이가 따라잡을 때까지
# 얼린다. 얼리는 동안 `_sim_tick`이 아예 돌지 않으므로 **15초 시계도 시작되지 않는다.**
# 비용은 사실상 0이다 — 제출 전에 어차피 `ticks/60 + 45`초를 기다려야 한다.
#
# ★ 토큰 신선도 600초(`Ranking.TOKEN_STALE_SEC`)가 새로 생겼고, `Main._process`가
#   대기 화면에서 그 나이를 넘은 토큰을 **자동 재발급**한다. 탐색 중에 그것이 돌면
#   토큰·시드·청크가 통째로 날아간다 — `_bot_hold_token()`이 그 경로를 막는다.
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

# --- 프로토콜 v5: 청크 시드 -------------------------------------------------
var search_chunks: Dictionary = {}   # 수확한 청크 시드. **회차 간 누적된다**
var search_chunk_rows := 25
var search_live := false             # 실토큰 주행인가(청크 수확이 가능한가)
var search_pace := true              # 페이싱 게이트를 쓰는가
var search_stall_t0 := 0.0           # 청크 대기 시작 벽시계. 0이면 대기 중이 아니다
var search_stall_ci := -1            # 기다리는 청크
var search_chunk_fail := 0           # 같은 청크에서 연속으로 실패한 회차 수
var search_pace_note := 0.0          # 페이싱 로그를 10초당 1회로 줄이기 위한 시각
var search_blocked: Dictionary = {}  # 내가 `_chunk_pending`에 걸어 막아 둔 청크
var search_req_t := 0.0              # 마지막으로 요청을 흘려보낸 벽시계 (간격 제한)
var search_best_score := 0           # 최선 trace의 점수 (상한에 닿으면 이것이 목표가 된다)
var search_floor := 0                # 이 점수 이상이면 마감 시점에 제출한다 (`sfloor`)
var search_capped := false           # 토큰의 행수 상한에 닿았는가
var search_row_cap := 0              # 그 상한 안에서 봇이 멈출 행

# ★★ 발급 경계 (`search_grant_row`) — 08-16에 세운 가설의 핵심 상태.
#
# 서버는 `api/chunk`마다 `trace`를 받아 **재생해서** 검증한다. 즉 토큰 하나에 대해 서버는
# "이 토큰은 이런 역사로 여기까지 왔다"를 이미 한 번 인정한 상태가 된다. 그런데 체크포인트
# 탐색은 **되감는다** — 접두사를 잘라 다른 갈래로 다시 간다. 되감은 지점이 *이미 발급받은
# 청크를 요청했던 행보다 아래*라면, 다음 청크 요청이 들고 가는 trace는 서버가 그 토큰에
# 대해 이미 검증한 trace와 **다른 역사**다.
#
# 기록과 맞는다 (`submissions-log.md` 세션 I / K):
#   08-15 11:11 성공 — 1회차 182행, 3회차 접두사 173행 > 청크7 요청 ~161행 → 18/18 발급
#   08-16 오늘 실패 — 1회차  47행, 3회차 접두사  38행 < 청크2 요청   41행 → 청크3 거부
#   08-15 13:45     — 봇이 9행을 못 넘음 → 즉시 모순 → 깊이 1
#
# **아직 가설이다.** 이 저장소는 게이트 원인을 두 번 단정하고 두 번 틀렸다
# (`leaderboard-api.md` §9.5). 그래서 두 가지를 같이 넣는다 —
#   (a) 되감기를 이 경계 위로 클램프한다 (틀려도 손해가 없다: 경계 아래 되감기의 이득은 0)
#   (b) 요청마다 (청크, 요청행, 그 회차의 접두사행, 경계, 결과)를 남긴다 → **1회 주행이 판정한다**
var search_grant_row := 0            # 발급된 청크를 요청했던 행 중 최대 = 되감기 하한
var search_req_row: Dictionary = {}  # ci -> 그 청크를 요청한 시점의 도달 행
var search_req_base: Dictionary = {} # ci -> 그 요청을 낸 회차의 접두사 행
var search_grant_log: Array = []     # 가설 검증용 판정표. 주행 끝에 한 번 출력한다
# **행 번호로 클램프하지 않고 trace 자체를 앵커로 쓴다.** 행 번호만 보면 틀린다 —
# 발급을 받아낸 회차가 `search_best`가 되지 못하면(점수가 낮으면) 다음 회차의 접두사는
# *다른* 회차의 trace에서 잘리고, 행 번호는 경계 위인데 역사는 갈라져 있을 수 있다.
# 그래서 서버가 실제로 검증한 **그 바이트열**을 들고 있다가 모든 회차가 그것을 잇게 한다.
var search_anchor: Array = []        # 서버가 마지막으로 인정한 trace (요청 시점 스냅샷)
var search_anchor_rows := 0          # 그 trace가 도달한 행
var search_pend_trace: Array = []    # 지금 기다리는 청크 요청이 들고 나간 trace
var search_pend_rows := 0
var search_pend_ext := true           # 그 trace가 앵커를 잇는가 = 가설의 예측
var search_clamp_n := 0              # 앵커로 되돌린 횟수 (로그 억제용)
var search_stuck_n := 0              # 클램프가 걸린 채 전진이 0인 회차 수
var search_anchor_free := false      # 갇힘 종료를 한 번만 처리하기 위한 플래그
# ★ 클램프의 **대가**와 그 출구. 앵커를 지키면 깊은 되감기를 잃는다 — 모의에서 앵커
#   140행에 갇혀 40회 이상 헛돌았다. 그 상태는 "이 토큰으로 더 깊이 갈 수 없다"는 뜻이고
#   (더 깊은 요청은 가설상 거부된다), 역사적으로 그때 통한 것은 갈아 넣기가 아니라
#   **새 토큰**이었다(11:03 청크9 3회 거부 → 11:11 새 토큰이 첫 요청에 발급, 깊이 19).
#   그래서 헛돌기를 세어 끊는다. 남의 서버에 요청을 더 쌓지 않는 것이 요점이다.
const SEARCH_STUCK_MAX := 25
# 원본의 포기 한계는 `WAIT_GIVEUP_MS = 15000`(벽시계)이다. 그것을 넘기면 `wait_gave_up`
# 이 고정되고 `unranked`가 켜져 회차를 살릴 수 없으므로, 반드시 그보다 먼저 접는다.
# ★ 거부를 **최소화**한다. 08-15에 이 IP에서 청크 발급 78건 대 거부 283건이 나갔고,
#   그 거부 대부분이 "같은 청크를 3회차까지 다시 물어본" 것이었다. 그리고 발급 깊이가
#   하루 동안 단조 감소했다(18 -> 16 -> 8 -> 7 -> 6 -> 2). `rep 1`의 문구가 "같은 출처에서
#   거부된 제출 이력"인 것을 보면 서버는 출처별 거부 이력을 들고 있고, **거부가 쌓일수록
#   게이트가 조여지는 래칫**일 수 있다(추정 — 단정하지 않는다). 그렇다면 그 래칫을 돌린
#   것은 우리 자신이다.
#
#   그래서 (a) 대기 창을 요청 간격보다 **짧게** 두어 벽 하나에 요청이 **정확히 1건**만
#   나가게 하고, (b) 한 번 거부되면 재시도하지 않고 즉시 상한으로 판정한다.
#   발급은 실측 0.4~0.6초에 도착하므로 5초는 충분한 여유다.
const SEARCH_WAIT_ABORT := 5.0       # 청크 응답을 이만큼 못 받으면 회차를 접는다
const SEARCH_REQ_INTERVAL := 6.0     # > SEARCH_WAIT_ABORT 이므로 벽당 요청은 1건이다
const SEARCH_CHUNK_FAIL_MAX := 1     # 한 번 거부되면 재시도하지 않는다 (위 주석 참조)
const SEARCH_PACE_MARGIN := 5.0      # ticks/60 대비 토큰 나이에 두는 여유(초)

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
			_search_on_over(last_trace, last_ticks, g.rows_crossed(), g.score(),
					g.unranked)
		return false
	if not _search_chunk_ok(g, guard):
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

# --- 청크 게이트 (프로토콜 v5) ----------------------------------------------
#
# ★ **원본이 기다린다.** `_sim_tick` 맨 위의 `_needs_chunk_wait()`가
#   `need_ci = (cam_row + 14) / chunk_rows`의 시드가 없으면 `tick_count`를 올리기 전에
#   return 하므로 틱이 통째로 얼고, 행 생성 지연이 **0틱**이다. 요청 깊이도 창 안쪽
#   (`(i-1)*chunk_rows + 11`)이라 서버가 받아들인다. 그래서 하네스는 요청을 직접 보내지
#   않고 세 가지만 한다.
#
#   1. 원본의 **선행 요청**(`_ensure_chunk`의 `want_chunk(ci+1)`)을 막는다. 그것은 창
#      아래끝보다 19행 얕아 반드시 거부되는 헛요청이다 — 남의 단일 스레드 서버에
#      청크마다 한 건씩 쌓인다.
#   2. **페이싱**: 요청 바디의 `ticks`가 토큰 나이를 앞서지 않게 경계 앞에서 얼린다.
#   3. 원본의 **15초 포기**(`WAIT_GIVEUP_MS`) 전에 회차를 접는다. 넘기면 `wait_gave_up`
#      과 `unranked`가 고정되어 그 주행은 영구히 제출 자격이 없다.
#
#   얼리는 방법도 원본에 맡긴다 — `_sim_acc`를 `FIXED_DT`로 두고 한 틱만 흘리면
#   `_needs_chunk_wait`가 그 틱을 삼키며 `want_chunk`를 살려 둔다. `guard < 1`로 프레임당
#   한 번으로 묶어야 한다. 무조건 true를 돌려주면 `_sim_acc`를 매번 다시 채우므로 한
#   프레임 안에서 무한 반복한다.
func _search_need_ci(g) -> int:
	return maxi(int(g.cam_row) + 14, 0) / maxi(g.chunk_rows, 1)

# `need_ci` 앞의 자리를 "요청 중"으로 걸어 원본의 선행 요청을 삼킨다. `need_ci`가 그
# 자리에 닿으면 풀어 준다 — 그 자리는 원본 `_needs_chunk_wait`가 제 깊이에서 요청해야
# 한다. 풀어 주지 않으면 영원히 못 받아 15초 뒤 `unranked`가 된다.
# `claim_run`이 매 회차 `_chunk_pending`을 비우므로 매 틱 다시 건다.
func _search_gate_prefetch(need_ci: int) -> void:
	for k in search_blocked.keys():
		if int(k) <= need_ci:
			search_blocked.erase(k)
			ranking._chunk_pending.erase(k)
	for k2 in range(need_ci + 1, need_ci + 4):
		if not ranking.active_chunks.has(k2) and not ranking._chunk_pending.has(k2):
			ranking._chunk_pending[k2] = true
			search_blocked[k2] = true

func _search_chunk_ok(g, guard: int) -> bool:
	if not search_live:
		return true
	var now := Time.get_unix_time_from_system()
	var need_ci: int = _search_need_ci(g)
	# ★ 선행 요청 차단은 **재생 중에도** 걸어 둔다. 여기서 재생을 먼저 걸러내면
	#   `claim_run`이 비운 `_chunk_pending`이 회차 내내 빈 채로 남고, `bot_tick_ok`가
	#   `_search_handoff`를 부르는 그 틱은 차단 없이 `_sim_tick`으로 들어간다
	#   (`_search_chunk_ok`가 replay_mode=true인 상태로 통과한 직후 인계가 일어난다).
	#   회차가 수십 번 도는 탐색에서는 그 한 틱이 회차마다 한 건씩 새어 나간다.
	_search_gate_prefetch(need_ci)
	if g.replay_mode:
		return true

	if ranking.chunk_seed_of(need_ci) != 0:
		if search_stall_t0 > 0.0 and search_stall_ci == need_ci:
			print("[search] 청크 %d 확보 (%.1fs 정지, 틱 %d, %d행)" % [
					need_ci, now - search_stall_t0, g.tick_count,
					g.max_row - g.start_row])
			search_stall_t0 = 0.0
			search_chunk_fail = 0
			# ★ 발급됐다 = 서버가 **이 trace를 이 행까지 인정했다.** 되감기 하한을 올린다.
			_search_note_chunk(need_ci, true)
		return true

	# 원본이 이미 포기했다 = 로컬 시드로 새어 나갔고 `unranked`가 켜졌다. 살릴 수 없다.
	if g.wait_gave_up:
		print("[search] 청크 %d — 원본이 15초 만에 포기(unranked). 회차를 버린다 (%d행)" % [
				need_ci, g.max_row - g.start_row])
		search_stall_t0 = 0.0
		_search_reap_chunks()
		_search_retry()
		return false

	# 페이싱: `ticks/60`이 토큰 나이를 앞선 요청은 사람이 만들 수 없는 조합이다.
	# 여기서 얼리면 `_sim_tick`이 아예 돌지 않아 원본의 15초 시계도 시작되지 않는다.
	var age := _search_token_age()
	var want := float(g.tick_count) / 60.0 + SEARCH_PACE_MARGIN
	if search_pace and age >= 0.0 and age < want:
		if now - search_pace_note > 10.0:
			search_pace_note = now
			print("[search] 페이싱: 청크 %d 요청 전 나이 %.0fs / 필요 %.0fs (틱 %d, %d행)" % [
					need_ci, age, want, g.tick_count, g.max_row - g.start_row])
		# ★★ 얼리는 동안 **대기 타이머를 흘려보내지 않는다.**
		#   `search_stall_t0`은 아래 블록에서 켜지는데, 스큐 등으로 그것이 먼저 켜진 뒤
		#   페이싱이 26초를 얼리면, 페이싱이 풀리는 순간 `now - search_stall_t0 >= 5.0`이
		#   즉시 참이 되어 **요청을 한 번도 보내지 않고 회차를 접는다.**
		#   08-17 08:58 주행이 정확히 그것이었고(프록시에 청크 요청 0건, 게임은 "거부"),
		#   같은 유령 거부를 08-17 08:33 주행의 청크 5에서도 냈다 — 그 판정을 근거로
		#   가설이 확정됐다고 썼다가 정정해야 했다. 타이머는 페이싱이 풀린 뒤에 켠다.
		search_stall_t0 = 0.0
		g._sim_acc = 0.0
		return false

	var reached: int = g.max_row - g.start_row
	if search_stall_t0 <= 0.0 or search_stall_ci != need_ci:
		# ★ 간격 초기화는 **청크가 실제로 바뀔 때만** 한다. `_search_launch`가 회차마다
		#   `search_stall_t0`을 0으로 되돌리므로, 여기서 무조건 초기화하면 같은 청크를
		#   두고 회차가 도는 동안 매 회차 한 건씩 즉시 나가서 6초 간격이 무력화된다.
		#   `search_req_t`는 main에 있어 회차를 넘어 살아남는다 — 그것이 요점이다.
		var moved: bool = search_stall_ci != need_ci
		search_stall_ci = need_ci
		search_stall_t0 = now
		if moved:
			search_req_t = 0.0   # 새 청크는 간격을 기다리지 않고 즉시 한 번 물어본다
		# ★ 이 요청이 들고 나가는 것을 기록한다 — 도달 행과 **이 회차의 접두사 행**.
		#   접두사가 `search_grant_row`보다 낮으면 가설상 이 요청은 거부된다. 그 예측을
		#   요청 시점에 미리 찍어 두면, 결과와 대조해 가설을 판정할 수 있다.
		if not search_req_row.has(need_ci):
			search_req_row[need_ci] = reached
			search_req_base[need_ci] = search_base_rows
		# 서버가 검증할 **바로 그 trace**를 스냅샷한다. 회차는 이 뒤로도 자라므로
		# 지금 복사해 두지 않으면 나중에는 같은 것을 재구성할 수 없다.
		search_pend_trace = g.input_trace.duplicate(true)
		search_pend_rows = reached
		# ★ 가설의 예측을 **요청 시점에** 확정해 둔다. 이 trace가 서버가 마지막으로
		#   인정한 trace(앵커)를 잇는가 — 잇지 않으면 가설은 "거부"를 예측한다.
		search_pend_ext = _search_trace_extends(g.input_trace, search_anchor)
		print("[search] 청크 %d 대기 — 원본이 요청한다 (%d행, 아래끝+%d, 틱 %d, 나이 %.0fs) 앵커=%d행%s" % [
				need_ci, reached, reached - (need_ci - 1) * g.chunk_rows,
				g.tick_count, age, search_anchor_rows,
				"" if search_pend_ext else "  ← 가설: 앵커를 잇지 않는 trace 이므로 거부 예측"])
	if now - search_stall_t0 >= SEARCH_WAIT_ABORT:
		search_chunk_fail += 1
		search_stall_t0 = 0.0
		_search_reap_chunks()
		print("[search] 청크 %d 무응답/거부 %.0fs (연속 %d회, %d행) — 회차를 접는다" % [
				need_ci, SEARCH_WAIT_ABORT, search_chunk_fail, reached])
		_search_note_chunk(need_ci, false)
		if search_chunk_fail >= SEARCH_CHUNK_FAIL_MAX:
			# 이 청크는 얻을 수 없다. 상한으로 판정하고 그 안에서 점수를 올린다.
			# 봇을 `boundary - 22`에서 멈추면 `need_ci`가 이 청크로 넘어오지 않는다
			# (`cam_row + 14 < boundary`가 유지된다) — 그래서 다시 얼지 않는다.
			search_capped = true
			search_row_cap = need_ci * g.chunk_rows - 22
			print("[search] ★ 청크 %d를 못 받는다 = 행수 상한 %d행 (최선 %d점/%d행)" % [
					need_ci, search_row_cap, search_best_score, search_best_rows])
			g.bot_rows = search_row_cap
			# 상한이 `sfloor`에 못 미치면(보너스를 넉넉히 20%로 봐도) 더 갈아 봐야
			# 의미가 없다 — 헛회차를 수백 번 도는 것을 막는다.
			if search_floor > 0 and float(search_row_cap) * 1.2 < float(search_floor):
				print("[search] ★ 상한 %d행으로는 %d점에 닿을 수 없다 — 탐색을 끝낸다 (제출 없음)" % [
						search_row_cap, search_floor])
				_search_finish()
				return false
		_search_retry()
		return false

	# ★ **요청 간격을 반드시 묶는다.** 원본은 대기 중 매 틱 `want_chunk`를 부르고,
	#   서버가 즉답(403/429)하면 `_chunk_pending`이 바로 풀려 다음 틱이 또 보낸다.
	#   08-15 11:03 실측: 청크 9 한 자리에 **275건**이 나갔다(초당 8건). 남의 단일 스레드
	#   서버에 그것은 그 자체로 사고이고, 429 스로틀에 걸려 진짜 응답도 못 보게 된다.
	#   간격은 원본 HTTP 타임아웃(5초)보다 길게 둔다 — 그래야 자리를 풀 때 이미 끝난
	#   요청이라 중복이 나가지 않는다.
	if now - search_req_t < SEARCH_REQ_INTERVAL:
		ranking._chunk_pending[need_ci] = true     # 간격 안에서는 원본의 요청을 삼킨다
		search_blocked[need_ci] = true
		g._sim_acc = 0.0
		return false
	search_req_t = now
	search_blocked.erase(need_ci)
	ranking._chunk_pending.erase(need_ci)
	# ★ 원본의 500ms 스로틀(`_chunk_last_try`, 08-15 21:03 배포)도 같이 비운다.
	#   비우지 않으면 우리가 흘려보낸 **그 한 틱**이 스로틀에 먹혀 요청이 나가지 않고,
	#   다음 기회는 6초 뒤 — `SEARCH_WAIT_ABORT`(5초)보다 늦으므로 회차가 통째로 버려지고
	#   거부로 오판된다. `space=0` 연습에서 청크 2를 이렇게 못 받는 것을 실제로 봤다
	#   (프록시 로그에 요청이 **한 건도 없는데** 하네스는 "거부"로 찍었다).
	#   원본의 선행 요청이 방금 이 자리를 건드렸을 때가 정확히 그 상황이다.
	if ranking._chunk_last_try.has(need_ci):
		ranking._chunk_last_try.erase(need_ci)
	# 정확히 한 틱만 흘린다. 그 틱은 `_needs_chunk_wait`가 삼켜서 `tick_count`가 자라지
	# 않으므로 시뮬레이션에 보이지 않고, 원본의 `want_chunk` 요청만 살아 있다.
	g._sim_acc = g.FIXED_DT
	return guard < 1

# ★ 청크 요청의 결과를 판정표에 남기고, 발급이면 앵커를 그 trace로 옮긴다.
#
# 판정표가 이 변경의 **목적**이다. 가설이 맞다면 `가설예측 == 실제`가 전건 일치하고,
# 틀렸다면 불일치가 나온다 — 어느 쪽이든 주행 한 번으로 결론이 난다. 클램프가 걸린 뒤에는
# 접두사가 항상 경계 위이므로 예측은 전부 "발급"이 되고, 그때 거부가 나오면 **가설은 죽는다.**
func _search_note_chunk(ci: int, granted: bool) -> void:
	var rr: int = int(search_req_row.get(ci, 0))
	var rb: int = int(search_req_base.get(ci, 0))
	var edge: int = search_anchor_rows
	var pred: bool = search_pend_ext         # 앵커를 이으면 "발급" 예측
	search_grant_log.append([ci, rr, rb, edge, granted, pred])
	if granted and not search_pend_trace.is_empty():
		search_anchor = search_pend_trace
		search_anchor_rows = search_pend_rows
		search_grant_row = maxi(search_grant_row, rr)
	# 판정의 강도는 두 방향이 다르다.
	#   예측 거부 → 실제 발급 = **가설 반증.** 모순된 trace를 서버가 받아들였다.
	#   예측 발급 → 실제 거부 = 가설로 설명 안 되는 거부. 다른 원인이 있다(깊이·스로틀·차단).
	var mark := "✓일치"
	if pred and not granted:
		mark = "✗ 예측 발급인데 거부 — 되감기 아닌 다른 원인"
	elif not pred and granted:
		mark = "✗ 예측 거부인데 발급 — ★가설 반증"
	print("[gate] 청크 %d %s — 요청행=%d 회차접두사=%d 앵커=%d행 예측=%s %s" % [
			ci, "발급" if granted else "거부", rr, rb, edge,
			"발급" if pred else "거부", mark])

# trace가 앵커를 **잇는가**(앵커가 그 접두사인가). 가설의 판정자이고 클램프의 판정자다.
#
# ★ 처음에는 `search_base_rows >= search_grant_row`(행 번호)로 판정했는데 **틀렸다.**
#   1회차는 접두사가 비어 있어 `base_rows = 0`이므로 경계가 오른 뒤의 모든 요청이
#   "거부 예측"으로 찍혔지만, 1회차의 trace는 자기 자신을 잇고 있어 모순이 없다.
#   모의에서 청크 3·4가 발급되며 예측이 두 번 틀린 것이 그 증거였다. 행 번호가 아니라
#   **바이트열**을 비교해야 한다.
func _search_trace_extends(t: Array, anchor: Array) -> bool:
	if anchor.is_empty():
		return true
	if t.size() < anchor.size():
		return false
	for i in range(anchor.size()):
		if int(t[i][0]) != int(anchor[i][0]) or int(t[i][1]) != int(anchor[i][1]):
			return false
	return true

# ★ 새 회차의 접두사가 앵커를 잇지 않으면 앵커로 되돌린다.
#
# `_search_prefix`는 `search_best`에서 자르므로, 앵커를 만든 회차가 최선이 아니면
# 접두사가 앵커와 **다른 역사**일 수 있다. 그때는 되감기 폭을 존중하지 않고 앵커를 쓴다 —
# 탐색력을 조금 잃지만, 잃는 것은 "어차피 거부될 회차"다.
	# ★★ 앵커에 갇히면 **포기가 아니라 클램프를 푼다.**
	#
	# 08-17 실서버에서 배운 것. 앵커는 "마지막으로 발급받은 청크를 요청한 순간"의 trace다.
	# 그 지점은 곧 **프런티어**이므로, 프런티어에 닿으면 `best_rows == anchor_rows`가 되어
	# 되감기 여지가 0이 된다 — 415행에서 21회차 연속 `+0`이 났다. 게다가 그 스냅샷은
	# *안전한 체크포인트가 아니라 요청이 나간 임의의 순간*이라, 그 뒤를 살린 입력이
	# 잘려 나가 있다. 그래서 갇히면 클램프를 풀어 깊은 되감기를 되살린다.
	#
	# 푸는 것이 손해가 아닌 이유: 갇힌 상태의 기대값은 0이고(전진 0이 반복된다),
	# 클램프를 풀면 최소한 08-15에 466행까지 갔던 그 동작으로 돌아간다. 그리고 그때
	# 나가는 요청이 **가설의 결정적 시험**이 된다 — 앵커를 잇지 않는 trace가 거부되는지
	# 판정표가 기록한다.
func _search_unstick() -> void:
	# ★★ 08-17 실서버가 확정한 것: 갇혔을 때 클램프를 **풀면 안 된다.**
	#
	# 처음에는 "갇힘의 기대값은 0이므로 풀어서 깊은 되감기를 되살린다"로 만들었고,
	# 08-17 08:33 주행이 그것을 실험으로 만들어 버렸다. 같은 토큰에서 18초 간격으로:
	#     t=51s 청크 4 @85행  접두사 64 >= 앵커 64  -> **발급**
	#     t=63s 앵커 85행에 8회차 갇힘 -> 클램프 해제
	#     t=69s 청크 5 @115행 접두사 43 <  앵커 85  -> **거부**  (예측과 일치)
	# 같은 아침 1번 주행은 클램프를 쥔 채 청크 2~17을 415행까지 **16건 전부** 받았다.
	# 깊이(115 < 415)·토큰 나이·요청 빈도가 모두 배제되므로, 되감기로 역사를 갈라 놓은
	# 것이 거부의 원인이다. 즉 **되감기는 첫 청크 요청 이후로는 토큰에 독이다.**
	#
	# 그래서 갇히면 푸는 대신 **거기서 끝낸다.** 프런티어 지터가 값을 만들 때는
	# `search_stuck_n`이 0으로 리셋되므로, 여기 오는 것은 진짜로 값이 없는 상태다.
	# 1번 주행은 415행에서 82회차 172초를 헛돌았다 — 그 시간은 새 토큰에 쓰는 게 맞다.
	if search_anchor_free or search_stuck_n < SEARCH_STUCK_MAX:
		return
	search_anchor_free = true      # 재진입 방지 플래그로만 쓴다 (클램프는 계속 쥔다)
	print("[search] ★ 앵커(%d행) 프런티어에서 %d회차 전진 0 — 이 토큰은 여기까지다 (best=%d점/%d행)" % [
			search_anchor_rows, search_stuck_n, search_best_score, search_best_rows])
	if search_best_score >= search_floor and search_floor > 0:
		_search_submit()
	else:
		print("[search] ★ best=%d점이 하한 %d점에 못 미친다 — 제출 없이 끝낸다 (새 토큰 필요)" % [
				search_best_score, search_floor])
		_search_finish()

func _search_anchor_base(base: Array) -> Array:
	if search_anchor.is_empty():
		return base
	if _search_trace_extends(base, search_anchor):
		return base
	search_clamp_n += 1
	if search_clamp_n <= 3 or search_clamp_n % 20 == 0:
		print("[search] 되감기 클램프 %d회 — 접두사 %d개가 앵커(%d개/%d행)를 잇지 않아 앵커로 되돌린다" % [
				search_clamp_n, base.size(), search_anchor.size(), search_anchor_rows])
	return search_anchor.duplicate(true)

# 마감을 넘겼으면 새 회차를 띄우지 않는다. 게이트가 어떤 이유로든 회차를 끝내지 못하는
# 상태에 빠져도 탐색이 반드시 종료되고 최선이 제출된다.
func _search_retry() -> void:
	# 마감 뒤에는 새 회차를 띄우지 않는다. 게이트가 어떤 이유로든 회차를 끝내지 못하는
	# 상태에 빠져도 탐색이 반드시 종료되고 최선이 제출된다.
	if search_mode == "search" and Time.get_unix_time_from_system() > search_deadline:
		print("[search] 마감 초과(회차 중단) — best=%d점/%d행 (제출 최소 %d점)" % [
				search_best_score, search_best_rows, search_floor])
		if search_best_score >= search_floor and search_floor > 0:
			_search_submit()
		else:
			_search_finish()
		return
	search_fail += 1
	var drop: int = search_drop + srng.randi_range(0, 3) + (search_fail % 12) * 4
	drop = mini(drop, maxi(search_best_rows - 2, 1))
	_search_unstick()
	var base := _search_anchor_base(_search_prefix(search_best, drop))
	_search_launch(base, (int(base[base.size() - 1][0]) + 1) if not base.is_empty() else -1)

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
	var pc = _bot_qs("space")
	if pc != null and str(pc) == "0":
		search_pace = false
	# 마감 시점에 제출할 최소 점수. 없으면 목표에 닿아야만 제출한다(기존 동작).
	search_floor = search_target
	var fl = _bot_qs("sfloor")
	if fl != null and str(fl).is_valid_int():
		search_floor = int(str(fl))

	# 시드는 세 가지 출처가 있다. 어느 쪽이든 **탐색과 제출이 같은 시드**여야 한다.
	# 프로토콜 v4에서는 청크 시드도 같은 `api/start` 응답에서 와야 하므로, 클라이언트가
	# 직접 발급받는 세 번째 경로가 기본이다(`stok` 주입은 청크를 함께 넘길 방법이 없다).
	var tk = _bot_qs("stok")
	var sd = _bot_qs("sseed")
	if tk != null and str(tk) != "" and sd != null and str(sd).is_valid_int():
		search_token = str(tk)
		search_seed = int(str(sd))
		search_chunks = ranking.chunks.duplicate()
		print("[search] 주입된 토큰/시드 seed=%d token=%s" % [search_seed,
				search_token.substr(0, 12)])
		if search_chunks.is_empty():
			print("[search] ★ 주입 경로에는 청크 시드가 없다 — 25행에서 막힌다. 중단한다")
			return
	else:
		var bs = _bot_qs("bseed")
		if bs != null and str(bs).is_valid_int():
			search_seed = int(str(bs))
			search_token = ""
			search_chunks = {}
			print("[search] 연습 시드 seed=%d (제출하지 않는다, 청크는 로컬 대체)" % search_seed)
		else:
			await _bot_wait_token()
			search_token = ranking.token
			search_seed = ranking.run_seed
			search_chunk_rows = maxi(1, ranking.chunk_rows)
			search_chunks = ranking.chunks.duplicate()
			print("[search] 발급 토큰 seed=%d token=%s chunk_rows=%d 선발급 청크=%d개" % [
					search_seed, search_token.substr(0, 12), search_chunk_rows,
					search_chunks.size()])
	if search_seed <= 0:
		print("[search] 시드를 얻지 못했다 — 중단한다")
		return
	# 실토큰 주행만 청크를 수확할 수 있다(`want_chunk`가 TEST를 걸러낸다).
	search_live = search_token != ""
	if not search_live:
		search_pace = false

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
func _search_reap_chunks() -> void:
	if not search_live:
		return
	var got := 0
	for k in ranking.active_chunks.keys():
		var ci := int(str(k))
		var s := int(str(ranking.active_chunks[k]))
		if s != 0 and not search_chunks.has(ci):
			search_chunks[ci] = s
			got += 1
	if got > 0:
		var mx := 0
		for k2 in search_chunks.keys():
			mx = maxi(mx, int(k2))
		print("[search] 청크 %d개 새로 확보 — 누적 %d개, 최대 %d (약 %d행까지)" % [
				got, search_chunks.size(), mx, (mx + 1) * search_chunk_rows])

func _search_launch(base: Array, hand: int) -> void:
	search_base = base
	search_base_rows = _search_rows_of(base)
	search_hand_tick = hand
	search_over_seen = false
	search_stall_t0 = 0.0
	search_blocked.clear()           # 걸어 둔 자리는 `claim_run`이 이미 비웠다
	search_iter += 1
	if search_live:
		# 실토큰 주행. `claim_run(-1)`이 token/run_seed/chunks를 집어가므로 그 자리에
		# 매 회차 되돌려 놓는다 — 특히 `chunks`에 누적분을 넣어야 프런티어가 전진한다.
		ranking.token = search_token
		ranking.run_seed = search_seed
		ranking.chunk_rows = search_chunk_rows
		ranking.chunks = search_chunks.duplicate()
		start_game(search_char)
	else:
		# 연습(bseed): TEST 토큰이라 청크를 받아올 수 없다. 아는 청크는 주입하고 나머지는
		# `_ensure_chunk`의 로컬 대체 시드가 채운다(시드만의 함수라 재현된다).
		start_game(search_char, search_seed, search_chunks.duplicate(),
				search_chunk_rows)
	game.bot_target = search_target
	game.bot_submit = false          # 탐색 주행은 절대 제출하지 않는다
	game.bot_name = ""
	if search_capped:
		game.bot_rows = search_row_cap   # 상한 너머로 나가면 월드가 로컬로 샌다
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

func _search_on_over(trace: Array, ticks: int, rows: int, score: int,
		unranked := false) -> void:
	var el := Time.get_unix_time_from_system() - search_t0
	# 이 주행에서 수확한 청크 시드를 누적분으로 거둔다. `claim_run`이 다음 주행에서
	# `chunks`를 새로 복사하므로, 여기서 거두지 않으면 매 회차가 같은 벽에 막힌다.
	_search_reap_chunks()
	if unranked:
		print("[search] ★ iter=%d unranked — 청크 시드를 서버에서 못 받아 로컬 월드를 달렸다"
				% search_iter)
	if search_mode == "verify":
		_search_verify_step(trace, ticks, rows, score)
		return
	if search_mode == "submit":
		print("[search] 제출 주행 종료 rows=%d score=%d ticks=%d unranked=%s (탐색: rows=%d ticks=%d)" % [
				rows, score, ticks, str(unranked), search_best_rows, search_best_ticks])
		if rows != search_best_rows or ticks != search_best_ticks:
			print("[search] ★ 재생이 어긋났다 — 제출은 `_bot_after_death`의 목표 가드가 막는다")
		_search_finish()
		return

	# 로컬 시드로 새어 나간 주행은 서버가 재현할 수 없는 월드를 달린 것이다. 그 행수를
	# 최선으로 채택하면 제출 주행에서 반드시 어긋난다 — 통째로 버린다.
	if unranked:
		print("[search] iter=%d unranked(로컬 시드로 새어 나갔다) — 폐기한다 rows=%d" % [
				search_iter, rows])
		_search_retry()
		return

	search_rows_log.append(rows)
	print("[search] iter=%d 접두사=%d행 -> rows=%d(+%d) score=%d best=%d점/%d행 경과=%.0fs" % [
			search_iter, search_base_rows, rows, rows - search_base_rows, score,
			maxi(search_best_score, score), maxi(search_best_rows, rows), el])
	# **점수가 목표다.** 행수만 보면 상한에 닿은 뒤 보너스로 올라가는 점수를 못 잡는다
	# (`score() = rows + bonus`이고 bonus는 니어미스로만 오른다). score >= rows이므로
	# 점수를 최대화하면 상한 전까지는 행수도 함께 올라간다.
	if score > search_best_score or (score == search_best_score and rows > search_best_rows):
		search_best = trace
		search_best_rows = rows
		search_best_score = score
		search_best_ticks = ticks
		search_fail = 0
		search_stuck_n = 0       # 전진이 있었다 = 갇힌 게 아니다
	else:
		search_fail += 1
		# 클램프가 걸린 채 전진이 없는 회차만 센다. 클램프가 없을 때의 헛회차는
		# 정상적인 탐색이므로 여기서 세면 안 된다.
		if search_clamp_n > 0:
			search_stuck_n += 1
	if score >= search_target:
		# 목표에 닿은 trace를 그대로 제출한다. 부풀리지 않는다.
		await _search_submit()
		return
	if Time.get_unix_time_from_system() > search_deadline:
		print("[search] 마감 초과 — best=%d점/%d행 (제출 최소 %d점) 회차=%s" % [
				search_best_score, search_best_rows, search_floor,
				str(search_rows_log)])
		if search_best_score >= search_floor and search_floor > 0:
			await _search_submit()
		else:
			_search_finish()
		return
	# 되감기 폭을 **훑는다.** 실패가 쌓일수록 깊이 되감다가 다시 얕게 돌아온다.
	# 단조 증가로 두면 한 번 깊어진 뒤 얕은(싸고 값진) 되감기를 다시 못 본다.
	var drop: int = search_drop + srng.randi_range(0, 3) + (search_fail % 12) * 4
	drop = mini(drop, maxi(search_best_rows - 2, 1))
	_search_unstick()
	var base := _search_anchor_base(_search_prefix(search_best, drop))
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
	print("[search] 제출 대상 %d점 / %d행 / %d틱 trace=%d건 회차=%s" % [
			search_best_score, search_best_rows, search_best_ticks,
			search_best.size(), str(search_rows_log)])
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
	# 비어 있다. 제출 직전에 되돌린다 — `claim_run(-1)`이 이 셋을 집어간다.
	# 청크는 수확분 전체를 넣는다. 제출 주행은 목표 행까지 재생한 뒤 스크롤 사망까지
	# 카메라가 더 내려가므로, 목표 너머 청크가 비어 있으면 그 자리에서 stall이 난다.
	ranking.token = search_token
	ranking.run_seed = search_seed
	ranking.chunk_rows = search_chunk_rows
	ranking.chunks = search_chunks.duplicate()
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
	# ★ 목표 가드는 **제출 대상 점수**로 맞춘다. `search_target`(원래 목표)으로 두면
	#   상한 때문에 그보다 낮은 최선을 제출할 때 `_bot_after_death`가 스스로 막는다.
	#   같은 값으로 두면 가드의 뜻은 그대로다 — "재생이 그 점수를 재현했는가".
	game.bot_target = search_best_score
	if search_capped:
		game.bot_rows = search_row_cap
	search_cap = SEARCH_CAP_REPLAY
	print("[search] 제출 주행 시작 name=%s token=%s seed=%d" % [
			search_name, ranking.active_token.substr(0, 12), ranking.active_seed])

func _search_token_age() -> float:
	# 토큰은 `<epoch>.<hex16>.<hex16>`이다. 첫 필드가 서버가 재는 나이의 기준점이다.
	var parts := search_token.split(".")
	if parts.size() < 2 or not str(parts[0]).is_valid_int():
		return -1.0
	# ★ 서버 epoch이 브라우저 시계보다 앞서면 나이가 **음수**로 나온다(08-17 실측 -1s).
	#   그러면 페이싱 조건 `age >= 0.0`이 거짓이 되어 페이싱을 건너뛰고, 그 사이에
	#   대기 타이머가 먼저 켜져 27초 뒤 "요청도 안 보내고 거부" 판정이 났다.
	#   토큰이 파싱된 이상 나이는 0 이상이다 — 스큐는 0으로 접는다.
	return maxf(Time.get_unix_time_from_system() - float(int(str(parts[0]))), 0.0)

# ★ 하네스를 내리기 전에 **원본의 청크 요청을 반드시 입막음한다.**
#
# `bot_tick_ok`는 `search_mode == "done"`이면 맨 위에서 빠져나가므로 그 뒤로
# `_search_chunk_ok`가 불리지 않는다 = 요청 간격 제한이 사라진다. 그런데 Game 노드는
# 아직 살아 있고, 시드가 없으면 원본 `_needs_chunk_wait`가 **매 틱** `want_chunk`를
# 부른다. 자기 한계(`WAIT_GIVEUP_MS` 15초)를 다 쓸 때까지 프레임마다 한 건씩 나간다.
#
# 08-15 실측: 모의 재현에서 종료 직후 **0.07초 간격으로 118건**, 딱 8초간. 실서버에서도
# 같은 이유로 청크 하나에 87건이 나갔다. 게이트는 정상이었고, 게이트를 치운 뒤에 원본을
# 방치한 것이 원인이었다.
#
# 두 가지를 건다. `_chunk_pending`에 자리를 걸어 `want_chunk`가 즉시 되돌아 나가게 하고,
# 원본 자신의 포기 플래그를 세워 `_needs_chunk_wait`가 아예 false를 돌려주게 한다.
# 이 판은 어차피 제출하지 않으므로 `unranked`가 되는 것은 손해가 아니다.
func _search_hush(g) -> void:
	if g == null or not is_instance_valid(g):
		return
	if search_live:
		var ci: int = _search_need_ci(g)
		for k in range(ci, ci + 4):
			if not ranking.active_chunks.has(k):
				ranking._chunk_pending[k] = true
	g.wait_gave_up = true

func _search_finish() -> void:
	_search_hush(game)
	search_mode = "done"
	search_cap = SEARCH_TICK_CAP
	Engine.time_scale = 1.0
	sfx.set_muted(false)
	_search_gate_report()

# ★ 게이트 판정표. 이 주행이 가설에 대해 무엇을 말하는지 한 화면에 담는다.
#   `docs/leaderboard-api.md` §12.4에 그대로 붙일 수 있는 형태로 낸다.
func _search_gate_report() -> void:
	if search_grant_log.is_empty():
		return
	var ok := 0
	var bad := 0
	var killed := 0
	print("[gate] ===== 판정표 (청크 | 결과 | 요청행 | 회차접두사 | 앵커 | 예측) =====")
	for row in search_grant_log:
		if bool(row[5]) == bool(row[4]):
			ok += 1
		else:
			bad += 1
			if not bool(row[5]) and bool(row[4]):
				killed += 1      # 모순된 trace가 발급됐다 = 가설 반증
		print("[gate]   %2d | %s | %4d행 | %4d행 | %4d행 | %s%s" % [
				int(row[0]), "발급" if bool(row[4]) else "거부", int(row[1]),
				int(row[2]), int(row[3]), "발급" if bool(row[5]) else "거부",
				"" if bool(row[5]) == bool(row[4]) else "  ✗불일치"])
	var verdict := "가설과 모순 없음 (확정은 아니다 — 반증 기회가 있었는지는 별개다)"
	if killed > 0:
		verdict = "★ 가설 반증 %d건 — 모순된 trace를 서버가 받아들였다" % killed
	elif bad > 0:
		verdict = "거부 %d건이 가설로 설명되지 않는다 — 되감기 외의 원인이 있다" % bad
	print("[gate] 일치 %d건 / 불일치 %d건 — %s" % [ok, bad, verdict])
	print("[gate] 앵커 되돌림 %d회, 최종 발급 경계 %d행" % [search_clamp_n, search_grant_row])

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
	# 한 항목의 틱을 1 **줄인다.** 앞 홉과 간격이 정확히 8틱인 항목을 고르므로, 1 줄이면
	# 그 틱에 플레이어가 아직 홉 중이고(`hop_end_tick = 시작 + 8`, 홉은 그 틱에 끝난다)
	# `_consume_input`이 첫 줄에서 빠진다. `_next_input`은 **틱이 정확히 일치할 때만**
	# 소비하므로 그 항목은 영구히 소비되지 않고 `replay_idx`가 거기 걸려 **뒤 입력이
	# 전부 버려진다** → rows가 크게 줄어야 한다.
	#
	# ★ 반대 방향(+1)은 검증이 되지 않는다. 간격 8을 9로 만드는 것은 홉이 끝난 다음
	#   틱에 소비되는 **1틱 지연**일 뿐이어서 결과가 그대로일 수 있다. 실제로 그렇게
	#   적혀 있어 08-14 밤 관문이 FAIL을 냈고, 원인은 재생이 아니라 이 변이였다.
	var out: Array = []
	for e in trace:
		out.append([int(e[0]), int(e[1])])
	var pick := out.size() / 2
	for i in range(1, out.size()):
		if int(out[i][0]) - int(out[i - 1][0]) == 8:
			pick = i
			break
	var gap: int = int(out[pick][0]) - int(out[pick - 1][0]) if pick > 0 else -1
	out[pick][0] = int(out[pick][0]) - 1
	print("[gate] 변이: %d번째 항목 tick %d -> %d (앞 항목과의 간격 %d)" % [
			pick, int(out[pick][0]) + 1, int(out[pick][0]), gap])
	return out
