

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
