extends Node2D
class_name Row
const CELL:= 64
const COLS:= 9
const KIND_GRASS:= 0
const KIND_ROAD:= 1
const KIND_RIVER:= 2
const KIND_RAIL:= 3
const SPAWN_MARGIN:= 280.0
const NEAR_DIST:= 84.0
static var _tex_cache:= {}
static var _glow_mat: CanvasItemMaterial = null
static func tex(n: String) -> Texture2D:
	if not _tex_cache.has(n):
		_tex_cache[n] = load("res://assets/sprites/%s.png" % n)
	return _tex_cache[n]
static func glow_mat() -> CanvasItemMaterial:
	if _glow_mat == null:
		_glow_mat = CanvasItemMaterial.new()
		_glow_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	return _glow_mat
static func make_eye_glow(parent: Node2D, at: Vector2, size:= 0.9) -> Sprite2D:
	var eye:= Sprite2D.new()
	eye.texture = tex("glow")
	eye.position = at
	eye.scale = Vector2(size, size)
	eye.material = glow_mat()
	eye.modulate = Color(1.35, 1.3, 1.05)
	parent.add_child(eye)
	return eye
var idx:= 0
var kind:= KIND_GRASS
var theme_def:= {}
var rng: RandomNumberGenerator
var diff:= 1.0
var blocked:= {}
var entities: Array = []
var spawn_t:= 0.0
var lane_dir:= 1
var lane_speed:= 100.0
var gap_lo:= 1.6
var gap_hi:= 3.2
var rush:= false
var gorani_mult:= 1.75
var pending_gorani:= -1.0
var pending_dir:= 1
var warn_node: Node2D = null
var ambush_armed:= false
var ambush_done:= false
var rail_phase:= "idle"
var rail_t:= 0.0
var train_node: Node2D = null
var train_x:= 0.0
var train_dir:= 1
var lamp_a: ColorRect = null
var lamp_b: ColorRect = null
var train_half:= 410.0
const TRAIN_SPEED:= 950.0
func build(p_idx: int, p_kind: int, p_theme: Dictionary, p_rng: RandomNumberGenerator, below_is_road: bool) -> void:
	idx = p_idx
	kind = p_kind
	theme_def = p_theme
	rng = p_rng
	diff = ThemeDefs.difficulty(maxi(idx, 0))
	position = Vector2(0, - idx * CELL)
	z_index = clampi((2000 - idx) * 2, -4000, 4000)
	match kind:
		KIND_GRASS: _build_grass()
		KIND_ROAD: _build_road(below_is_road)
		KIND_RIVER: _build_river()
		KIND_RAIL: _build_rail()
func _crect(pos: Vector2, size: Vector2, color: Color) -> ColorRect:
	var r:= ColorRect.new()
	r.position = pos
	r.size = size
	r.color = color
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(r)
	return r
func _bg(color: Color) -> void:
	_crect(Vector2(-96, - CELL), Vector2(832, CELL), color)
func _sprite(n: String, x: float, y: float, s:= 4.0) -> Sprite2D:
	var sp:= Sprite2D.new()
	sp.texture = tex(n)
	sp.scale = Vector2(s, s)
	sp.position = Vector2(x, y)
	add_child(sp)
	return sp
func _build_grass() -> void:
	var cols_c: Array = theme_def["grass"]
	_bg(cols_c[idx % 2])
	for i in rng.randi_range(3, 6):
		_crect(Vector2(rng.randf_range(-40, 660), rng.randf_range(-CELL + 6, -10)),
				Vector2(8, 6), Color(cols_c[(idx + 1) % 2]).darkened(0.08))
	var tree_kind: String = theme_def["trees"][0]
	for ex in [-20.0, 660.0]:
		var sp:= _sprite(tree_kind, ex + rng.randf_range(-8, 8), - CELL + 8)
		sp.modulate = theme_def["deco_tint"]
	if idx > 2:
		var n_block:= rng.randi_range(0, 3)
		var cols_pool:= range(COLS)
		cols_pool.shuffle()
		for i in mini(n_block, 4):
			var c: int = cols_pool[i]
			blocked[c] = true
			var deco: String = theme_def["trees"][rng.randi_range(0, theme_def["trees"].size() - 1)]
			var y_off:=(-CELL + 8.0) if deco in ["tree", "pine_snow"] else -18.0
			var sp:= _sprite(deco, c * CELL + CELL, y_off)
			sp.modulate = theme_def["deco_tint"]
	ambush_armed = idx > 6 and rng.randf() < ThemeDefs.ambush_p(idx, float(theme_def["p_ambush"]))
	pending_dir = 1 if rng.randf() < 0.5 else -1
