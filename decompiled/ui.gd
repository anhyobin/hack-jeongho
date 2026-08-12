extends CanvasLayer
class_name UI
var main: Node
var font_r: Font = load("res://assets/fonts/Galmuri11.ttf")
var font_b: Font = load("res://assets/fonts/Galmuri11-Bold.ttf")
var font_s: Font = load("res://assets/fonts/Galmuri9.ttf")
var title_root: Control = null
var hud_root: Control = null
var over_root: Control = null
var rank_root: Control = null
var pause_root: Control = null
var score_lbl: Label
var stage_lbl: Label
var best_lbl: Label
var selected_char:= 0
var char_frames: Array = []
var mute_b: Button = null
var submit_b: Button = null
const CHARS:= [
	{ "id": "rabbit", "name": "토끼"},
	{ "id": "chick", "name": "병아리"},
	{ "id": "hedgehog", "name": "고슴도치"},
	{ "id": "gorani_p", "name": "고라니"},
	{ "id": "peccy", "name": "페키"},
]
const CAUSE_TEXT:= {
	"car": "차에 치이고 말았다…",
	"gorani": "고라니와 정면충돌!",
	"train": "기차는 못 이겨요…",
	"water": "풍덩! 물에 빠졌다",
	"scroll": "어둠에 삼켜졌다…",
}
func _ready() -> void:
	layer = 10
func lbl(text: String, size: int, color:= Color.WHITE, bold:= false, outline:= 0) -> Label:
	var l:= Label.new()
	l.text = text
	l.add_theme_font_override("font", font_b if bold else font_r)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if outline > 0:
		l.add_theme_color_override("font_outline_color", Color(0.08, 0.1, 0.08, 0.9))
		l.add_theme_constant_override("outline_size", outline)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l
func btn(text: String, size: int, cb: Callable, bg:= Color("2f5a3a")) -> Button:
	var b:= Button.new()
	b.text = text
	b.add_theme_font_override("font", font_b)
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_color_override("font_color", Color("f4f1e8"))
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color("cfe9c0"))
	b.add_theme_color_override("font_focus_color", Color.WHITE)
	for st_name in ["normal", "hover", "pressed", "focus"]:
		var st:= StyleBoxFlat.new()
		st.bg_color = bg
		if st_name == "hover":
			st.bg_color = bg.lightened(0.12)
		elif st_name == "pressed":
			st.bg_color = bg.darkened(0.15)
		st.set_corner_radius_all(10)
		st.set_border_width_all(3)
		st.border_color = bg.darkened(0.35) if st_name != "focus" else Color("ffd94a")
		st.set_content_margin_all(10)
		st.content_margin_left = 18
		st.content_margin_right = 18
		b.add_theme_stylebox_override(st_name, st)
	b.pressed.connect(func():
		main.sfx.play("click", -8.0)
		cb.call()
	)
	return b
func panel_box() -> StyleBoxFlat:
	var st:= StyleBoxFlat.new()
	st.bg_color = Color(0.09, 0.14, 0.1, 0.96)
	st.set_corner_radius_all(14)
	st.set_border_width_all(3)
	st.border_color = Color("4a7a52")
	st.set_content_margin_all(22)
	return st
func full_rect(c: Control) -> void:
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
func clear(node: Control) -> void:
	if node != null and is_instance_valid(node):
		node.queue_free()
