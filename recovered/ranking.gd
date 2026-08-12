extends Node
class_name Ranking


signal submitted(ok: bool, rank: int, list: Array)

const SAVE_PATH := "user://save.json"

var data := { "nickname": "", "best": 0, "muted": false, "char": 0}
var server_ok := false
var top: Array = []
var token := ""
var submit_reason := ""

func _ready() -> void:
	load_local()

func base_url() -> String:
	if OS.has_feature("web"):
		var v = JavaScriptBridge.eval("location.origin + location.pathname.replace(/[^/]*$/, '')", true)
		if v is String and v.begins_with("http"):
			return v
	return "http://127.0.0.1:8000/"

func load_local() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		for k in data.keys():
			if parsed.has(k):
				data[k] = parsed[k]

func save_local() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(data))
	f.close()

func record_score(score: int) -> bool:

	if score > int(data["best"]):
		data["best"] = score
		save_local()
		return true
	return false

func _request(url: String, method: int, body: String, cb: Callable) -> void:
	var hr := HTTPRequest.new()
	hr.timeout = 5.0
	add_child(hr)
	hr.request_completed.connect(func (result: int, code: int, _h: PackedStringArray, raw: PackedByteArray):
		var payload = null
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			payload = JSON.parse_string(raw.get_string_from_utf8())
		cb.call(payload)
		hr.queue_free()
	)
	var headers := PackedStringArray(["Content-Type: application/json"])
	var err := hr.request(url, headers, method, body)
	if err != OK:
		cb.call(null)
		hr.queue_free()

func start_run() -> void:

	token = ""
	_request(base_url() + "api/start", HTTPClient.METHOD_GET, "", func (payload):
		if payload is Dictionary and payload.has("token"):
			token = str(payload["token"])
	)

func fetch_board(char_filter: String, cb: Callable) -> void:

	var url := base_url() + "api/scores"
	if char_filter != "":
		url += "?char=" + char_filter
	_request(url, HTTPClient.METHOD_GET, "", func (payload):
		if payload is Dictionary and payload.has("scores"):
			server_ok = true
			cb.call(payload["scores"], true)
		else:
			server_ok = false
			cb.call([], false)
	)

func submit(name: String, score: int, rows: int, char_id := "rabbit") -> void:
	if token == "":

		submit_reason = "offline"
		submitted.emit(false, -1, [])
		return
	var body := JSON.stringify({ "name": name, "score": score, "rows": rows, "char": char_id, "token": token})
	_request(base_url() + "api/scores", HTTPClient.METHOD_POST, body, func (payload):
		if payload is Dictionary and payload.get("ok", false):
			token = ""
			server_ok = true
			top = payload.get("scores", [])
			submit_reason = ""
			submitted.emit(true, int(payload.get("rank", -1)), top)
		else:
			submit_reason = "rejected"
			submitted.emit(false, -1, [])
	)
