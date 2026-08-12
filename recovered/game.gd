extends Node2D
class_name Game


const CELL := 64
const COLS := 9
const CAM_ANCHOR := 600.0
const X_MIN := 34.0
const X_MAX := 606.0

var main: Node
var world: Node2D
var canvas_mod: CanvasModulate
var player: Player
var rows := {}
var rng := RandomNumberGenerator.new()
var gen_next := 0
var start_row := 0
var consec := { "kind": -1, "count": 0, "since_grass": 0}
var cam_row := 0.0
var max_row := 0
var bonus := 0
var state := "play"
var stage_idx := 0
var elapsed := 0.0
var shake_t := 0.0
var snow_layer: CanvasLayer = null
var snow_flakes: Array = []

func setup(p_main: Node, char_name: String) -> void:
	main = p_main
	main.ranking.start_run()
	rng.randomize()

	if OS.has_feature("web"):
		var v = JavaScriptBridge.eval("new URLSearchParams(location.search).get('s')", true)
		if v != null and str(v).is_valid_int():
			start_row = clampi(int(str(v)), 0, 500) * ThemeDefs.ROWS_PER_STAGE
	world = Node2D.new()
	add_child(world)
	canvas_mod = CanvasModulate.new()
	canvas_mod.color = ThemeDefs.theme_for_row(start_row)["ambient"]
	world.add_child(canvas_mod)

	for i in range(start_row - 6, start_row):
		_make_row(i, Row.KIND_GRASS)
	gen_next = start_row
	consec = { "kind": Row.KIND_GRASS, "count": 6, "since_grass": 0}
	while gen_next < start_row + 15:
		_gen_row()
	max_row = start_row
	cam_row = float(start_row)
	stage_idx = ThemeDefs.stage_index(start_row)
	player = Player.new()
	player.setup(char_name)
	player.row = start_row
	player.x = center_x(4)
	player.sync_position()
	world.add_child(player)
	world.position.y = CAM_ANCHOR + cam_row * CELL
	_setup_snow()
	_apply_stage_visuals(stage_idx, true)


func center_x(col: int) -> float:
	return col * CELL + CELL

func col_of(x: float) -> int:
	return clampi(int(round((x - CELL) / CELL)), 0, COLS - 1)

func _make_row(idx: int, kind: int) -> void:
	var r := Row.new()
	world.add_child(r)
	var below = rows.get(idx - 1)
	var below_is_road: bool = below != null and below.kind == Row.KIND_ROAD and kind == Row.KIND_ROAD
	r.build(idx, kind, ThemeDefs.theme_for_row(maxi(idx, 0)), rng, below_is_road)
	rows[idx] = r

func _gen_row() -> void:
	var idx := gen_next
	gen_next += 1
	var theme := ThemeDefs.theme_for_row(idx)
	var kind := Row.KIND_GRASS
	if idx >= start_row + 3 and idx % ThemeDefs.ROWS_PER_STAGE != 0:
		if consec["since_grass"] >= 6:
			kind = Row.KIND_GRASS
		else:
			kind = _pick_kind(theme)

			if kind == Row.KIND_GRASS and consec["kind"] == Row.KIND_GRASS and consec["count"] >= 3:
				kind = _pick_kind(theme)

	if kind == Row.KIND_RAIL and consec["kind"] == Row.KIND_RAIL:
		kind = Row.KIND_GRASS
	if kind == Row.KIND_RIVER and consec["kind"] == Row.KIND_RIVER and consec["count"] >= int(theme["river_run"]):
		kind = Row.KIND_GRASS
	if kind == consec["kind"]:
		consec["count"] += 1
	else:
		consec["kind"] = kind
		consec["count"] = 1
	consec["since_grass"] = 0 if kind == Row.KIND_GRASS else consec["since_grass"] + 1
	_make_row(idx, kind)

func _pick_kind(theme: Dictionary) -> int:
	var w: Dictionary = theme["weights"]
	var total := float(w["grass"]) + float(w["road"]) + float(w["river"]) + float(w["rail"])
	var roll := rng.randf() * total
	if roll < float(w["grass"]):
		return Row.KIND_GRASS
	roll -= float(w["grass"])
	if roll < float(w["road"]):
		return Row.KIND_ROAD
	roll -= float(w["road"])
	if roll < float(w["river"]):
		return Row.KIND_RIVER
	return Row.KIND_RAIL