func show_title() -> void:
	hide_all()
	selected_char = int(main.ranking.data["char"])
	title_root = Control.new()
	full_rect(title_root)
	add_child(title_root)
	var bg:= ColorRect.new()
	bg.color = Color("223d28")
	full_rect(bg)
	title_root.add_child(bg)
	var road:= ColorRect.new()
	road.color = Color("41414b")
	road.position = Vector2(0, 250)
	road.size = Vector2(640, 90)
	title_root.add_child(road)
	for i in 8:
		var dash:= ColorRect.new()
		dash.color = Color("d8d4c0")
		dash.position = Vector2(i * 84 + 10, 292)
		dash.size = Vector2(30, 5)
		title_root.add_child(dash)
	var car:= TextureRect.new()
	car.texture = Row.tex("car_red")
	car.scale = Vector2(4, 4)
	car.position = Vector2(430, 268)
	title_root.add_child(car)
	var gor:= TextureRect.new()
	gor.texture = Row.tex("gorani_0")
	gor.scale = Vector2(6, 6)
	gor.position = Vector2(60, 226)
	title_root.add_child(gor)
	var logo:= lbl("고라니 피하기", 62, Color("ffd94a"), true, 10)
	logo.position = Vector2(0, 90)
	logo.size = Vector2(640, 80)
	title_root.add_child(logo)
	var sub:= lbl("숲속 찻길을 무사히 건너라!", 24, Color("cfe9c0"))
	sub.position = Vector2(0, 168)
	sub.size = Vector2(640, 30)
	title_root.add_child(sub)
	var pick:= lbl("캐릭터 선택", 22, Color("a8c8a0"))
	pick.position = Vector2(0, 384)
	pick.size = Vector2(640, 26)
	title_root.add_child(pick)
	char_frames = []
	var hb:= HBoxContainer.new()
	hb.position = Vector2(33, 424)
	hb.size = Vector2(574, 148)
	hb.add_theme_constant_override("separation", 6)
	title_root.add_child(hb)
	for i in CHARS.size():
		var holder:= Button.new()
		holder.custom_minimum_size = Vector2(110, 140)
		var st:= StyleBoxFlat.new()
		st.bg_color = Color(0.14, 0.22, 0.15, 0.9)
		st.set_corner_radius_all(12)
		st.set_border_width_all(4)
		st.border_color = Color("2a4a30")
		for sn in ["normal", "hover", "pressed", "focus"]:
			holder.add_theme_stylebox_override(sn, st.duplicate())
		var tr:= TextureRect.new()
		tr.texture = Row.tex(CHARS[i]["id"] + "_0")
		tr.scale = Vector2(5, 5)
		tr.position = Vector2(15, 18)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(tr)
		var nm:= lbl(CHARS[i]["name"], 19, Color("f4f1e8"))
		nm.position = Vector2(0, 104)
		nm.size = Vector2(110, 24)
		nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(nm)
		var idx:= i
		holder.pressed.connect(func():
			main.sfx.play("click", -8.0)
			selected_char = idx
			main.ranking.data["char"] = idx
			main.ranking.save_local()
			_update_char_frames()
		)
		hb.add_child(holder)
		char_frames.append(holder)
	_update_char_frames()
	var start:= btn("게임 시작", 34, func(): main.start_game(CHARS[selected_char]["id"]))
	start.position = Vector2(200, 610)
	start.size = Vector2(240, 70)
	title_root.add_child(start)
	var rank_b:= btn("랭킹 보기", 24, func(): show_ranking(), Color("3a5a6a"))
	rank_b.position = Vector2(200, 700)
	rank_b.size = Vector2(240, 56)
	title_root.add_child(rank_b)
	mute_b = btn(_mute_text(), 20, func():
		main.set_muted(not main.sfx.muted)
		mute_b.text = _mute_text()
	, Color("4a4a52"))
	mute_b.position = Vector2(230, 776)
	mute_b.size = Vector2(180, 46)
	title_root.add_child(mute_b)
	var help:= lbl("이동: 화살표·WASD·스와이프  |  탭 = 앞으로", 17, Color("8aa886"))
	help.position = Vector2(0, 850)
	help.size = Vector2(640, 22)
	title_root.add_child(help)
	var best:= lbl("내 최고기록: %d" % int(main.ranking.data["best"]), 20, Color("ffd94a"))
	best.position = Vector2(0, 884)
	best.size = Vector2(640, 24)
	title_root.add_child(best)
	start.grab_focus()
func _mute_text() -> String:
	return "소리: 끔" if main.sfx.muted else "소리: 켬"
func _update_char_frames() -> void:
	for i in char_frames.size():
		var sel:= i == selected_char
		for sn in ["normal", "hover", "pressed", "focus"]:
			var st: StyleBoxFlat = char_frames[i].get_theme_stylebox(sn)
			st.border_color = Color("ffd94a") if sel else Color("2a4a30")
