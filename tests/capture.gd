extends Node
## Scripted capture director for visual checks with Godot's Movie Maker:
##   godot --write-movie out/frame.png --fixed-fps 30 res://tests/capture.tscn -- <shot>
## Shots: overview, deflect, deflect_offcenter, block, mikiri, thrust_backstep, sweep, sweep_flee, whirl, shuriken,
## shuriken5, charge, slashes, parried, deathblow [final], edge, inferno [stand|wide|spin|plunge|plunge_stand], attack <clip> [distance], recovery <clip>, diagnostics, the menus
## (menu_title, menu_options, menu_controls, menu_start, menu_pause, help), and art checks: model (orbit), model_head, model_face, model_face_p2, model_combo,
## model_flourish, player_model, player_head, player_face, player_moves, fire_staff [level], fire_combo, floor [overview|centre|medallion|puddle|moss|broken|rim|low|sweep],
## scenery [torii|gate|south|east|west|high|lantern].
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
var _orbit_on: Combatant           ## who the art camera orbits (the boss unless a shot says)


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
	# The music at its default volume (not this machine's), or DANKIRO_MUSIC=<0..1>.
	var music := OS.get_environment("DANKIRO_MUSIC")
	Game.save_enabled = false
	Game.music_volume = clampf(float(music), 0.0, 1.0) if music != "" else Game.DEFAULT_MUSIC_VOLUME
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(main)
	var flat := OS.get_environment("DANKIRO_FLAT")
	if flat != "":
		_flat_background(flat)
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


## UI work: with DANKIRO_FLAT=<png> the 3D world isn't drawn; that still picture of it (a
## plate, see shot_plate_fight / shot_menu_plate) stands behind the live UI instead, so a frame
## takes a moment instead of 20 s at 1920x1080.
func _flat_background(path: String) -> void:
	get_viewport().disable_3d = true
	var img := Image.load_from_file(path)
	var layer := CanvasLayer.new()
	layer.layer = -100
	var tr := TextureRect.new()
	tr.texture = ImageTexture.create_from_image(img)
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(tr)
	add_child(layer)


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
		var subject: Combatant = _orbit_on if _orbit_on != null else boss
		var a := deg_to_rad(float(_orbit["start"]) + t * float(_orbit["speed"]))
		var c := subject.global_position
		var fwd := subject.forward()
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
## `-- attack <clip> [distance] [circle]` (to check how an attack reads from where you stand;
## `circle`: locked on, you walk round him from the moment he starts and don't guard, to see
## whether it still lands on you).
func shot_attack() -> void:
	var args := OS.get_cmdline_user_args()
	var clip: String = args[1] if args.size() > 1 else "b_jab"
	_stage(float(args[2]) if args.size() > 2 else 2.4)
	var circle := args.size() > 3 and args[3] == "circle"
	if not circle:
		auto_guard(0.05, 0.08)
	at(0.3, func(): boss_string([clip]))
	if circle:
		at(0.3, func():
			player.locked = true
			player.bot_move = Vector2(1, 0))
	_end_at = 0.3 + AnimLibrary.get_clip(clip).length + 0.2


## His shuriken volley, 3 in the air + 1 delayed, every one deflected. `-- shuriken double`: the
## phase-two volley, two sets, the second thrown from the ground straight after the first.
func shot_shuriken() -> void:
	var args := OS.get_cmdline_user_args()
	var double := args.size() > 1 and args[1] == "double"
	_stage(2.6)
	auto_guard(0.06, 0.05)
	at(0.3, func(): boss_string(["b_shuriken_4x2" if double else "b_shuriken_4"]))
	_end_at = 4.0 if double else 2.7


## The same with 5 in the air (`-- shuriken5 double`: then 5 more from the ground).
func shot_shuriken5() -> void:
	var args := OS.get_cmdline_user_args()
	var double := args.size() > 1 and args[1] == "double"
	_stage(2.6)
	auto_guard(0.06, 0.05)
	at(0.3, func(): boss_string(["b_shuriken_5x2" if double else "b_shuriken_5"]))
	_end_at = 3.6 if double else 2.6


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


