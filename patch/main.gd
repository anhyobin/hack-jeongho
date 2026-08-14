extends Node


var sfx: Sfx
var ranking: Ranking
var ui: UI
var game: Game = null
var app_state := "title"
var last_char := "rabbit"
var last_trace: Array = []
var last_ticks := 0
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

func start_game(char_id: String, forced_seed := -1) -> void:
	last_char = char_id
	_over_token += 1
	if game != null:
		game.queue_free()
	get_tree().paused = false
	app_state = "play"

	ranking.claim_run(forced_seed)
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
	start_game(last_char)

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

func _bot_autostart() -> void:
	if not _bot_flag("bot"):
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
