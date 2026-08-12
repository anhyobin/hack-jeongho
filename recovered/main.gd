extends Node


var sfx: Sfx
var ranking: Ranking
var ui: UI
var game: Game = null
var app_state := "title"
var last_char := "rabbit"
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

func set_muted(m: bool) -> void:
	sfx.set_muted(m)
	ranking.data["muted"] = m
	ranking.save_local()

func start_game(char_id: String) -> void:
	last_char = char_id
	_over_token += 1
	if game != null:
		game.queue_free()
	get_tree().paused = false
	app_state = "play"
	game = Game.new()
	game.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(game)
	game.setup(self, char_id)
	ui.show_hud()
	sfx.start_music()

func on_game_over(score: int, rows: int, stage_idx: int, cause: String) -> void:

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