## Posture break and deathblow: his posture all but full, deflecting his cut breaks it, and the
## player executes him (the camera's deathblow shot, blood, 忍殺). `-- deathblow final` makes it
## his last life: he falls, then the victory screen, the fade to black and "Thanks for Playing".
func shot_deathblow() -> void:
	var final := OS.get_cmdline_user_args().has("final")
	if final:
		boss.lives_left = 1
	auto_guard(0.05, 0.12)
	at(0.2, func(): boss.add_posture(boss.max_posture - 5.0, false))
	at(0.4, func(): boss_string(["b_combo_1"]))
	for k in 24:
		at(1.0 + 0.15 * k, func():
			if boss.is_deathblow_ready() and player.distance_to_opponent() < 3.0:
				player.press_action("attack", Game.clock))
	_end_at = 15.5 if final else 5.6


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


## The plaza floor from fixed cameras, fighters out of the way:
## `-- floor [overview|centre|medallion|puddle|moss|broken|rim|low|sweep]` (sweep: a slow low pass, 6 s).
func shot_floor() -> void:
	var args := OS.get_cmdline_user_args()
	var view: String = args[1] if args.size() > 1 else "overview"
	_stage(3.0, Vector3(1.5, 0, 10.5))
	var views := {
		"overview": [Vector3(0, 12.5, 16.5), Vector3(0, 0, -1.5), 55.0],
		"centre": [Vector3(0.5, 2.1, 3.0), Vector3(0, 0, -0.2), 50.0],
		"medallion": [Vector3(0.7, 1.05, 1.75), Vector3(0, 0, -0.1), 50.0],
		"puddle": [Vector3(-1.7, 1.55, -3.9), Vector3(-3.9, 0, -8.4), 55.0],
		"moss": [Vector3(5.6, 1.45, -6.6), Vector3(7.5, 0, -9.6), 55.0],
		"broken": [Vector3(-9.4, 1.4, -2.4), Vector3(-11.7, 0, -4.4), 55.0],
		"rim": [Vector3(2.0, 1.6, -9.5), Vector3(5.5, 0.3, -13.3), 60.0],
		"low": [Vector3(0.0, 0.55, 7.5), Vector3(0, 0.25, -6.0), 60.0],
		"sweep": [Vector3(-6.0, 1.3, 2.0), Vector3(-4.0, 0, -8.0), 60.0],
	}
	var v: Array = views.get(view, views["overview"])
	var cc := Game.camera as Camera3D
	if cc != null:
		cc.set_process(false)
		cc.set_physics_process(false)
	Game.hud.visible = false
	var cam := Camera3D.new()
	cam.fov = float(v[2])
	add_child(cam)
	cam.current = true
	cam.global_position = v[0]
	cam.look_at(v[1], Vector3.UP)
	_end_at = 0.4
	if view == "sweep":
		_end_at = 6.0
		var from: Vector3 = v[0]
		var look: Vector3 = v[1]
		var tw := create_tween()
		tw.tween_method(func(k: float):
			cam.global_position = from + Vector3(9.0 * k, 0.0, -2.0 * k)
			cam.look_at(look + Vector3(9.0 * k, 0.0, 0.0), Vector3.UP), 0.0, 1.0, 6.0)