func _process(dt: float) -> void:
	if state != "play":
		_update_shake(dt)
		return
	elapsed += dt

	var auto := 0.0
	if elapsed > 3.0:
		auto = minf(0.1 + float(max_row) * 0.004, 0.62)
	var target := maxf(cam_row, float(max_row) - 3.0)
	cam_row = maxf(cam_row + auto * dt, lerpf(cam_row, target, minf(1.0, 4.5 * dt)))
	world.position.y = CAM_ANCHOR + cam_row * CELL
	_update_shake(dt)

	while gen_next < int(cam_row) + 14:
		_gen_row()
	for idx in rows.keys():
		if idx < int(cam_row) - 8:
			rows[idx].queue_free()
			rows.erase(idx)

	for idx in range(int(cam_row) - 7, int(cam_row) + 14):
		if rows.has(idx):
			rows[idx].step(dt, self)

	player.follow_ride(dt)
	if player.riding != null and not player.hopping:
		if player.x < X_MIN or player.x > X_MAX:
			kill_player("water")
			return

	if not player.hopping and not player.dead:
		var r = rows.get(player.row)
		if r != null:
			var cause: String = r.hazard_hit(player.x)
			if cause != "":
				kill_player(cause)
				return

	var py := world.position.y + player.position.y
	if py > 1000.0:
		kill_player("scroll")
		return
	_update_snow(dt)
	main.ui.set_score(score(), max_row)

func _update_shake(dt: float) -> void:
	if shake_t > 0.0:
		shake_t -= dt
		world.position.x = rng.randf_range(-1.0, 1.0) * 7.0 * (shake_t / 0.35)
		if shake_t <= 0.0:
			world.position.x = 0.0


func try_move(dir: Vector2i) -> void:
	if state != "play" or player.dead:
		return
	if player.hopping:
		player.input_buffer = dir
		return
	var to_row := player.row + dir.y
	if to_row < 0:
		player.bump(dir)
		return
	while gen_next <= to_row + 1:
		_gen_row()
	var to_x := player.x
	if dir.x != 0:
		if player.riding != null:
			to_x = player.x + dir.x * CELL
			if to_x < X_MIN or to_x > X_MAX:
				player.bump(dir)
				return
		else:
			var to_col := col_of(player.x) + dir.x
			if to_col < 0 or to_col >= COLS:
				player.bump(dir)
				return
			to_x = center_x(to_col)
	var target = rows.get(to_row)
	if target != null and target.kind == Row.KIND_GRASS and target.is_blocked(col_of(to_x)):
		player.bump(dir)
		main.sfx.play("click", -12.0, 0.7)
		return
	main.sfx.play("hop", -6.0, 1.0, 0.06)
	player.hop(dir, to_row, to_x, _resolve_landing)

func _resolve_landing() -> void:
	if state != "play" or player.dead:
		return
	var r = rows.get(player.row)
	if r == null:
		return
	if r.kind == Row.KIND_RIVER:
		var ent = r.log_at(player.x)
		if ent != null:
			player.start_ride(ent)
		else:
			kill_player("water")
			return
	else:
		var col := col_of(player.x)

		if r.kind == Row.KIND_GRASS and r.is_blocked(col):
			for off in[1, -1, 2, -2, 3, -3, 4, -4]:
				var c2: int = col + off
				if c2 >= 0 and c2 < COLS and not r.is_blocked(c2):
					col = c2
					break
		player.x = center_x(col)
		player.sync_position()
		if r.kind == Row.KIND_GRASS:
			r.trigger_ambush(self)

	var cause: String = r.hazard_hit(player.x)
	if cause != "":
		kill_player(cause)
		return
	if player.row > max_row:
		max_row = player.row
		var new_stage := ThemeDefs.stage_index(max_row)
		if new_stage != stage_idx:
			stage_idx = new_stage
			_apply_stage_visuals(stage_idx)

	if player.input_buffer != Vector2i.ZERO:
		var b := player.input_buffer
		player.input_buffer = Vector2i.ZERO
		try_move(b)

