extends Node
## Scripted capture director for visual checks with Godot's Movie Maker:
##   godot --write-movie out/frame.png --fixed-fps 30 res://tests/capture.tscn -- <shot>
## Shots: overview, deflect, deflect_offcenter, block, mikiri, thrust_backstep, sweep, sweep_flee, whirl, shuriken,
## shuriken5, charge, slashes, parried, attack <clip> [distance], and art checks: model (orbit), model_head,
## model_face, model_face_p2, model_combo, model_flourish.
## Loads the real game scene (arena, lighting, HUD, lock-on camera), skips the intro, stages
## the fighters and drives the player with a bot that reacts to the boss's hit windows.

var main: Node
var player: Player
var boss: Boss
var shot := "deflect"
var t := 0.0
var _pressed: Dictionary = {}
var _clip_serial := 0
var _last_clip := ""
var _release_at := -1.0
var _steps: Array = []          ## [time, Callable]
var _end_at := 4.0
var _orbit_cam: Camera3D        ## art-check camera orbiting the boss
var _orbit := {"radius": 2.8, "height": 1.45, "look_y": 1.3, "speed": 90.0, "start": 0.0}


func _ready() -> void:
	process_physics_priority = -500
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		shot = args[0]
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(main)
	await get_tree().physics_frame
	player = Game.player as Player
	boss = Game.boss as Boss
	main.set("flow", 1)                          # Flow.FIGHT
	Game.hud.call("hide_overlay")
	var card: Control = Game.hud.get("_namecard")
	if card != null:
		card.visible = false
	player.controls_enabled = true
	player.bot_enabled = true
	boss.passive = true
	boss.state = Boss.S.NEUTRAL
	boss.anim.play_locomotion(Boss.LOCO, 0.0)
	_stage(2.4)
	call("shot_" + shot)


func _stage(dist: float, boss_pos := Vector3(0, 0, -1.0)) -> void:
	boss.global_position = boss_pos
	boss.set_facing(0.0)
	player.global_position = boss_pos + Vector3(0, 0, dist)
	boss.face_now(player.global_position)
	player.face_now(boss.global_position)
	var cam := Game.camera as CombatCamera
	if cam != null:
		cam.setup(player, boss)


func at(time: float, fn: Callable) -> void:
	_steps.append([time, fn])


func _physics_process(delta: float) -> void:
	t += delta
	var due: Array = []
	for s in _steps:
		if t >= float(s[0]):
			due.append(s)
	for s in due:
		_steps.erase(s)
		(s[1] as Callable).call()
	if t >= _end_at:
		get_tree().quit()


# ------------------------------------------------------------------------- bot helpers
## Presses guard `lead` seconds before each boss hit window opens (clip time), releasing
## after `hold` seconds (hold < 0 keeps it held).
func auto_guard(lead := 0.05, hold := 0.12) -> void:
	var fn := func():
		_auto_guard_tick(lead, hold)
	_steps.append([0.0, fn])
	set_meta("auto_guard", [lead, hold])


func _process(_delta: float) -> void:
	if _orbit_cam != null and boss != null:
		var a := deg_to_rad(float(_orbit["start"]) + t * float(_orbit["speed"]))
		var c := boss.global_position
		var fwd := boss.forward()
		var right := fwd.cross(Vector3.UP)
		var off := (fwd * cos(a) + right * sin(a)) * float(_orbit["radius"])
		_orbit_cam.global_position = c + off + Vector3.UP * float(_orbit["height"])
		_orbit_cam.look_at(c + Vector3.UP * float(_orbit["look_y"]), Vector3.UP)
	if has_meta("auto_guard") and boss != null:
		var cfg: Array = get_meta("auto_guard")
		_auto_guard_tick(float(cfg[0]), float(cfg[1]))
		_auto_guard_projectiles(float(cfg[0]))


var _seen_projectiles: Dictionary = {}