## The world round the plaza from fixed cameras, the fighters out of the way:
## `-- scenery [torii|gate|south|east|west|high|lantern]`.
func shot_scenery() -> void:
	var args := OS.get_cmdline_user_args()
	var view: String = args[1] if args.size() > 1 else "torii"
	_stage(3.0, Vector3(3.0, 0, 11.0))
	var views := {
		"torii": [Vector3(0, 1.8, 9.0), Vector3(0, 4.5, -30.0), 60.0],
		"gate": [Vector3(1.5, 2.2, -11.5), Vector3(0, 4.5, -30.0), 60.0],
		"south": [Vector3(0, 1.8, -9.0), Vector3(0, 5.0, 40.0), 60.0],
		"east": [Vector3(-8.0, 1.8, 0.0), Vector3(40.0, 6.0, 0.0), 60.0],
		"west": [Vector3(8.0, 1.8, 0.0), Vector3(-40.0, 6.0, 0.0), 60.0],
		"high": [Vector3(0, 30.0, 36.0), Vector3(0, 0, -12.0), 55.0],
		"lantern": [Vector3(4.2, 1.5, -10.4), Vector3(5.55, 0.8, -13.4), 50.0],
		"vista": [Vector3(12.5, 2.4, -2.0), Vector3(80.0, -4.0, 8.0), 60.0],
		"north": [Vector3(-3.0, 2.0, 12.0), Vector3(2.0, 9.0, -60.0), 60.0],
		"cliff": [Vector3(13.0, 4.5, -14.0), Vector3(24.0, -6.0, 6.0), 60.0],
		"grove": [Vector3(-9.0, 2.2, 9.5), Vector3(-19.0, 5.0, 19.0), 55.0],
		"shrine": [Vector3(5.0, 4.4, -32.0), Vector3(0.0, 5.0, -41.5), 55.0],
	}
	var v: Array = views.get(view, views["torii"])
	var cc := Game.camera as Camera3D
	if cc != null:
		cc.set_process(false)
		cc.set_physics_process(false)
	Game.hud.visible = false
	var cam := Camera3D.new()
	cam.fov = float(v[2])
	add_child(cam)
	cam.current = true
	cam.global_position = v[0]
	cam.look_at(v[1], Vector3.UP)
	_end_at = 0.4


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


## The shinobi (tools/build_player_model.py): an orbit round him in his stance.
func shot_player_model() -> void:
	_stage(6.0)
	_orbit_on = player
	_art_camera(2.7, 1.3, 1.0, 90.0)
	_end_at = 4.0


## Close orbit round the shinobi's head.
func shot_player_head() -> void:
	_stage(6.0)
	_orbit_on = player
	_art_camera(0.95, 1.64, 1.6, 90.0)
	_end_at = 4.0


## The shinobi's face from the front, sweeping from his left to his right.
func shot_player_face() -> void:
	_stage(6.0)
	_orbit_on = player
	_art_camera(0.8, 1.62, 1.61, 25.0, -50.0)
	_end_at = 4.0


## The shinobi moving, from a fixed 3/4 front view: his slash string, a step back, a jump and
## a drink from the gourd.
func shot_player_moves() -> void:
	_stage(6.0)
	_orbit_on = player
	_art_camera(3.6, 1.35, 1.0, 0.0, 35.0)
	player.hp = player.max_hp * 0.5
	for k in 3:
		var tt := 0.3 + 0.42 * k
		at(tt, func(): player.press_action("attack", Game.clock))
	at(1.9, func():
		player.bot_move = Vector2(0, 1)
		player.press_action("dodge", Game.clock))
	at(1.96, func(): player.release_dodge())
	at(2.2, func(): player.bot_move = Vector2.ZERO)
	at(2.6, func(): player.press_action("jump", Game.clock))
	at(3.7, func(): player.press_action("heal", Game.clock))
	_end_at = 5.4


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


## The title menu's Controls page.
func shot_menu_controls() -> void:
	at(0.3, func():
		for b in (main.get("menu") as GameMenu).find_children("*", "Button", true, false):
			if (b as Button).text == "Controls":
				(b as Button).pressed.emit())
	_end_at = 1.6


## The title menu's Lore page: the Chronicle of the Dried Root, in type too small to read.
func shot_menu_lore() -> void:
	at(0.3, func():
		for b in (main.get("menu") as GameMenu).find_children("*", "Button", true, false):
			if (b as Button).text == "Lore":
				(b as Button).pressed.emit())
	_end_at = 1.6