func _unhandled_input(event: InputEvent) -> void:
	if state != "play":
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_UP, KEY_W: try_move(Vector2i(0, 1))
			KEY_DOWN, KEY_S: try_move(Vector2i(0, -1))
			KEY_LEFT, KEY_A: try_move(Vector2i(-1, 0))
			KEY_RIGHT, KEY_D: try_move(Vector2i(1, 0))
	elif event is InputEventScreenDrag:

		_swipe_last = event.position
	elif event is InputEventScreenTouch:



		if event.pressed:
			_swipe_active = true
			_swipe_start = event.position
			_swipe_last = event.position
			_swipe_t0 = Time.get_ticks_msec()
		elif _swipe_active:
			_swipe_active = false
			if Time.get_ticks_msec() - _swipe_t0 > 700:
				return
			var end_pos := _swipe_last
			if (event.position - _swipe_start).length() > (end_pos - _swipe_start).length():
				end_pos = event.position
			var d: Vector2 = end_pos - _swipe_start
			if d.length() < 26.0:
				try_move(Vector2i(0, 1))
			elif absf(d.x) > absf(d.y):
				try_move(Vector2i(1 if d.x > 0 else -1, 0))
			else:
				try_move(Vector2i(0, -1 if d.y > 0 else 1))

var _swipe_active := false
var _swipe_start := Vector2.ZERO
var _swipe_last := Vector2.ZERO
var _swipe_t0 := 0


func kill_player(cause: String) -> void:
	if state != "play":
		return
	state = "dead"
	player.die(cause)
	match cause:
		"water":
			main.sfx.play("splash", -2.0)
		"scroll":
			main.sfx.play("over", -4.0)
		"gorani":
			main.sfx.play("crash", -2.0)
			main.sfx.play("gorani", 0.0, 0.8)
			shake_t = 0.35
		"train":
			main.sfx.play("crash", 0.0, 0.8)
			shake_t = 0.35
		_:
			main.sfx.play("crash", -2.0)
			main.sfx.play("horn", -8.0)
			shake_t = 0.35
	main.on_game_over(score(), rows_crossed(), stage_idx, cause)

func score() -> int:
	return max_row - start_row + bonus

func rows_crossed() -> int:
	return max_row - start_row

func on_near_miss(_row_idx: int) -> void:
	bonus += 2
	main.sfx.play("near", -4.0)
	var pos: Vector2 = player.get_global_transform_with_canvas().origin
	main.ui.float_text("아슬아슬! +2", pos + Vector2(0, -40), Color("ffd94a"))

func sfx_near_row(row_idx: int, sname: String) -> void:

	if absf(float(row_idx) - cam_row) < 15.0:
		var vol := -6.0 if sname == "horn" else -3.0
		main.sfx.play(sname, vol, 1.0, 0.05)

func player_alive() -> bool:
	return not player.dead

func player_row() -> int:
	return player.row

func player_x() -> float:
	return player.x


func _apply_stage_visuals(s_idx: int, instant := false) -> void:
	var theme := ThemeDefs.theme_for_row(s_idx * ThemeDefs.ROWS_PER_STAGE)
	if instant:
		canvas_mod.color = theme["ambient"]
	else:
		var tw := create_tween()
		tw.tween_property(canvas_mod, "color", theme["ambient"], 1.2)
		main.sfx.play("stage", -3.0)
		main.ui.show_banner("STAGE %d — %s" % [s_idx + 1, theme["name"]])
	if snow_layer != null:
		snow_layer.visible = theme["snow"]
	if player != null:
		player.set_night(theme["night"])

func _setup_snow() -> void:
	snow_layer = CanvasLayer.new()
	snow_layer.layer = 5
	add_child(snow_layer)
	for i in 42:
		var f := ColorRect.new()
		f.size = Vector2(4, 4) if i % 3 == 0 else Vector2(6, 6)
		f.color = Color(1, 1, 1, 0.85)
		f.position = Vector2(randf() * 640.0, randf() * 960.0)
		f.mouse_filter = Control.MOUSE_FILTER_IGNORE
		snow_layer.add_child(f)
		snow_flakes.append({ "n": f, "v": randf_range(55.0, 120.0), "drift": randf_range(-25.0, 25.0)})
	snow_layer.visible = false

func _update_snow(dt: float) -> void:
	if not snow_layer.visible:
		return
	for s in snow_flakes:
		var n: ColorRect = s["n"]
		n.position.y += s["v"] * dt
		n.position.x += s["drift"] * dt
		if n.position.y > 970.0:
			n.position.y = -10.0
			n.position.x = randf() * 640.0
		elif n.position.x < -10.0:
			n.position.x = 650.0
		elif n.position.x > 650.0:
			n.position.x = -10.0
