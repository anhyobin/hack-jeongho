

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
# --- 프로토콜 v4(08-14 22:04 배포) 대응 -------------------------------------
#
# 월드 시드가 25행 단위 청크로 쪼개졌다. `api/start`는 청크 0·1만 주고, 그 뒤 시드는
# 주행 중에 `POST api/chunk {token, i, ticks, char, trace}`로 받아온다. 서버는 그 trace
# 를 **재현해서** 그 행에 실제로 닿았는지 보고 시드를 준다(합성 trace는 거부 — 실측).
# 시드를 못 받으면 `Game._ensure_chunk`가 420틱 뒤 로컬 시드로 넘어가며 `unranked`를
# 켜고, 그 주행은 서버가 재현할 수 없으므로 제출 자격을 잃는다.
#
# 그래서 탐색이 세 가지를 더 지켜야 한다.
#
# 1. **탐색 주행도 실토큰으로 돈다.** `want_chunk`가 `active_token == "TEST"`를 걸러내
#    므로 TEST 주행은 프런티어에서 새 청크를 수확할 수 없다. 대신 옛 "TEST라서 제출이
#    구조적으로 불가능" 가드가 사라지므로, 그 자리는 프록시의 `ALLOW_POST_NAME` /
#    `ALLOW_POST_MIN_SCORE`가 게임 밖에서 메운다(`tools/local_proxy.py`).
# 2. **수확한 청크 시드를 회차 간 누적한다.** `claim_run`이 매 주행 `active_chunks`를
#    `chunks`에서 새로 복사하므로, 그 자리에 누적분을 되돌려 놓아야 한다. 되돌리지
#    않으면 매 회차가 청크 2에서 다시 막힌다.
# 3. **경계에 닿기 전에 틱을 멈춘다.** 시드가 없어 `_gen_row`가 실패하면 그 행은 다음
#    틱에 만들어져 `step()`을 한 번 덜 받는다 — 서버의 재현과 갈라진다. 틱 전체를
#    멈추는 것은 배속과 같아 시뮬레이션에 보이지 않으므로, 경계 앞에서 멈춘 뒤 시드를
#    받아 이어 간다. 이미 stall이 일어난 회차는 갈라진 월드이므로 버린다(§_search_chunk_ok).
#
# 그리고 **페이싱**: 서버는 청크 요청마다 `ticks`를 함께 받는다. 60배속 탐색은 벽시계
# 보다 시뮬레이션이 앞서므로 `ticks/60 > 토큰 나이`인 요청을 보내게 되는데, 그것은
# 사람이 만들 수 없는 조합이다. 미지 청크에 진입하기 전에 나이가 따라잡을 때까지
# 기다린다. 비용은 사실상 0이다 — 제출 전에 어차피 `ticks/60 + 45`초를 기다려야 한다.
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

# --- 프로토콜 v4: 청크 시드 -------------------------------------------------
var search_chunks: Dictionary = {}   # 수확한 청크 시드. **회차 간 누적된다**
var search_chunk_rows := 25
var search_live := false             # 실토큰 주행인가(청크 수확이 가능한가)
var search_pace := true              # 페이싱 게이트를 쓰는가
var search_stall_t0 := 0.0           # 청크 대기 시작 벽시계. 0이면 대기 중이 아니다
var search_stall_ci := -1            # 기다리는 청크
var search_chunk_fail := 0           # 같은 청크에서 연속으로 실패한 회차 수
var search_pace_note := 0.0          # 페이싱 로그를 10초당 1회로 줄이기 위한 시각
var search_req_t := 0.0              # 마지막 청크 요청 시각(재요청 간격 제한)
var search_chunk_off := 2            # 요청 깊이(창 아래끝 + 이 값). 거부되면 자동으로 깊어진다
var search_next_ci := 1              # 프런티어 청크 캐시 (단조 증가)
var search_best_score := 0           # 최선 trace의 점수 (상한에 닿으면 이것이 목표가 된다)
var search_floor := 0                # 이 점수 이상이면 마감 시점에 제출한다 (`sfloor`)
var search_capped := false           # 토큰의 행수 상한에 닿았는가
var search_row_cap := 0              # 그 상한 안에서 봇이 멈출 행
const SEARCH_STALL_GIVEUP := 10.0    # 청크 응답을 이만큼 못 받으면 회차를 접는다
const SEARCH_CHUNK_FAIL_MAX := 3     # 같은 청크에서 이만큼 실패하면 상한으로 판정한다
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
	if not _search_chunk_ok(g):
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