## UI work: the fight from the lock-on camera with the HUD hidden (a plate for DANKIRO_FLAT).
## The fighters stand as in shot_ui_hud.
func shot_plate_fight() -> void:
	_stage(3.0)
	Game.hud.visible = false
	_end_at = 0.6


## UI work: the title screen without the menu (a plate for DANKIRO_FLAT).
func shot_menu_plate() -> void:
	at(0.1, func(): (main.get("menu") as GameMenu).visible = false)
	_end_at = 1.1


## The fight's HUD with both fighters hurt, his posture building and one gourd left.
func shot_ui_hud() -> void:
	_stage(3.0)
	at(0.2, func():
		player.hp = player.max_hp * 0.55
		boss.hp = boss.max_hp * 0.7
		player.heal_charges = 1
		player.heal_charges_changed.emit(1)
		player.add_posture(player.max_posture * 0.45, false)
		boss.add_posture(boss.max_posture * 0.6, false))
	_end_at = 1.4


## The HUD as the fight starts: full bars, three gourds, no posture.
func shot_ui_hud_fresh() -> void:
	_stage(3.0)
	_end_at = 0.6


## The HUD with his posture nearly broken and the gourd empty.
func shot_ui_hud_low() -> void:
	_stage(3.0)
	at(0.2, func():
		player.hp = player.max_hp * 0.2
		boss.hp = boss.max_hp * 0.35
		boss.lives_left = 2
		player.heal_charges = 0
		player.heal_charges_changed.emit(0)
		player.add_posture(player.max_posture * 0.8, false)
		boss.add_posture(boss.max_posture * 0.93, false))
	_end_at = 1.4


## The ribbons and his mane in motion (SpringChain), from the lock-on camera: you strafe round
## him, stop, dodge back, then he runs his combo while you deflect. `-- ribbons close` follows
## you from behind, close (your scarf and headband tails); `-- ribbons boss` watches him from
## behind (his mane and sashes).
func shot_ribbons() -> void:
	var args := OS.get_cmdline_user_args()
	var view: String = args[1] if args.size() > 1 else ""
	_stage(3.0)
	if view == "close":
		_orbit_on = player
		_art_camera(2.3, 1.5, 1.2, 0.0, 205.0)
	elif view == "boss":
		# straight to his combo (his mane and sashes), you deflecting
		_orbit_on = boss
		_art_camera(3.4, 1.9, 1.5, 0.0, 150.0)
		auto_guard(0.05, 0.12)
		at(0.6, func(): boss_string(["b_combo_1", "b_combo_2", "b_combo_3"]))
		_end_at = float(args[2]) if args.size() > 2 else 3.8
		return
	auto_guard(0.05, 0.12)
	at(0.2, func(): player.bot_move = Vector2(1, 0))
	at(1.5, func(): player.bot_move = Vector2.ZERO)
	at(2.0, func(): player.press_action("dodge", Game.clock))
	at(2.9, func(): boss_string(["b_combo_1", "b_combo_2", "b_combo_3"]))
	_end_at = float(args[2]) if args.size() > 2 else 6.2


## UI work: one of the HUD's moments over the fight, `-- ui_moment <what>`: namecard (as the fight
## begins), callout (MIKIRI COUNTER), deathblow (his posture broken: the red mark and the
## prompt), execution (忍殺), death, victory, end (the end screen: the fade to black and "Thanks
## for Playing") or help (F1).
func shot_ui_moment() -> void:
	var args := OS.get_cmdline_user_args()
	var what: String = args[1] if args.size() > 1 else "namecard"
	_stage(3.0)
	_end_at = 1.6
	match what:
		"namecard":
			at(0.1, func():
				(Game.hud.get("_namecard") as Control).visible = true
				Game.hud.call("show_namecard"))
			_end_at = 3.4
		"callout":
			at(0.1, func(): Game.hud.call("show_callout", "Mikiri counter"))
			_end_at = 1.4
		"deathblow":
			at(0.1, func():
				player.global_position = boss.global_position + Vector3(0, 0, 2.0)
				player.locked = true
				boss._posture_break())
		"execution":
			at(0.1, func(): Game.hud.call("show_execution"))
		"death":
			at(0.1, func(): Game.hud.call("show_death"))
			_end_at = 2.2
		"victory":
			at(0.1, func(): Game.hud.call("show_victory"))
			_end_at = 2.2
		"end":
			at(0.1, func(): Game.hud.call("show_end"))
			_end_at = 5.6
		"help":
			at(0.1, func(): Game.hud.set_panel_visible(true))
			_end_at = 0.8