func _build_road(below_is_road: bool) -> void:
	_bg(theme_def["road"])
	if below_is_road:
		var x:= -80.0
		while x < 720.0:
			_crect(Vector2(x, -3), Vector2(26, 4), theme_def["line"])
			x += 64.0
	lane_dir = 1 if rng.randf() < 0.5 else -1
	var sp_range: Array = theme_def["speed"]
	lane_speed = rng.randf_range(sp_range[0], sp_range[1]) * diff
	var gp: Array = theme_def["gap"]
	gap_lo = gp[0] / diff
	gap_hi = gp[1] / diff
	rush = rng.randf() < ThemeDefs.rush_lane_p(idx)
	if rush:
		gorani_mult = 1.3
		lane_speed *= 0.85
		gap_lo *= 0.75
		gap_hi *= 0.75
		for ex in [-20.0, 660.0]:
			_sprite("sign_deer", ex, - CELL + 10)
	spawn_t = rng.randf_range(0.2, gap_hi)
	for i in rng.randi_range(1, 2):
		_spawn_vehicle(rng.randf_range(60, 580))
func _vehicle_name() -> String:
	var cars: Array = theme_def["cars"]
	return cars[rng.randi_range(0, cars.size() - 1)]
func _spawn_vehicle(at_x:= -99999.0, gorani:= false) -> void:
	var holder:= Node2D.new()
	var name_s:= "gorani_0" if gorani else _vehicle_name()
	var sp:= Sprite2D.new()
	sp.texture = tex(name_s)
	sp.scale = Vector2(4, 4)
	sp.flip_h = lane_dir < 0
	holder.add_child(sp)
	var half:= sp.texture.get_width() * 2.0
	var speed:= lane_speed * lane_dir
	if gorani:
		speed *= gorani_mult
		half = 44.0
		if theme_def["night"]:
			Row.make_eye_glow(sp, Vector2(9.0 if lane_dir > 0 else -9.0, -4.5))
	elif theme_def["night"]:
		var cone:= Polygon2D.new()
		var fx:=(half - 4.0) * lane_dir
		cone.polygon = PackedVector2Array([
			Vector2(fx, -6), Vector2(fx + 95 * lane_dir, -24),
			Vector2(fx + 95 * lane_dir, 14), Vector2(fx, 8),
		])
		cone.color = Color(1.0, 0.96, 0.35, 0.3)
		cone.material = glow_mat()
		holder.add_child(cone)
	var x:= at_x
	if x <= -9999.0:
		x = - SPAWN_MARGIN if lane_dir > 0 else 640.0 + SPAWN_MARGIN
	holder.position = Vector2(x, - CELL * 0.5)
	add_child(holder)
	entities.append({
		"node": holder, "x": x, "speed": speed, "half": half,
		"gorani": gorani, "near": false, "log": false, "anim_t": 0.0, "sp": sp,
	})
