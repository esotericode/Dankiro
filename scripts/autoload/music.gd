extends Node
## The score: a track for each of his three phases (audio/music/phase_N.mp3), crossfaded as the
## fight moves on. main.gd says what to play: the phase's track as the fight begins, a dip under
## a deathblow, the next phase's track as he rises and roars, and a fade to silence when you die,
## when he does and on the way back to the title (which is quiet but for the wind). A phase that
## outlasts its track starts it again as its closing fade dies away (`loop_at` in
## data/music.json, measured by tools/music_levels.py along with a trim that evens out the
## tracks' levels), so the music never stops for the silence at the end of a track.
##
## Everything plays on the "Music" bus (Sfx sets it up; it dips a little under the deflect) at
## the Options' music volume, `Game.music_volume`, quiet by default. Fades run in real time, through
## hit-stop, slow motion and the pause menu, and across a restart (this is an autoload).

const DATA_PATH := "res://data/music.json"
const TRACKS := ["phase_1", "phase_2", "phase_3"]
## The bus at 100 % in Options: the tracks, evened out to -12 LUFS, at about -14 LUFS, as loud as
## the fight's sounds. The volume is squared on the way (volume_db), so 40 %, the default, is
## 16 dB under that: there, but under the fight.
const FULL_DB := -2.0
const SILENT_DB := -80.0


## One playing copy of a track, and its fade.
class Voice:
	var player: AudioStreamPlayer
	var track := 0
	var gain := 0.0          ## 0..1 along its fade; equal power (sin), so a crossfade holds the level
	var target := 1.0
	var rate := 0.0          ## gain per second toward the target
	var looped := false      ## the next time round has started
	var done := false        ## played to its end


var _voices: Array[Voice] = []
var _current: Voice = null          ## the voice playing (or fading in); null in silence
var _info: Dictionary = {}          ## track name -> its entry in data/music.json
var _streams: Dictionary = {}       ## track index -> AudioStream
var _preview := false
var _bus := -1
var _bus_volume := -1.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var text := FileAccess.get_file_as_string(DATA_PATH)
	var data: Variant = JSON.parse_string(text) if text != "" else null
	if data is Dictionary:
		_info = (data as Dictionary).get("tracks", {})
	_apply_volume()


## The bus level for a music volume of `v` (0..1, the Options slider): squared, so the steps
## sound roughly even, and off at 0.
static func volume_db(v: float) -> float:
	return FULL_DB + linear_to_db(v * v) if v > 0.0 else SILENT_DB


## Phase `n`'s track (1 to 3), faded in over `fade` seconds while whatever else is playing fades
## out. If it's playing already it carries on, back up to full if it was dipped.
func play_phase(n: int, fade := 2.0) -> void:
	var track := clampi(n, 1, TRACKS.size()) - 1
	_preview = false
	if _current != null and _current.track == track:
		_fade(_current, 1.0, fade)
		return
	for v in _voices:
		_fade(v, 0.0, fade)
	_current = _start(track, fade)


## Everything fades to silence over `fade` seconds.
func fade_out(fade := 2.0) -> void:
	_preview = false
	for v in _voices:
		_fade(v, 0.0, fade)
	_current = null


## The music sinks to `db` under full over `fade` seconds (under a deathblow), until play_phase
## brings it back up or moves on to the next track.
func dip(db := -10.0, fade := 1.0) -> void:
	if _current != null:
		_fade(_current, asin(db_to_linear(db)) / (PI * 0.5), fade)


## Changing the music volume on the title's Options page (the title is quiet) plays phase 1's
## track so you can hear it; end_preview (leaving the page) fades it out again.
func preview() -> void:
	if _current == null:
		_current = _start(0, 1.0)
		_preview = _current != null


func end_preview(fade := 1.2) -> void:
	if _preview:
		fade_out(fade)


## The phase whose track is playing (fading in or dipped included), 0 in silence.
func current_phase() -> int:
	return _current.track + 1 if _current != null else 0


## The current track's level, 0..1 (1 at full, before the music volume).
func level() -> float:
	return sin(_current.gain * PI * 0.5) if _current != null else 0.0


## How many copies of tracks are still sounding (two through a crossfade or a loop).
func voices() -> int:
	return _voices.size()


## Stops everything at once (tests).
func stop_all() -> void:
	for v in _voices:
		v.player.queue_free()
	_voices.clear()
	_current = null
	_preview = false


func _process(delta: float) -> void:
	_apply_volume()
	var dt := minf(Game.unscaled(delta), 0.1)
	for v in _voices.duplicate():
		if v.gain != v.target:
			v.gain = move_toward(v.gain, v.target, v.rate * dt)
			v.player.volume_db = _voice_db(v)     # (only while it fades: each change is handed to the audio thread)
		if v == _current and not v.looped and (v.done or v.player.get_playback_position() >= _loop_at(v.track)):
			# The next time round, at once (this one's tail is 40 dB down by now and plays out
			# under it), at the level this one is at.
			v.looped = true
			var next := _start(v.track, 0.0)
			if next != null:
				next.gain = v.gain
				next.target = v.target
				next.rate = v.rate
				next.player.volume_db = _voice_db(next)
			_current = next
		if v.done or (v.gain <= 0.0 and v.target <= 0.0):
			_voices.erase(v)
			v.player.queue_free()


func _start(track: int, fade: float) -> Voice:
	var st := _stream(track)
	if st == null:
		return null
	var v := Voice.new()
	v.track = track
	v.player = AudioStreamPlayer.new()
	v.player.bus = &"Music"
	v.player.stream = st
	v.player.finished.connect(func(): v.done = true)
	_fade(v, 1.0, fade)
	v.player.volume_db = _voice_db(v)
	add_child(v.player)
	v.player.play()
	_voices.append(v)
	return v


func _fade(v: Voice, to: float, seconds: float) -> void:
	v.target = clampf(to, 0.0, 1.0)
	if seconds <= 0.0:
		v.gain = v.target
		v.rate = 0.0
	else:
		v.rate = absf(v.target - v.gain) / seconds


func _voice_db(v: Voice) -> float:
	var a := sin(clampf(v.gain, 0.0, 1.0) * PI * 0.5)
	if a <= 0.0001:
		return SILENT_DB
	return linear_to_db(a) + float(_entry(v.track).get("trim_db", 0.0))


func _loop_at(track: int) -> float:
	return float(_entry(track).get("loop_at", INF))


func _entry(track: int) -> Dictionary:
	return _info.get(TRACKS[track], {})


## A copy of the track, like Sfx's wind: quitting mid-fight leaves the audio server holding the
## stream that's playing, and a copy isn't one of the loaded files the engine checks at exit.
func _stream(track: int) -> AudioStream:
	if not _streams.has(track):
		var path := str(_entry(track).get("file", "res://audio/music/%s.mp3" % TRACKS[track]))
		var st := load(path) as AudioStream if ResourceLoader.exists(path) else null
		_streams[track] = st.duplicate() as AudioStream if st != null else null
	return _streams[track]


func _apply_volume() -> void:
	if _bus < 0:
		_bus = AudioServer.get_bus_index("Music")
		if _bus < 0:
			return
	var v := clampf(Game.music_volume, 0.0, 1.0)
	if v != _bus_volume:
		_bus_volume = v
		AudioServer.set_bus_volume_db(_bus, volume_db(v))
		AudioServer.set_bus_mute(_bus, v <= 0.0)