## The lock-on camera with your back to the fence, at eight places round the rim, a second each:
## it keeps its distance, swinging out over the fence (the fighters' wall doesn't stop it).
func shot_edge() -> void:
	_stage(6.0)
	var rim: float = (main.get("arena") as Arena).radius
	for k in 8:
		var a := TAU * float(k) / 8.0 + 0.2
		at(0.2 + 1.0 * k, func():
			boss.global_position = Vector3.ZERO
			player.global_position = Combat.dir_of(a) * (rim - 0.7)
			player.face_now(boss.global_position)
			player.locked = true)
	_end_at = 8.2


## In the fight, F1: the controls sheet over the fight.
func shot_help() -> void:
	_stage(3.0)
	at(0.1, func(): Game.hud.set_panel_visible(true))
	_end_at = 0.8


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


## A pummeling: he's reeling (the recoil from a deflected final blow) and you keep hitting him;
## after a few hits he escapes. `-- pummel [phase] [seed] [escape]`: the seed picks which way
## out he takes, or name one (evade, shuriken, retreat, sidestep, sweep, parry) to force it.
func shot_pummel() -> void:
	var args := OS.get_cmdline_user_args()
	var ph := int(args[1]) if args.size() > 1 else 1
	seed(int(args[2]) if args.size() > 2 else 1)
	var force: String = args[3] if args.size() > 3 else ""
	_stage(2.2)
	if ph > 1:
		boss._enter_phase(ph, false)
	if force != "":
		boss.set_meta("force_escape", force)
	player.max_hp = 1.0e6
	player.hp = player.max_hp
	auto_guard(0.06, 0.05)
	at(0.3, func():
		boss.passive = false
		boss._react("b_recoil"))
	for k in 22:
		var tk := 0.34 + 0.12 * k
		at(tk, func():
			if boss.distance_to_opponent() < 2.8 and boss.escape_count == 0:
				player.press_action("attack", Game.clock))
	_end_at = 4.6


## He runs round you to a new spot (the reposition move) and opens from there, seen from the
## lock-on camera (`-- reposition wide`: from high above, so you see his path).
func shot_reposition() -> void:
	var args := OS.get_cmdline_user_args()
	var mode: String = args[1] if args.size() > 1 else ""
	_stage(2.4)
	if mode == "wide":
		# a fixed camera high above you, looking down on the plaza round you
		var cc := Game.camera as Camera3D
		if cc != null:
			cc.set_process(false)
			cc.set_physics_process(false)
		Game.hud.visible = false
		var cam := Camera3D.new()
		cam.fov = 50.0
		add_child(cam)
		cam.current = true
		var c := player.global_position
		cam.global_position = c + Vector3(0.0, 15.0, 8.0)
		cam.look_at(c + Vector3(0.0, 0.0, -1.0), Vector3.UP)
	auto_guard(0.06, 0.05)
	at(0.4, func():
		boss.passive = false
		boss.cooldown = 99.0
		boss._begin_action("reposition", boss.distance_to_opponent()))
	_end_at = 4.2


## Phase 3's Tempest of Fangs from the lock-on camera, every blow deflected (`-- tempest side`:
## from a fixed 3/4 view beside the two of you; `-- tempest hold`: holding guard, which breaks on
## the last blow).
func shot_tempest() -> void:
	var args := OS.get_cmdline_user_args()
	var mode: String = args[1] if args.size() > 1 else ""
	_stage(2.6)
	boss._enter_phase(3, false)
	if mode == "side":
		_art_camera(4.6, 1.6, 1.3, 0.0, 40.0)
	if mode == "hold":
		at(0.1, func(): player.press_guard(Game.clock))
	else:
		auto_guard(0.06, 0.05)
	at(0.3, func(): boss_string(["b_tempest"]))
	_end_at = 0.3 + AnimLibrary.get_clip("b_tempest").length + 0.4


