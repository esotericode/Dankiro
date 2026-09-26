extends Node
## Scripted capture director for visual checks with Godot's Movie Maker:
##   godot --write-movie out/frame.png --fixed-fps 30 res://tests/capture.tscn -- <shot>
## Shots: overview, deflect, deflect_offcenter, block, mikiri, thrust_backstep, sweep, sweep_flee, whirl, shuriken,
## shuriken5, charge, slashes, parried, inferno [stand|wide], attack <clip> [distance], recovery <clip>, diagnostics, the menus
## (menu_title, menu_options, menu_start, menu_pause), and art checks: model (orbit), model_head, model_face, model_face_p2, model_combo,
## model_flourish.
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
	# Straight into the fight (the menu shots boot to the title menu, like the game), whatever
	# options are saved on this machine.
	process_mode = Node.PROCESS_MODE_ALWAYS       # keep directing while the game is paused
	Game.skip_title = not shot.begins_with("menu") or shot == "menu_pause"
	Game.start_phase = 1
	Game.debug = shot == "diagnostics"
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(main)
	await get_tree().physics_frame
	if shot.begins_with("menu"):
		call("shot_" + shot)
		return
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
	if has_meta("inferno_bot") and boss != null:
		_inferno_bot_tick()
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
	boss._enter_phase(2)
	_art_camera(1.0, 1.70, 1.84, 25.0, -50.0)
	_end_at = 4.0


## The title menu as the game boots (his idle behind it, the camera orbiting slowly).
func shot_menu_title() -> void:
	_end_at = 2.0


## Boot to the title, press Start fight: the menu goes, his intro plays, the fight begins.
func shot_menu_start() -> void:
	at(1.0, func(): (main.get("menu") as GameMenu).start_pressed.emit())
	_end_at = 4.0


## In the fight, Esc: the pause menu over the frozen fight.
func shot_menu_pause() -> void:
	at(1.2, func(): main.call("_toggle_pause"))
	_end_at = 2.2


## The title menu's Options page.
func shot_menu_options() -> void:
	at(0.3, func():
		for b in (main.get("menu") as GameMenu).find_children("*", "Button", true, false):
			if (b as Button).text == "Options":
				(b as Button).pressed.emit())
	_end_at = 1.6


## The diagnostics overlay during an exchange: hurtboxes, lit weapons, the guard ring and
## hit markers, plus the live readout.
func shot_diagnostics() -> void:
	_stage(2.4)
	auto_guard(0.05, 0.12)
	at(0.3, func(): boss_string(["b_combo_1", "b_combo_2", "b_combo_3"]))
	_end_at = 3.4


## One boss attack from a fixed 3/4 front view, played to the very end (no chaining), to look
## at how he recovers into his stance: `-- recovery <clip>`.
func shot_recovery() -> void:
	var args := OS.get_cmdline_user_args()
	var clip: String = args[1] if args.size() > 1 else "b_whirl"
	_stage(3.0)
	_art_camera(4.2, 1.6, 1.25, 0.0, 35.0)
	at(0.3, func(): boss_string([clip]))
	_end_at = 0.3 + AnimLibrary.get_clip(clip).length + 0.5


## Phase 2's fire move (the Inferno) from the lock-on camera: he leaps to the middle, you back
## out of the blast radius while he channels, then jump each arm of fire (the bot jumps 0.3 s
## before an arm reaches it). `-- inferno stand` stands still and gets burned instead;
## `-- inferno wide` films it (jumping) from high above the arena.
func shot_inferno() -> void:
	var args := OS.get_cmdline_user_args()
	var mode: String = args[1] if args.size() > 1 else "jump"
	_stage(7.0, Vector3(0, 0, -4.0))
	boss._enter_phase(2, false)
	at(0.3, func(): boss.begin_inferno())
	set_meta("inferno_bot", "stand" if mode == "stand" else "jump")
	if mode == "wide":
		var cc := Game.camera as Camera3D
		if cc != null:
			cc.set_process(false)
			cc.set_physics_process(false)
		Game.hud.visible = false
		var cam := Camera3D.new()
		cam.fov = 50.0
		add_child(cam)
		cam.current = true
		cam.global_position = Vector3(9.0, 15.0, 17.0)
		cam.look_at(Vector3(0, 0, 0.5), Vector3.UP)
	_end_at = 16.5


var _jumped_for := -1


func _inferno_bot_tick() -> void:
	var inf := boss.inferno
	var to := Combat.flat(player.global_position - inf.center)
	var escaping := boss.state == Boss.S.INFERNO and inf.stage <= Inferno.St.IGNITE and not inf.blast_hit
	player.bot_move = Vector2(0, 1) if escaping and to.length() < Inferno.BLAST_R + 1.5 else Vector2.ZERO
	if str(get_meta("inferno_bot")) == "jump" and inf.stage == Inferno.St.SPIN and inf.passes != _jumped_for:
		if inf.next_pass_in() <= 0.30 and player.state != Player.S.AIR and player.state != Player.S.KNOCKDOWN:
			_jumped_for = inf.passes
			player.press_action("jump", Game.clock)


## His staff plant (the intro / flourish), 3/4 front.
func shot_model_flourish() -> void:
	_stage(4.0)
	_art_camera(4.0, 1.5, 1.2, 0.0, 30.0)
	at(0.3, func():
		boss._seq.clear()
		boss._play_attack("b_intro", 0.0))
	_end_at = 2.3