func _auto_guard_projectiles(lead: float) -> void:
	for n in player.get_parent().get_children():
		if n is Shuriken and (n as Shuriken)._flying and not _seen_projectiles.has(n.get_instance_id()):
			var cap := player.hurt_capsule()
			var q := Geometry3D.get_closest_point_to_segment(n.global_position, cap[0], cap[1])
			if (q.distance_to(n.global_position) - float(cap[2])) / Shuriken.SPEED <= lead + 0.03:
				_seen_projectiles[n.get_instance_id()] = true
				if player.guard_held:
					player.release_guard(Game.clock)
				player.press_guard(Game.clock)
				_release_at = Game.clock + 0.05


func _auto_guard_tick(lead: float, hold: float) -> void:
	if boss.state != Boss.S.ATTACK or boss.anim.clip == null or boss.anim.loco_active:
		if _release_at > 0.0 and Game.clock >= _release_at:
			player.release_guard(Game.clock)
			_release_at = -1.0
		return
	if boss.anim.clip.name != _last_clip or boss.anim.time < 0.02:
		_last_clip = boss.anim.clip.name
		_clip_serial += 1
	for i in boss.anim.clip.hits.size():
		var h: Dictionary = boss.anim.clip.hits[i]
		var k := "%d:%d" % [_clip_serial, i]
		if _pressed.has(k):
			continue
		if boss.anim.time >= float(h["from"]) - lead:
			_pressed[k] = true
			if player.guard_held:
				player.release_guard(Game.clock)
			player.press_guard(Game.clock)
			_release_at = Game.clock + hold if hold >= 0.0 else -1.0
	if _release_at > 0.0 and Game.clock >= _release_at:
		player.release_guard(Game.clock)
		_release_at = -1.0


func boss_string(clips: Array) -> void:
	boss._seq.clear()
	for i in range(1, clips.size()):
		boss._seq.append([clips[i], 1.0])
	boss.face_now(player.global_position)
	boss._play_attack(clips[0], 0.0)


# ------------------------------------------------------------------------- shots
func shot_overview() -> void:
	_stage(4.5)
	_end_at = 1.5


## Boss string, every hit deflected on time: sparks, flash, clang, hit-stop.
func shot_deflect() -> void:
	auto_guard(0.05, 0.12)
	at(0.4, func(): boss_string(["b_combo_1", "b_combo_2", "b_combo_3"]))
	_end_at = 3.6


## The deflect string staged away from the arena centre (effects must appear at the clash, not
## at the world origin).
func shot_deflect_offcenter() -> void:
	_stage(2.4, Vector3(5.0, 0, 3.0))
	auto_guard(0.05, 0.12)
	at(0.4, func(): boss_string(["b_combo_1", "b_combo_2", "b_combo_3"]))
	_end_at = 3.6


## Same string with guard held: dull blocks, player posture climbs.
func shot_block() -> void:
	at(0.1, func(): player.press_guard(Game.clock))
	at(0.4, func(): boss_string(["b_combo_1", "b_combo_2", "b_combo_3"]))
	_end_at = 3.4


func shot_mikiri() -> void:
	_stage(3.2)
	at(0.3, func(): boss_string(["b_thrust"]))
	at(0.3 + 0.74, func(): player.press_action("dodge", Game.clock))      # neutral step on the release
	_end_at = 3.0


func shot_sweep() -> void:
	_stage(2.6)
	at(0.3, func(): boss_string(["b_sweep"]))
	at(0.3 + 0.46, func(): player.press_action("jump", Game.clock))
	at(0.3 + 0.80, func(): player.press_action("jump", Game.clock))
	_end_at = 2.8


## Running away from the sweep as the kanji shows: he slides after you and the spin still
## catches you.
func shot_sweep_flee() -> void:
	_stage(2.6)
	at(0.3, func(): boss_string(["b_sweep"]))
	at(0.4, func():
		player.bot_move = Vector2(0, 1)
		player.press_action("dodge", Game.clock))
	_end_at = 2.2


## Backstepping away from the perilous thrust: he tracks you and the lunge stretches.
func shot_thrust_backstep() -> void:
	_stage(3.2)
	at(0.3, func(): boss_string(["b_thrust"]))
	at(0.3 + 0.64, func():
		player.bot_move = Vector2(0, 1)
		player.press_action("dodge", Game.clock))
	at(0.3 + 0.70, func(): player.release_dodge())
	_end_at = 2.4