func _build_river() -> void:
	_bg(theme_def["river"])
	_crect(Vector2(-96, - CELL), Vector2(832, 3), Color(theme_def["river"]).darkened(0.25))
	for i in rng.randi_range(2, 4):
		_crect(Vector2(rng.randf_range(-60, 660), rng.randf_range(-CELL + 10, -12)),
				Vector2(20, 3), Color(theme_def["river"]).lightened(0.18))
	lane_dir = 1 if rng.randf() < 0.5 else -1
	lane_speed = rng.randf_range(42.0, 80.0) * sqrt(diff)
	var log_name:= "floe" if theme_def["snow"] else "log"
	var x:= -160.0
	while x < 800.0:
		var scale_x:= 1.0 if rng.randf() < 0.6 else 0.65
		var holder:= Node2D.new()
		var sp:= Sprite2D.new()
		sp.texture = tex(log_name)
		sp.scale = Vector2(4.0 * scale_x, 4.0)
		holder.add_child(sp)
		holder.position = Vector2(x, - CELL * 0.5)
		add_child(holder)
		var half:= sp.texture.get_width() * 2.0 * scale_x
		entities.append({
			"node": holder, "x": x, "speed": lane_speed * lane_dir, "half": half,
			"gorani": false, "near": false, "log": true, "anim_t": 0.0, "sp": sp,
		})
		x += half * 2.0 + rng.randf_range(115.0, 210.0)
func _build_rail() -> void:
	_bg(theme_def["rail"])
	for ry in [-44.0, -20.0]:
		_crect(Vector2(-96, ry), Vector2(832, 4), Color("5a5248"))
	var x:= -88.0
	while x < 740.0:
		_crect(Vector2(x, -50), Vector2(8, 38), Color("6e5a42"))
		x += 48.0
	lamp_a = _lamp(10.0)
	lamp_b = _lamp(618.0)
	rail_phase = "idle"
	rail_t = rng.randf_range(2.0, 6.5) / diff
	train_dir = 1 if rng.randf() < 0.5 else -1
	train_node = Node2D.new()
	var parts:= ["train_engine", "train_car", "train_car", "train_car"]
	if train_dir < 0:
		parts.reverse()
	var total:= 0.0
	for p in parts:
		total += tex(p).get_width() * 4.0 + 10.0
	total -= 10.0
	train_half = total * 0.5 + 8.0
	var cursor:= - total * 0.5
	for p in parts:
		var w:= tex(p).get_width() * 4.0
		var sp:= Sprite2D.new()
		sp.texture = tex(p)
		sp.scale = Vector2(4, 4)
		sp.flip_h = train_dir < 0
		sp.position = Vector2(cursor + w * 0.5, - CELL * 0.55)
		train_node.add_child(sp)
		cursor += w + 10.0
	train_node.visible = false
	add_child(train_node)
func _lamp(x: float) -> ColorRect:
	_crect(Vector2(x + 4, - CELL + 4), Vector2(4, 18), Color("3a3630"))
	return _crect(Vector2(x, - CELL + 0), Vector2(12, 10), Color("7a2020"))
func step(dt: float, game) -> void:
	match kind:
		KIND_ROAD: _step_road(dt, game)
		KIND_RIVER: _step_entities(dt, game)
		KIND_RAIL: _step_rail(dt, game)
		KIND_GRASS: _step_grass(dt, game)
func _step_grass(dt: float, game) -> void:
	if pending_gorani > 0.0:
		pending_gorani -= dt
		if pending_gorani <= 0.0:
			_clear_warn()
			lane_dir = pending_dir
			lane_speed = 245.0 *(1.0 + diff * 0.18) / 1.75
			_spawn_vehicle(-99999.0, true)
	_step_entities(dt, game)
func _step_road(dt: float, game) -> void:
	spawn_t -= dt
	if spawn_t <= 0.0:
		spawn_t = rng.randf_range(gap_lo, gap_hi)
		var entry:= - SPAWN_MARGIN if lane_dir > 0 else 640.0 + SPAWN_MARGIN
		var clearance:= true
		for e in entities:
			if not e["log"] and absf(e["x"] - entry) < e["half"] + 150.0:
				clearance = false
				break
		if clearance:
			var p_g:= 0.8 if rush else ThemeDefs.gorani_p(idx, float(theme_def["p_gorani"]))
			if pending_gorani <= 0.0 and rng.randf() < p_g:
				_begin_gorani_warn(lane_dir, game)
			else:
				_spawn_vehicle()
				if rng.randf() < 0.04:
					game.sfx_near_row(idx, "horn")
	if pending_gorani > 0.0:
		pending_gorani -= dt
		if pending_gorani <= 0.0:
			_clear_warn()
			_spawn_vehicle(-99999.0, true)
	_step_entities(dt, game)
