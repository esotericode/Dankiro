extends Node
## Global game clock, hit-stop / slow motion, camera shake and shared references.
##
## `clock` is scaled game time advanced once per physics tick (before any other node,
## see process_physics_priority). Input presses are stamped with `precise_now()`, which
## adds the real time elapsed since the last tick, so deflect timing is measured with
## sub-tick precision instead of being rounded to frames.

signal debug_toggled(enabled: bool)

var clock := 0.0
var tick_delta := 1.0 / 120.0
var _last_tick_usec := 0

var base_time_scale := 1.0
var _hitstop_until := 0
var _hitstop_scale := 1.0
var _slowmo_until := 0
var _slowmo_scale := 1.0

var player: Node = null
var boss: Node = null
var camera: Node = null
var hud: Node = null
var debug := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = -1000
	_last_tick_usec = Time.get_ticks_usec()


func _physics_process(delta: float) -> void:
	if get_tree().paused:
		return
	clock += delta
	tick_delta = delta
	_last_tick_usec = Time.get_ticks_usec()


func _process(_delta: float) -> void:
	_apply_time_scale()


## Game-time stamp for an input event that arrived between physics ticks.
func precise_now() -> float:
	var real_dt := float(Time.get_ticks_usec() - _last_tick_usec) / 1000000.0
	var max_dt := 1.0 / float(Engine.physics_ticks_per_second)
	return clock + clampf(real_dt, 0.0, max_dt) * Engine.time_scale


## Freezes the action for `duration` real seconds (time slowed to `scale`).
func hitstop(duration: float, scale := 0.02) -> void:
	var now := Time.get_ticks_usec()
	if now >= _hitstop_until:
		_hitstop_scale = scale
	else:
		_hitstop_scale = minf(_hitstop_scale, scale)
	_hitstop_until = maxi(_hitstop_until, now + int(duration * 1000000.0))
	_apply_time_scale()


func slowmo(duration: float, scale: float) -> void:
	_slowmo_until = maxi(_slowmo_until, Time.get_ticks_usec() + int(duration * 1000000.0))
	_slowmo_scale = scale
	_apply_time_scale()


func clear_time_effects() -> void:
	_hitstop_until = 0
	_slowmo_until = 0
	_hitstop_scale = 1.0
	Engine.time_scale = base_time_scale


func _apply_time_scale() -> void:
	var now := Time.get_ticks_usec()
	var s := base_time_scale
	if now < _slowmo_until:
		s = minf(s, _slowmo_scale)
	if now < _hitstop_until:
		s = minf(s, _hitstop_scale)
	else:
		_hitstop_scale = 1.0
	Engine.time_scale = s


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
		debug = not debug
		debug_toggled.emit(debug)