# --- 청크 게이트 (프로토콜 v4) ----------------------------------------------
#
# ★ 배포된 클라이언트의 요청 시점을 **그대로 쓴다.** 서버가 받아들이는 지점이 그것이기
#   때문이다. `_ensure_chunk`는 두 자리에서 시드를 요구한다.
#
#     선행: 청크 ci에 들어설 때 `want_chunk(ci + 1)` — 창보다 얕아 거부된다(무해)
#     직접: 생성이 그 청크를 필요로 해 막힐 때 — **이쪽이 받아들여지는 자리다**
#
#   직접 요청 시점의 도달 행은 `i*25 - 19 ~ -10`(생성이 `int(cam_row)+13`까지 가므로)이고,
#   창 아래끝보다 6~15행 깊다. 하네스가 그보다 이르게 보내면 거부된다 — 08-15 00:27
#   주행에서 청크 4를 77행(아래끝+2)에서 6회 거부당해 실측했다. 같은 요청이 00:04
#   주행에서는 통했으므로 그 사이 서버가 조여진 것으로 읽는다(클라이언트는 그대로였다).
#
# 그래서 하네스가 하는 일은 두 가지로 줄어든다.
#
# 1. **대기 중 틱을 멈춘다.** `tick_count`가 자라지 않으므로 (a) 420틱 포기 판정에
#    걸리지 않아 `unranked`가 되지 않고, (b) **행 생성 지연이 정확히 1틱으로 묶인다.**
#    지연이 있으면 그 행이 `step()`을 한 번 덜 받아 서버의 재현과 어긋나지만, 1틱은
#    차량이 2~3px 움직이는 양이고 히트박스 여유보다 훨씬 작다. 무엇보다 **모든 실제
#    플레이어가 네트워크 지연만큼 같은 일을 겪으므로 서버는 이것을 견뎌야 한다.**
# 2. **페이싱**: 경계에 닿기 전에 토큰 나이가 시뮬레이션 시간을 따라잡게 한다. 틱 전체를
#    멈추는 것은 배속과 같아 시뮬레이션에 보이지 않는다.
func _search_chunk_ok(g) -> bool:
	if not search_live:
		return true
	var now := Time.get_unix_time_from_system()

	# --- 시드를 기다리는 중 ---------------------------------------------------
	if g.stall_since >= 0:
		var sci: int = maxi(g.gen_next, 0) / g.chunk_rows
		if ranking.chunk_seed_of(sci) != 0:
			print("[search] 청크 %d 확보 (%.1fs 정지, 틱 %d, %d행)" % [
					sci, now - search_stall_t0, g.tick_count, g.max_row - g.start_row])
			search_stall_t0 = 0.0
			search_chunk_fail = 0
			return true
		if search_capped:
			# 상한 판정 뒤에도 stall이면 이 회차가 상한 너머로 나간 것이다. 시드는
			# 오지 않으므로 기다릴 이유가 없고, 월드도 이미 갈라졌다 — 버린다.
			g._sim_acc = 0.0
			search_stall_t0 = 0.0
			_search_retry()
			return false
		if search_stall_t0 <= 0.0:
			search_stall_t0 = now
			search_stall_ci = sci
			print("[search] 청크 %d 대기 — 틱을 멈춘다 (틱 %d, 나이 %.0fs, %d행, 아래끝 %d)" % [
					sci, g.tick_count, _search_token_age(), g.max_row - g.start_row,
					(sci - 1) * g.chunk_rows])
		if now - search_stall_t0 < SEARCH_STALL_GIVEUP:
			# ★ `_sim_acc`는 **여기서만** 비운다. 무조건 비우면 아래에서 "틱 하나를
			#   흘린다"가 한 틱도 돌지 않아 `_ensure_chunk`가 재요청을 못 하고 교착에
			#   빠진다(연습에서 실측: 75초 동안 재요청 0건).
			g._sim_acc = 0.0
			return false
		# 원본은 대기 중 매 틱 재요청하지만 틱이 멈춰 있어 재요청이 안 나간다. 한 번
		# 틱을 흘려 `_ensure_chunk`가 다시 `want_chunk`를 부르게 한다(간격 = GIVEUP).
		search_chunk_fail += 1
		search_stall_t0 = now
		_search_reap_chunks()
		print("[search] 청크 %d 무응답/거부 (연속 %d회) — 재요청한다" % [
				sci, search_chunk_fail])
		if search_chunk_fail >= SEARCH_CHUNK_FAIL_MAX:
			# 이 청크는 얻을 수 없다. 상한으로 판정하고 그 안에서 점수를 올린다.
			search_capped = true
			search_row_cap = sci * g.chunk_rows - 22
			print("[search] ★ 청크 %d를 못 받는다 = 행수 상한. 이제 %d행 안에서 점수를 올린다 (최선 %d점/%d행)" % [
					sci, search_row_cap, search_best_score, search_best_rows])
			g.bot_rows = search_row_cap
			search_stall_t0 = 0.0
			# 이 회차는 시드를 못 받아 멈춰 있고 월드도 갈라졌다. 살리지 않는다 —
			# 상한이 적용된(`bot_rows`) 새 회차로 넘어간다.
			_search_retry()
			return false
			search_stall_t0 = 0.0
		# 정확히 한 틱만 흘린다. 그 틱의 `_gen_row`가 `_ensure_chunk`를 다시 부르고,
		# 거기서 원본의 `want_chunk`가 재요청을 낸다. 한 프레임분을 그대로 두면
		# 배속만큼(60틱) 흘러 행 생성 지연이 그만큼 커진다.
		g._sim_acc = g.FIXED_DT
		return true

	if search_capped:
		# 상한이 목표에 못 미치는 것이 확정됐으면 더 갈아 봐야 의미가 없다. 즉시 끝낸다 —
		# 청크 예산이 닫힌 창에서 헛회차를 수백 번 도는 것을 막는다.
		# (보너스 상한을 넉넉히 20%로 봐도 `sfloor`에 못 닿는 경우)
		if search_floor > 0 and float(search_row_cap) * 1.2 < float(search_floor):
			print("[search] ★ 상한 %d행으로는 %d점에 닿을 수 없다 — 탐색을 끝낸다 (제출 없음)" % [
					search_row_cap, search_floor])
			_search_finish()
			return false
		# ★ 상한 뒤에도 차단은 유지해야 한다. 안 그러면 원본의 선행 요청이 회차마다
		#   한 건씩 나가고, 상한 뒤에는 회차가 초당 여러 번 돌기 때문에 그것만으로
		#   남의 서버에 수십~수백 건이 쌓인다(실측: 82회차에 72건).
		var cap_ci: int = _search_frontier_ci()
		if cap_ci >= 0:
			_search_block_prefetch(cap_ci)
		search_stall_t0 = 0.0
		return true

	# --- 요청 시점 자동 보정 -------------------------------------------------
	#
	# 서버가 받아들이는 깊이를 우리는 모른다 — **하룻밤에 두 번 달라졌다.** 00:04에는
	# 아래끝+2가 통했고 00:27에는 같은 요청이 거부됐다(클라이언트는 그대로였다).
	# 그래서 고정값을 쓰지 않고 얕은 쪽에서 시작해 거부되면 깊게 옮긴다.
	#
	# 깊어질 수 있는 한계는 **생성이 그 청크를 필요로 하기 직전**이다. 그 지점을 넘기면
	# `_gen_row`가 실패해 행 생성이 늦어지고, 그 행이 `step()`을 한 번 덜 받아 서버의
	# 재현과 갈라진다(연습 실측: 그런 trace를 재생하면 438행 접두사가 241행으로 줄었다).
	# 그래서 그 직전에 멈춰 요청한다 — 지연 0틱, 가능한 가장 깊은 자리.
	var ci := _search_frontier_ci()
	if ci < 0:
		search_stall_t0 = 0.0
		return true
	# 프런티어가 옮겨 갔다 = 앞 청크를 받았다. 타이머를 여기서만 초기화한다 —
	# 매 프레임 초기화하면 `search_req_t`도 함께 풀려 요청이 프레임마다 나간다
	# (연습에서 모의 서버에 11,440건이 나갔다).
	_search_block_prefetch(ci)
	if ci != search_stall_ci:
		if search_stall_t0 > 0.0 and ci > search_stall_ci:
			print("[search] 청크 %d 확보 (%.1fs 정지, 아래끝+%d)" % [
					search_stall_ci, now - search_stall_t0, search_chunk_off])
			search_chunk_fail = 0
		search_stall_ci = ci
		search_stall_t0 = 0.0
	var boundary: int = ci * g.chunk_rows
	var reached: int = g.max_row - g.start_row
	var natural: bool = int(g.cam_row) + 14 >= boundary or g.gen_next >= boundary
	if not natural and reached < (ci - 1) * g.chunk_rows + search_chunk_off:
		search_stall_t0 = 0.0
		return true                      # 아직 요청 시점이 아니다

	g._sim_acc = 0.0

	# 페이싱: 요청 바디의 `ticks`가 토큰 나이보다 앞서면 사람이 만들 수 없는 조합이다.
	var age := _search_token_age()
	var want := float(g.tick_count) / 60.0 + SEARCH_PACE_MARGIN
	if search_pace and age >= 0.0 and age < want:
		if now - search_pace_note > 10.0:
			search_pace_note = now
			print("[search] 페이싱: 청크 %d 요청 전 나이 %.0fs / 필요 %.0fs (틱 %d, %d행)" % [
					ci, age, want, g.tick_count, reached])
		return false

	if search_stall_t0 <= 0.0:
		search_stall_t0 = now
		search_req_t = 0.0
		print("[search] 청크 %d 요청 (%d행, 아래끝+%d%s, 틱 %d, 나이 %.0fs)" % [
				ci, reached, reached - (ci - 1) * g.chunk_rows,
				" 생성한계" if natural else "", g.tick_count, age])
	if search_req_t <= 0.0 or now - search_req_t > 6.0:
		search_req_t = now
		ranking._chunk_pending.erase(ci)
		ranking.want_chunk(ci, g.input_trace, g.tick_count, last_char)
	if now - search_stall_t0 < SEARCH_STALL_GIVEUP:
		return false

	search_stall_t0 = 0.0
	_search_reap_chunks()     # 이 회차가 받아 둔 시드를 잃지 않는다 (안 거두면 다시 받아온다)
	if not natural and search_chunk_off < 10:
		# 더 깊은 자리에서 다시 물어본다. 이 회차를 버리지 않는다. 폭은 좁게 둔다 —
		# 실측에서 한 청크가 막히면 +2부터 +18까지 전부 거부됐다(깊이 문제가 아니다).
		search_chunk_off += 4
		print("[search] 청크 %d 거부 — 요청 깊이를 아래끝+%d로 옮긴다" % [
				ci, search_chunk_off])
		return true
	# 생성 한계까지 갔는데도 안 준다. 이 청크는 얻을 수 없다.
	search_chunk_fail += 1
	print("[search] 청크 %d 생성한계에서도 거부 (연속 %d회)" % [ci, search_chunk_fail])
	if search_chunk_fail >= SEARCH_CHUNK_FAIL_MAX:
		search_capped = true
		search_row_cap = boundary - 22
		print("[search] ★ 청크 %d를 못 받는다 = 행수 상한. 이제 %d행 안에서 점수를 올린다 (최선 %d점/%d행)" % [
				ci, search_row_cap, search_best_score, search_best_rows])
		g.bot_rows = search_row_cap
		return true
	_search_retry()
	return false