func show_hud() -> void:
	hide_all()
	hud_root = Control.new()
	full_rect(hud_root)
	hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud_root)
	score_lbl = lbl("0", 52, Color.WHITE, true, 8)
	score_lbl.position = Vector2(0, 18)
	score_lbl.size = Vector2(640, 60)
	score_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(score_lbl)
	stage_lbl = lbl("", 18, Color("cfe9c0"), false, 5)
	stage_lbl.position = Vector2(0, 78)
	stage_lbl.size = Vector2(640, 24)
	stage_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(stage_lbl)
	best_lbl = lbl("최고 %d" % int(main.ranking.data["best"]), 17, Color("ffd94a"), false, 5)
	best_lbl.position = Vector2(-16, 20)
	best_lbl.size = Vector2(640, 22)
	best_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	best_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(best_lbl)
func set_score(s: int, row: int) -> void:
	if score_lbl == null or not is_instance_valid(score_lbl):
		return
	score_lbl.text = str(s)
	var theme:= ThemeDefs.theme_for_row(maxi(row, 0))
	stage_lbl.text = "STAGE %d · %s" % [ThemeDefs.stage_index(maxi(row, 0)) + 1, theme["name"]]
	var shown_best:= maxi(int(main.ranking.data["best"]), s)
	best_lbl.text = "최고 %d" % shown_best
func show_banner(text: String) -> void:
	if hud_root == null or not is_instance_valid(hud_root):
		return
	var p:= PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var st:= StyleBoxFlat.new()
	st.bg_color = Color(0.08, 0.12, 0.09, 0.55)
	st.set_corner_radius_all(8)
	st.set_border_width_all(2)
	st.border_color = Color(1.0, 0.85, 0.16, 0.7)
	st.content_margin_top = 5
	st.content_margin_bottom = 5
	st.content_margin_left = 18
	st.content_margin_right = 18
	p.add_theme_stylebox_override("panel", st)
	var l:= lbl(text, 22, Color("ffd94a"), true, 4)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(l)
	hud_root.add_child(p)
	p.reset_size()
	await get_tree().process_frame
	if not is_instance_valid(p) or not p.is_inside_tree():
		return
	p.position = Vector2((640.0 - p.size.x) * 0.5, 108)
	p.modulate.a = 0.0
	var tw:= create_tween()
	tw.tween_property(p, "modulate:a", 1.0, 0.25)
	tw.tween_interval(1.0)
	tw.tween_property(p, "modulate:a", 0.0, 0.4)
	tw.tween_callback(p.queue_free)
func float_text(text: String, pos: Vector2, color: Color) -> void:
	if hud_root == null or not is_instance_valid(hud_root):
		return
	var l:= lbl(text, 26, color, true, 6)
	l.position = pos + Vector2(-150, 0)
	l.size = Vector2(300, 30)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(l)
	var tw:= create_tween()
	tw.set_parallel(true)
	tw.tween_property(l, "position:y", l.position.y - 60.0, 0.9)
	tw.tween_property(l, "modulate:a", 0.0, 0.9).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(l.queue_free)