## Phase 2's fire move (the Inferno) from the lock-on camera: he leaps to the middle, you back
## out of the blast radius while he channels, then jump each arm of fire and the eruption at
## the end (the bot jumps 0.28 s before each). `-- inferno stand` stands still and gets burned instead;
## `-- inferno wide` films it (jumping) from high above the arena.
func shot_inferno() -> void:
	var args := OS.get_cmdline_user_args()
	var mode: String = args[1] if args.size() > 1 else "jump"
	var p3 := args.has("p3")          # phase 3: waves of fire between the arms
	_stage(7.0, Vector3(0, 0, -4.0))
	boss._enter_phase(3 if p3 else 2, false)
	if mode == "spin":
		# straight to the turn (the arms of fire and the ring round him), for looking at the fire
		at(0.3, func():
			boss.global_position = Vector3.ZERO
			player.global_position = Vector3(0, 0, 7.0)
			boss.begin_inferno()
			boss.staff_fire.set_level(1.0, 10.0)
			boss.inferno.on_event("fire_whips", {})
			boss.inferno._begin_spin())
		set_meta("inferno_bot", "jump")
		_end_at = 6.6 if p3 else 4.5
		return
	if mode.begins_with("plunge"):
		# straight to the finisher, for looking at the eruption: he's already in the middle
		at(0.3, func():
			boss.global_position = Vector3.ZERO
			player.global_position = Vector3(0, 0, 7.0)
			boss.begin_inferno()
			boss.staff_fire.set_level(1.0, 10.0)
			boss.inferno._ring_target = 1.0         # his ring of fire, still up from the spin
			boss.inferno._ring_level = 1.0
			boss.inferno._begin_plunge())
		set_meta("inferno_bot", "stand" if mode == "plunge_stand" else "jump")
		_end_at = 3.5
		return
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
	# one jump per arm and wave, and one for the eruption
	var key := inf.passes + inf.waves_passed if inf.stage == Inferno.St.SPIN else 100
	if str(get_meta("inferno_bot")) == "jump" and key != _jumped_for and inf.next_jump_in() <= 0.28:
		if player.state != Player.S.AIR and player.state != Player.S.KNOCKDOWN:
			_jumped_for = key
			player.press_action("jump", Game.clock)


## The fire on his staff, from a slow orbit: `-- fire_staff [level]` (0.3 = smouldering, as in
## his normal fighting from phase 2 on; 1 = ablaze, as in the Inferno).
func shot_fire_staff() -> void:
	var args := OS.get_cmdline_user_args()
	var level: float = float(args[1]) if args.size() > 1 else StaffFire.SMOULDER
	_stage(7.0)
	boss._enter_phase(2, false)
	boss.staff_fire.set_level(level, 50.0)
	_art_camera(3.4, 1.5, 1.25, 45.0, 30.0)
	_end_at = 3.0


## Phase three (staff smouldering): his opening combo from a fixed 3/4 view, to check the
## strikes still read with the fire on.
func shot_fire_combo() -> void:
	_stage(3.0)
	boss._enter_phase(3, false)
	_art_camera(4.2, 1.6, 1.15, 0.0, 35.0)
	at(0.4, func(): boss_string(["b_combo_1", "b_combo_2", "b_thrust"]))
	_end_at = 4.2


## His staff plant (the intro / flourish), 3/4 front.
func shot_model_flourish() -> void:
	_stage(4.0)
	_art_camera(4.0, 1.5, 1.2, 0.0, 30.0)
	at(0.3, func():
		boss._seq.clear()
		boss._play_attack("b_intro", 0.0))
	_end_at = 2.3