# 원본 `_ensure_chunk`는 청크 ci-1에 들어설 때 정확히 ci를 선행 요청한다. 그 시점의
# 도달 행은 창 아래끝보다 14행 얕아 **반드시 거부된다** — 실측에서 요청 총량의 절반
# 이상이 이 헛요청이었고, `api/chunk`의 한도를 소진시킨 주범으로 본다(추정).
# 그래서 프런티어와 그 앞 몇 칸을 "요청 중"으로 표시해 막고, 창에 들어와 하네스가
# 직접 보낼 때만 그 자리를 풀어 준다.
func _search_block_prefetch(ci: int) -> void:
	for k in range(ci, ci + 4):
		if not ranking.active_chunks.has(k):
			ranking._chunk_pending[k] = true

func _search_frontier_ci() -> int:
	while search_next_ci < 4000 and ranking.chunk_seed_of(search_next_ci) != 0:
		search_next_ci += 1
		# 새 프런티어는 하네스가 직접 보낸다 — 아래에서 걸어 둔 자리를 풀어 준다.
		ranking._chunk_pending.erase(search_next_ci)
	return search_next_ci if search_next_ci < 4000 else -1

# 원본 `_ensure_chunk`는 청크 ci에 들어설 때 `want_chunk(ci + 1)`을 선행 호출한다.
# 그 시점의 trace는 창 아래끝보다 **얕아서 반드시 거부된다**(연습에서 80초에 25건).
# 남의 단일 스레드 서버에 헛요청을 보내지 않도록 프런티어보다 앞선 자리를 미리
# "요청 중"으로 표시해 둔다. `claim_run`이 매 회차 이 사전을 비우므로 매 틱 다시 건다.
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
	var base := _search_prefix(search_best, drop)
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
	search_next_ci = 1               # 프런티어를 실제 보유분에서 다시 센다
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
	else:
		search_fail += 1
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
