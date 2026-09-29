extends Node
## Global game clock, hit-stop / slow motion, camera shake and shared references.
##
## `clock` is scaled game time advanced once per physics tick (before any other node,
## see process_physics_priority). Hit-stop and slow motion count real time (see `unscaled`).
## Input presses are stamped with `precise_now()`, which adds the real time elapsed since the
## last tick, so deflect timing is measured with sub-tick precision instead of being rounded to
## frames.

signal debug_toggled(enabled: bool)

var clock := 0.0
var tick_delta := 1.0 / 120.0
var _last_tick_usec := 0

var base_time_scale := 1.0
## Hit-stop / slow motion remaining, in unscaled seconds (counted down per rendered frame,
## so they behave the same live, in Movie Maker captures and in the headless test lab).
var _hitstop_left := 0.0
var _hitstop_scale := 1.0
var _slowmo_left := 0.0
var _slowmo_scale := 1.0
## The time scale this frame's deltas were scaled by: Godot reads Engine.time_scale once, as a
## frame begins, so a change during the frame (a deflect's hit-stop, in a physics step) is the
## next frame's. A physics step's delta shows it exactly (see _physics_process). And whether
## _process has counted this frame yet: a change after that is the next frame's too.
var _frame_scale := 1.0
var _frame_counted := false
## A hit-stop or slow motion started during a frame: that frame began before it, so it isn't
## slowed and doesn't count; the effect starts counting from the next one.
var _hitstop_fresh := false
var _slowmo_fresh := false
## Deterministic mode (Movie Maker, tests): input presses are stamped with the tick clock
## instead of wall-clock time, and the test lab can switch time effects off.
var deterministic := false
var time_effects_enabled := true

var player: Node = null
var boss: Node = null
var camera: Node = null
var hud: Node = null

## Options. `music_volume` (0..1, the Options slider, see Music.volume_db) is kept between
## sessions in SETTINGS_PATH. The testing options aren't: every session starts in phase 1 with
## diagnostics off, whatever the last one was set to. `debug` is the diagnostics overlay:
## hitboxes, hit windows and live combat readouts (Options menu or F3). `start_phase` is the
## phase the fight starts in (for testing the later phases).
const SETTINGS_PATH := "user://settings.cfg"
## Quiet: the music sits under the fight (16 dB under full, see Music.FULL_DB).
const DEFAULT_MUSIC_VOLUME := 0.4
const MUSIC_VOLUME_STEP := 0.1
var debug := false
var start_phase := 1
var music_volume := DEFAULT_MUSIC_VOLUME
## Set before reloading the scene to go straight back into the fight (retry, restart)
## instead of the title menu.
var skip_title := false
## Warmup (every effect drawn once behind a loading screen as the game starts, so none stutters
## the first time it shows): `warmup` whether to (the capture harness turns it off), `warmed_up`
## once it's done (once per launch).
var warmup := true
var warmed_up := false
## Tests switch this off so they never overwrite the player's saved options.
var save_enabled := true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = -1000
	process_priority = 1000      # _process last: it counts the frame after every other node's
	get_tree().physics_frame.connect(_new_frame)
	get_tree().process_frame.connect(_new_frame)
	_last_tick_usec = Time.get_ticks_usec()
	if Engine.get_write_movie_path() != "":
		deterministic = true
	load_settings()


## Reads the saved options. Earlier builds saved the starting phase and diagnostics too
## ([fight]): those are left alone, so a phase picked for testing doesn't stick.
func load_settings(path := SETTINGS_PATH) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return
	music_volume = _music_step(float(cfg.get_value("audio", "music_volume", DEFAULT_MUSIC_VOLUME)))


func save_settings(path := SETTINGS_PATH) -> void:
	if not save_enabled:
		return
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "music_volume", music_volume)
	cfg.save(path)


func set_diagnostics(on: bool) -> void:
	debug = on
	debug_toggled.emit(debug)


func set_start_phase(n: int) -> void:
	start_phase = clampi(n, 1, Combat.BOSS_LIVES)


func set_music_volume(v: float) -> void:
	music_volume = _music_step(v)
	save_settings()


## On the slider's steps (tenths), within 0..1.
static func _music_step(v: float) -> float:
	return clampf(snappedf(v, MUSIC_VOLUME_STEP), 0.0, 1.0)