func shot_whirl() -> void:
	_stage(2.4)
	auto_guard(0.05, 0.08)
	at(0.3, func(): boss_string(["b_whirl"]))
	_end_at = 3.6


## Any single boss attack from the lock-on camera, the player deflecting each blow:
## `-- attack <clip> [distance]` (to check how an attack reads from where you stand).
func shot_attack() -> void:
	var args := OS.get_cmdline_user_args()
	var clip: String = args[1] if args.size() > 1 else "b_jab"
	_stage(float(args[2]) if args.size() > 2 else 2.4)
	auto_guard(0.05, 0.08)
	at(0.3, func(): boss_string([clip]))
	_end_at = 0.3 + AnimLibrary.get_clip(clip).length + 0.2


func shot_shuriken() -> void:
	_stage(2.6)
	auto_guard(0.06, 0.05)
	at(0.3, func(): boss_string(["b_shuriken_4"]))
	_end_at = 2.7


func shot_shuriken5() -> void:
	_stage(2.6)
	auto_guard(0.06, 0.05)
	at(0.3, func(): boss_string(["b_shuriken_5"]))
	_end_at = 2.6


## He runs at you from across the arena and flows into the running cut.
func shot_charge() -> void:
	_stage(10.0)
	auto_guard(0.05, 0.1)
	at(0.3, func():
		boss.passive = false
		boss._begin_action("charge", 10.0))
	_end_at = 3.2


## Player slash string against a guarding boss.
func shot_slashes() -> void:
	_stage(2.2)
	for k in 8:
		var tt := 0.3 + 0.18 * k
		at(tt, func(): player.press_action("attack", Game.clock))
	_end_at = 2.6


func shot_parried() -> void:
	_stage(2.0)
	boss._parry_threshold = 2
	for k in 10:
		var tt := 0.3 + 0.2 * k
		at(tt, func(): player.press_action("attack", Game.clock))
	_end_at = 3.2


# ------------------------------------------------------------------------- art checks
func _art_camera(radius: float, height: float, look_y: float, speed: float, start := 0.0) -> void:
	var cc := Game.camera as Camera3D
	if cc != null:
		cc.set_process(false)
		cc.set_physics_process(false)
	Game.hud.visible = false
	_orbit_cam = Camera3D.new()
	_orbit_cam.fov = 32.0
	add_child(_orbit_cam)
	_orbit_cam.current = true
	_orbit = {"radius": radius, "height": height, "look_y": look_y, "speed": speed, "start": start}


## The boss idling while the camera circles him (4 s = one turn).
func shot_model() -> void:
	_stage(7.0)
	_art_camera(3.0, 1.55, 1.2, 90.0)
	_end_at = 4.0


## Close orbit around his head.
func shot_model_head() -> void:
	_stage(7.0)
	_art_camera(1.15, 1.95, 1.86, 90.0)
	_end_at = 4.0


## His opening combo from a fixed 3/4 front view.
func shot_model_combo() -> void:
	_stage(3.0)
	_art_camera(3.6, 1.5, 1.2, 0.0, 35.0)
	at(0.3, func(): boss_string(["b_combo_1", "b_combo_2", "b_thrust"]))
	_end_at = 4.2


## His face from about the player's eye height, sweeping from his left to his right.
func shot_model_face() -> void:
	_stage(7.0)
	_art_camera(1.0, 1.70, 1.84, 25.0, -50.0)
	_end_at = 4.0


## Same as model_face, in phase two (brighter aura and glow).
func shot_model_face_p2() -> void:
	_stage(7.0)
	boss._enter_phase_two()
	_art_camera(1.0, 1.70, 1.84, 25.0, -50.0)
	_end_at = 4.0


## His staff plant (the intro / flourish), 3/4 front.
func shot_model_flourish() -> void:
	_stage(4.0)
	_art_camera(4.0, 1.5, 1.2, 0.0, 30.0)
	at(0.3, func():
		boss._seq.clear()
		boss._play_attack("b_intro", 0.0))
	_end_at = 2.3