func show_game_over(score: int, rows: int, best: int, is_new_best: bool, cause: String, stage_i: int) -> void:
	clear(over_root)
	over_root = Control.new()
	full_rect(over_root)
	add_child(over_root)
	var dim:= ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	full_rect(dim)
	over_root.add_child(dim)
	var pc:= PanelContainer.new()
	pc.add_theme_stylebox_override("panel", panel_box())
	pc.position = Vector2(60, 150)
	pc.size = Vector2(520, 660)
	over_root.add_child(pc)
	var vb:= VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	pc.add_child(vb)
	vb.add_child(lbl("게임 오버", 44, Color("ff8a7a"), true))
	vb.add_child(lbl(CAUSE_TEXT.get(cause, "여정이 끝났다"), 21, Color("d8d4c8")))
	vb.add_child(lbl(str(score), 64, Color.WHITE, true))
	if is_new_best:
		vb.add_child(lbl("★ 신기록! ★", 24, Color("ffd94a"), true))
	else:
		vb.add_child(lbl("내 최고기록 %d" % best, 19, Color("a8c8a0")))
	var name_row:= HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 10)
	name_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(name_row)
	var name_edit:= LineEdit.new()
	name_edit.max_length = 12
	name_edit.text = str(main.ranking.data["nickname"])
	name_edit.placeholder_text = "닉네임"
	name_edit.custom_minimum_size = Vector2(230, 52)
	name_edit.add_theme_font_override("font", font_r)
	name_edit.add_theme_font_size_override("font_size", 22)
	name_row.add_child(name_edit)
	var status:= lbl("", 17, Color("a8c8a0"))
	submit_b = btn("랭킹 등록", 20, func():
		var nm:= name_edit.text.strip_edges()
		if nm.is_empty():
			nm = "무명고라니"
		main.ranking.data["nickname"] = nm
		main.ranking.save_local()
		submit_b.disabled = true
		status.text = "등록 중…"
		main.ranking.submit(nm, score, rows, main.last_char)
	, Color("6a5a2a"))
	name_row.add_child(submit_b)
	vb.add_child(status)
	var board:= _add_filtered_board(vb, 5, main.last_char)
	main.ranking.submitted.connect(func(ok: bool, rank: int, _list: Array):
		if not is_instance_valid(status):
			return
		if ok:
			status.text = "등록 완료! 현재 %d위" % rank if rank > 0 else "등록 완료!"
			board["reload"].call()
		elif main.ranking.submit_reason == "offline":
			status.text = "오프라인이라 랭킹 등록이 안 돼요 (게임은 계속 즐길 수 있어요)"
		else:
			status.text = "등록이 거부됐어요 (점수 검증 실패)"
			if is_instance_valid(submit_b):
				submit_b.disabled = false
	, CONNECT_ONE_SHOT)
	var hb:= HBoxContainer.new()
	hb.add_theme_constant_override("separation", 16)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(hb)
	var retry:= btn("다시하기", 26, func(): main.retry())
	retry.custom_minimum_size = Vector2(200, 62)
	hb.add_child(retry)
	var home:= btn("타이틀로", 26, func(): main.to_title(), Color("3a5a6a"))
	home.custom_minimum_size = Vector2(200, 62)
	hb.add_child(home)
	retry.grab_focus()
func _add_filtered_board(parent: VBoxContainer, limit: int, default_filter: String) -> Dictionary:
	var cur:= [default_filter]
	var tabs: Array = []
	var bar:= HBoxContainer.new()
	bar.add_theme_constant_override("separation", 4)
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	parent.add_child(bar)
	var list_box:= VBoxContainer.new()
	list_box.add_theme_constant_override("separation", 4)
	parent.add_child(list_box)
	var load_fn:= func():
		var want: String = cur[0]
		_fill_rank_list(list_box, [], limit, "불러오는 중…")
		main.ranking.fetch_board(want, func(lst: Array, ok: bool):
			if not is_instance_valid(list_box) or cur[0] != want:
				return
			_fill_rank_list(list_box, lst, limit, "" if ok else "서버 랭킹 연결 실패")
		)
	var opts: Array = [{ "id": "", "name": "전체"}]
	for c in CHARS:
		opts.append(c)
	for o in opts:
		var b:= Button.new()
		b.custom_minimum_size = Vector2(0, 42)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.tooltip_text = o["name"]
		for sn in ["normal", "hover", "pressed", "focus"]:
			var st:= StyleBoxFlat.new()
			st.bg_color = Color(0.14, 0.22, 0.15, 0.9)
			st.set_corner_radius_all(8)
			st.set_border_width_all(3)
			st.border_color = Color("2a4a30")
			st.set_content_margin_all(4)
			b.add_theme_stylebox_override(sn, st)
		if o["id"] == "":
			b.text = "전체"
			b.add_theme_font_override("font", font_b)
			b.add_theme_font_size_override("font_size", 16)
			b.add_theme_color_override("font_color", Color("f4f1e8"))
		else:
			b.icon = Row.tex(o["id"] + "_0")
			b.expand_icon = true
		var oid: String = o["id"]
		b.pressed.connect(func():
			main.sfx.play("click", -10.0)
			cur[0] = oid
			_update_filter_tabs(tabs, oid)
			load_fn.call()
		)
		bar.add_child(b)
		tabs.append({ "btn": b, "id": o["id"]})
	_update_filter_tabs(tabs, cur[0])
	load_fn.call()
	return { "list_box": list_box, "reload": load_fn, "get": func(): return cur[0]}