func _begin_gorani_warn(dir: int, game) -> void:
	pending_gorani = 0.55
	pending_dir = dir
	_make_warn(20.0 if dir > 0 else 620.0)
	game.sfx_near_row(idx, "gorani")
func trigger_ambush(game) -> void:
	if not ambush_armed or ambush_done or pending_gorani > 0.0:
		return
	ambush_done = true
	pending_gorani = 0.45
	_make_warn(20.0 if pending_dir > 0 else 620.0)
	game.sfx_near_row(idx, "gorani")
func _make_warn(x: float) -> void:
	_clear_warn()
	warn_node = _sprite("warn", x, - CELL - 6, 3.0)
func _clear_warn() -> void:
	if warn_node != null and is_instance_valid(warn_node):
		warn_node.queue_free()
	warn_node = null
func _step_entities(dt: float, game) -> void:
	var to_remove:= []
	for e in entities:
		e["x"] += e["speed"] * dt
		if e["log"]:
			if e["speed"] > 0.0 and e["x"] - e["half"] > 800.0:
				e["x"] = -160.0 - e["half"]
			elif e["speed"] < 0.0 and e["x"] + e["half"] < -160.0:
				e["x"] = 800.0 + e["half"]
		else:
			if e["gorani"]:
				e["anim_t"] += dt
				e["sp"].texture = tex("gorani_%d" %(int(e["anim_t"] * 8.0) % 2))
				if game.player_alive() and game.player_row() == idx:
					if absf(e["x"] - game.player_x()) < NEAR_DIST:
						e["near"] = true
			if absf(e["x"] - 320.0) > 640.0 + SPAWN_MARGIN:
				to_remove.append(e)
		e["node"].position.x = e["x"]
	for e in to_remove:
		if e["gorani"] and e["near"] and game.player_alive():
			game.on_near_miss(idx)
		e["node"].queue_free()
		entities.erase(e)
func _step_rail(dt: float, game) -> void:
	rail_t -= dt
	match rail_phase:
		"idle":
			if rail_t <= 0.0:
				rail_phase = "warn"
				rail_t = 1.25
				game.sfx_near_row(idx, "train")
		"warn":
			var blink:= int(rail_t / 0.16) % 2 == 0
			var on:= Color("ff4040")
			var off:= Color("7a2020")
			lamp_a.color = on if blink else off
			lamp_b.color = off if blink else on
			if rail_t <= 0.0:
				rail_phase = "run"
				train_x = -360.0 - train_half if train_dir > 0 else 1000.0 + train_half
				train_node.visible = true
		"run":
			train_x += TRAIN_SPEED * train_dir * dt
			train_node.position.x = train_x
			if absf(train_x - 320.0) > 690.0 + train_half:
				rail_phase = "idle"
				rail_t = rng.randf_range(3.0, 7.5) / diff
				train_node.visible = false
				lamp_a.color = Color("7a2020")
				lamp_b.color = Color("7a2020")
func is_blocked(col: int) -> bool:
	return blocked.has(col)
func hazard_hit(px: float) -> String:
	for e in entities:
		if e["log"]:
			continue
		if absf(e["x"] - px) < e["half"] + 18.0:
			return "gorani" if e["gorani"] else "car"
	if kind == KIND_RAIL and rail_phase == "run":
		if absf(px - train_x) < train_half + 16.0:
			return "train"
	return ""
func log_at(px: float) -> Variant:
	for e in entities:
		if e["log"] and absf(e["x"] - px) <= e["half"] + 4.0:
			return e
	return null
