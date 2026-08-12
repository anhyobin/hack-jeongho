extends Node2D
class_name Player


const CELL := 64
const HOP_T := 0.13

var char_name := "rabbit"
var row := 0
var x := 320.0
var dead := false
var hopping := false
var riding = null
var input_buffer := Vector2i.ZERO

var sprite: Sprite2D
var shadow: ColorRect
var _hop_tw: Tween = null
var _fx_tw: Tween = null
var _eye_glows: Array = []

func set_night(on: bool) -> void:
	for g in _eye_glows:
		if is_instance_valid(g):
			g.visible = on

func setup(p_char: String) -> void:
	char_name = p_char
	shadow = ColorRect.new()
	shadow.size = Vector2(40, 12)
	shadow.position = Vector2(-20, 14)
	shadow.color = Color(0, 0, 0, 0.22)
	shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shadow)
	sprite = Sprite2D.new()
	sprite.texture = Row.tex(char_name + "_0")
	sprite.scale = Vector2(4, 4)
	add_child(sprite)

	if char_name == "gorani_p":

		_eye_glows.append(Row.make_eye_glow(sprite, Vector2(-2.5, -4.5), 0.7))
		_eye_glows.append(Row.make_eye_glow(sprite, Vector2(2.5, -4.5), 0.7))
	elif char_name == "peccy":

		_eye_glows.append(Row.make_eye_glow(sprite, Vector2(-8.0, -8.0), 0.6))
		_eye_glows.append(Row.make_eye_glow(sprite, Vector2(8.0, -8.0), 0.6))
	set_night(false)
	sync_position()

func rest_pos() -> Vector2:
	return Vector2(x, -row * CELL - CELL * 0.5)

func sync_position() -> void:
	position = rest_pos()
	z_index = clampi((2000 - row) * 2 + 1, -4000, 4000)

func face(dir: Vector2i) -> void:
	if dir.y > 0:
		sprite.rotation = 0.0
	elif dir.y < 0:
		sprite.rotation = PI
	elif dir.x > 0:
		sprite.rotation = PI * 0.5
	elif dir.x < 0:
		sprite.rotation = -PI * 0.5

func hop(dir: Vector2i, to_row: int, to_x: float, on_land: Callable) -> void:
	hopping = true
	riding = null
	face(dir)
	row = to_row
	x = to_x
	z_index = clampi((2000 - row) * 2 + 1, -4000, 4000)
	sprite.texture = Row.tex(char_name + "_1")
	var from := position
	var to := rest_pos()
	if _hop_tw != null and _hop_tw.is_valid():
		_hop_tw.kill()
	var tw := create_tween()
	_hop_tw = tw
	tw.tween_method(func (t: float):
		var p := from.lerp(to, t)
		p.y -= sin(t * PI) * 22.0
		position = p
	, 0.0, 1.0, HOP_T)
	tw.tween_callback(func ():
		hopping = false
		sprite.texture = Row.tex(char_name + "_0")
		sprite.scale = Vector2(4.4, 3.4)
		_fx_tw = create_tween()
		_fx_tw.tween_property(sprite, "scale", Vector2(4, 4), 0.06)
		on_land.call()
	)

func bump(dir: Vector2i) -> void:
	if hopping or riding != null:
		return
	_fx_tw = create_tween()
	var off := Vector2(dir.x, -dir.y) * 10.0
	_fx_tw.tween_property(self, "position", rest_pos() + off, 0.05)
	_fx_tw.tween_property(self, "position", rest_pos(), 0.05)

func follow_ride(dt: float) -> void:
	if riding != null and not hopping:
		x = riding["x"] + ride_offset
		position.x = x

var ride_offset := 0.0

func start_ride(ent) -> void:
	riding = ent
	ride_offset = x - ent["x"]

func die(cause: String) -> void:
	if dead:
		return
	dead = true
	riding = null
	if _hop_tw != null and _hop_tw.is_valid():
		_hop_tw.kill()
	if _fx_tw != null and _fx_tw.is_valid():
		_fx_tw.kill()
	hopping = false
	sprite.scale = Vector2(4, 4)
	var tw := create_tween()
	match cause:
		"water":
			tw.set_parallel(true)
			tw.tween_property(sprite, "scale", Vector2(1.2, 1.2), 0.4)
			tw.tween_property(sprite, "modulate", Color(0.5, 0.7, 1.0, 0.0), 0.45)
			tw.tween_property(self, "position:y", position.y + 14.0, 0.4)
			shadow.visible = false
		"scroll":
			tw.tween_property(sprite, "modulate", Color(1, 1, 1, 0), 0.3)
		_:
			sprite.rotation = 0.0
			tw.set_parallel(true)
			tw.tween_property(sprite, "scale", Vector2(5.6, 1.1), 0.09)
			tw.tween_property(sprite, "modulate", Color(1.0, 0.45, 0.45), 0.09)