func _physics_process(delta: float) -> void:
	_frame_scale = delta * Engine.physics_ticks_per_second   # (a step is 1 / ticks of real time)
	if get_tree().paused:
		return
	clock += delta
	tick_delta = delta
	_last_tick_usec = Time.get_ticks_usec()


func _new_frame() -> void:
	_frame_counted = false


func _process(delta: float) -> void:
	var real_dt := minf(unscaled(delta), 0.1)
	if not _hitstop_fresh:
		_hitstop_left = _count_down(_hitstop_left, real_dt)
	if not _slowmo_fresh:
		_slowmo_left = _count_down(_slowmo_left, real_dt)
	_hitstop_fresh = false
	_slowmo_fresh = false
	_apply_time_scale()
	_frame_scale = Engine.time_scale     # the next frame's (unless it changes before it begins)
	_frame_counted = true


## Whether this frame's deltas are already spent, so a time-scale change now is the next
## frame's: after _process has counted the frame, and never while physics is stepping.
func _between_frames() -> bool:
	return _frame_counted and not Engine.is_in_physics_frame()


static func _count_down(left: float, dt: float) -> float:
	left -= dt
	return left if left > 0.0001 else 0.0     # (a float crumb mustn't hold the effect a frame longer)


## The real (unscaled) seconds in a delta given to this frame's callbacks. Godot scales a frame's
## deltas by the time scale in force when the frame began, so a hit-stop started during the frame
## (a deflect, in a physics step) doesn't change them: dividing by the new Engine.time_scale would
## count ~50x too much real time and end the freeze at once. For anything that runs in real time
## through hit-stop and slow motion (the HUD, the menus, the camera), in _process.
func unscaled(delta: float) -> float:
	return delta / maxf(_frame_scale, 0.0001)


## Game-time stamp for an input event that arrived between physics ticks.
func precise_now() -> float:
	if deterministic:
		return clock
	var real_dt := float(Time.get_ticks_usec() - _last_tick_usec) / 1000000.0
	var max_dt := 1.0 / float(Engine.physics_ticks_per_second)
	return clock + clampf(real_dt, 0.0, max_dt) * Engine.time_scale


## Freezes the action for `duration` real seconds (time slowed to `scale`), scaled by
## Combat.HITSTOP_STRENGTH.
func hitstop(duration: float, scale := 0.02) -> void:
	if not time_effects_enabled:
		return
	duration *= Combat.HITSTOP_STRENGTH
	if _hitstop_left <= 0.0:
		_hitstop_scale = scale
		_hitstop_fresh = not _between_frames()   # (started mid-frame: count from the next)
	else:
		_hitstop_scale = minf(_hitstop_scale, scale)
	_hitstop_left = maxf(_hitstop_left, duration)
	_apply_time_scale()


func slowmo(duration: float, scale: float) -> void:
	if not time_effects_enabled:
		return
	if _slowmo_left <= 0.0:
		_slowmo_fresh = not _between_frames()
	_slowmo_left = maxf(_slowmo_left, duration)
	_slowmo_scale = scale
	_apply_time_scale()


func clear_time_effects() -> void:
	_hitstop_left = 0.0
	_slowmo_left = 0.0
	_hitstop_fresh = false
	_slowmo_fresh = false
	_hitstop_scale = 1.0
	Engine.time_scale = base_time_scale
	if _between_frames():
		_frame_scale = base_time_scale


func _apply_time_scale() -> void:
	var s := base_time_scale
	if _slowmo_left > 0.0:
		s = minf(s, _slowmo_scale)
	if _hitstop_left > 0.0:
		s = minf(s, _hitstop_scale)
	else:
		_hitstop_scale = 1.0
	Engine.time_scale = s
	if _between_frames():
		_frame_scale = s             # (the next frame's)


func shake(strength: float, duration := 0.25) -> void:
	if camera != null and camera.has_method("add_shake"):
		camera.call("add_shake", strength, duration)


func rumble(weak: float, strong: float, duration: float) -> void:
	for id in Input.get_connected_joypads():
		Input.start_joy_vibration(id, weak, strong, duration)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("fullscreen"):
		var mode := DisplayServer.window_get_mode()
		if mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		else:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif event.is_action_pressed("debug"):
		set_diagnostics(not debug)
