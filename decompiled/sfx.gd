extends Node
class_name Sfx
var streams:= {}
var pool: Array[AudioStreamPlayer] = []
var pool_i:= 0
var music: AudioStreamPlayer
var muted:= false
const NAMES:= ["hop", "crash", "horn", "splash", "train", "gorani", "stage", "near", "over", "click", "bgm"]
func _ready() -> void:
	for n in NAMES:
		var st: AudioStream = load("res://assets/audio/%s.wav" % n)
		streams[n] = st
	for i in 8:
		var p:= AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		pool.append(p)
	music = AudioStreamPlayer.new()
	music.bus = "Master"
	music.volume_db = -7.0
	add_child(music)
	var bgm: AudioStreamWAV = streams["bgm"]
	bgm.loop_mode = AudioStreamWAV.LOOP_FORWARD
	bgm.loop_begin = 0
	bgm.loop_end = int(round(bgm.get_length() * bgm.mix_rate))
	music.stream = bgm
func play(n: String, vol_db:= 0.0, pitch:= 1.0, jitter:= 0.0) -> void:
	if muted or not streams.has(n):
		return
	var p:= pool[pool_i]
	pool_i =(pool_i + 1) % pool.size()
	p.stream = streams[n]
	p.volume_db = vol_db
	p.pitch_scale = pitch + randf_range(-jitter, jitter)
	p.play()
func start_music() -> void:
	if not music.playing:
		music.play()
func stop_music() -> void:
	music.stop()
func set_muted(m: bool) -> void:
	muted = m
	AudioServer.set_bus_mute(0, m)