func _update_filter_tabs(tabs: Array, sel: String) -> void:
	for t in tabs:
		var on: bool = t["id"] == sel
		for sn in ["normal", "hover", "pressed", "focus"]:
			var st: StyleBoxFlat = t["btn"].get_theme_stylebox(sn)
			st.border_color = Color("ffd94a") if on else Color("2a4a30")
func _fill_rank_list(box: VBoxContainer, list: Array, limit: int, note: String) -> void:
	for c in box.get_children():
		c.queue_free()
	box.add_child(lbl("— 서버 랭킹 TOP %d —" % limit, 18, Color("8ab8d8")))
	if note != "":
		box.add_child(lbl(note, 16, Color("c8a888")))
	var n:= mini(limit, list.size())
	for i in n:
		var e: Dictionary = list[i]
		var row:= HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var rank_l:= lbl("%d." %(i + 1), 19, Color("ffd94a") if i < 3 else Color("d8d4c8"))
		rank_l.custom_minimum_size = Vector2(40, 0)
		rank_l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(rank_l)
		var cid:= str(e.get("char", "rabbit"))
		if not ["rabbit", "chick", "hedgehog", "gorani_p", "peccy"].has(cid):
			cid = "rabbit"
		var icon:= TextureRect.new()
		icon.texture = Row.tex(cid + "_0")
		icon.custom_minimum_size = Vector2(32, 32)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(icon)
		var name_l:= lbl(str(e.get("name", "?")), 19, Color("f4f1e8"))
		name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(name_l)
		var sc_l:= lbl(str(int(e.get("score", 0))), 19, Color("cfe9c0"))
		sc_l.custom_minimum_size = Vector2(80, 0)
		sc_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		sc_l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(sc_l)
		box.add_child(row)
	if n == 0 and note == "":
		box.add_child(lbl("아직 기록이 없어요 — 1등을 노려보세요!", 16, Color("a8c8a0")))
func show_ranking() -> void:
	clear(rank_root)
	rank_root = Control.new()
	full_rect(rank_root)
	add_child(rank_root)
	var dim:= ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	full_rect(dim)
	rank_root.add_child(dim)
	var pc:= PanelContainer.new()
	pc.add_theme_stylebox_override("panel", panel_box())
	pc.position = Vector2(70, 140)
	pc.size = Vector2(500, 640)
	rank_root.add_child(pc)
	var vb:= VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	pc.add_child(vb)
	vb.add_child(lbl("랭킹", 40, Color("ffd94a"), true))
	_add_filtered_board(vb, 10, "")
	vb.add_child(lbl("내 최고기록: %d" % int(main.ranking.data["best"]), 20, Color("cfe9c0")))
	var close:= btn("닫기", 24, func():
		clear(rank_root)
		rank_root = null
	, Color("3a5a6a"))
	close.custom_minimum_size = Vector2(160, 56)
	var hb:= HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.add_child(close)
	vb.add_child(hb)
	var self_path:= close.get_path()
	close.focus_next = self_path
	close.focus_previous = self_path
	close.focus_neighbor_top = self_path
	close.focus_neighbor_bottom = self_path
	close.focus_neighbor_left = self_path
	close.focus_neighbor_right = self_path
	close.grab_focus()
func show_pause() -> void:
	clear(pause_root)
	pause_root = Control.new()
	full_rect(pause_root)
	pause_root.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(pause_root)
	var dim:= ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	full_rect(dim)
	pause_root.add_child(dim)
	var vb:= VBoxContainer.new()
	vb.position = Vector2(190, 380)
	vb.size = Vector2(260, 220)
	vb.add_theme_constant_override("separation", 18)
	pause_root.add_child(vb)
	vb.add_child(lbl("일시정지", 36, Color.WHITE, true))
	var res:= btn("계속하기", 24, func(): main.resume())
	vb.add_child(res)
	var home:= btn("타이틀로", 24, func(): main.to_title(), Color("3a5a6a"))
	vb.add_child(home)
	res.grab_focus()
func hide_pause() -> void:
	clear(pause_root)
	pause_root = null
func hide_all() -> void:
	for r in [title_root, hud_root, over_root, rank_root, pause_root]:
		clear(r)
	title_root = null
	hud_root = null
	over_root = null
	rank_root = null
	pause_root = null
	score_lbl = null
	stage_lbl = null
	best_lbl = null
	mute_b = null
	submit_b = null
