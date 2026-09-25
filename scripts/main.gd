extends Node3D
## Builds the fight and runs the flow: title menu -> intro -> fight -> death / victory ->
## retry (straight back into the fight) or the title menu.
## Gameplay lives under `World` (pausable); HUD, menu and this node keep running while paused.

enum Flow { INTRO, FIGHT, DEAD, VICTORY, TITLE }

const PLAYER_START := Vector3(0, 0, 6.5)
const BOSS_START := Vector3(0, 0, -5.0)

var flow: int = Flow.INTRO
var world: Node3D
var arena: Arena
var player: Player
var boss: Boss
var camera: CombatCamera
var hud: Hud
var menu: GameMenu
var diagnostics: Diagnostics
var _title_cam: Camera3D
var _title_time := 0.0
var _intro_timer := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Game.clear_time_effects()
	world = Node3D.new()
	world.name = "World"
	world.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(world)

	arena = Arena.new()
	arena.name = "Arena"
	world.add_child(arena)

	# Positions are set before entering the tree so the bodies never spawn overlapping.
	player = Player.new()
	player.name = "Player"
	player.position = PLAYER_START
	world.add_child(player)
	player.set_facing(0.0)

	boss = Boss.new()
	boss.name = "Boss"
	boss.position = BOSS_START
	world.add_child(boss)
	boss.set_facing(PI)

	player.opponent = boss
	player.lock_target = boss
	boss.opponent = player
	Game.player = player
	Game.boss = boss

	camera = CombatCamera.new()
	camera.name = "Camera"
	world.add_child(camera)
	camera.setup(player, boss)

	hud = Hud.new()
	hud.name = "HUD"
	add_child(hud)
	hud.bind(player, boss)

	diagnostics = Diagnostics.new()
	diagnostics.name = "Diagnostics"
	add_child(diagnostics)
	diagnostics.bind(player, boss)

	menu = GameMenu.new()
	menu.name = "Menu"
	add_child(menu)
	menu.start_pressed.connect(_start_fight)
	menu.resume_pressed.connect(_toggle_pause)
	menu.restart_pressed.connect(_restart)
	menu.title_pressed.connect(_to_title)
	menu.quit_pressed.connect(func(): get_tree().quit())

	player.died.connect(_on_player_died)
	boss.defeated.connect(_on_boss_defeated)
	boss.life_lost.connect(_on_boss_life_lost)
	Sfx.start_ambience()
	if Game.skip_title:
		Game.skip_title = false
		_start_fight()
	else:
		_show_title()


## The title menu, over a slow orbit around him while he waits.
func _show_title() -> void:
	flow = Flow.TITLE
	player.controls_enabled = false
	hud.visible = false
	_title_cam = Camera3D.new()
	_title_cam.fov = 42.0
	add_child(_title_cam)
	_title_cam.current = true
	_update_title_camera(0.0)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	menu.open_title()


func _update_title_camera(delta: float) -> void:
	_title_time += delta
	# In front of him (he faces you), swaying slowly from side to side.
	var a := boss.facing + 0.35 + 0.4 * sin(_title_time * 0.12)
	var c := boss.global_position
	_title_cam.global_position = c + Combat.dir_of(a) * 5.4 + Vector3(0, 1.7, 0)
	_title_cam.look_at(c + Vector3(0, 1.4, 0), Vector3.UP)
	_title_cam.rotate_object_local(Vector3.UP, 0.24)   # frame him right of centre, clear of the menu


func _start_fight() -> void:
	menu.close()
	hud.visible = true
	if _title_cam != null:
		_title_cam.queue_free()
		_title_cam = null
	camera.cam.current = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	boss.set_start_phase(Game.start_phase)
	_begin_intro()


func _begin_intro() -> void:
	flow = Flow.INTRO
	player.controls_enabled = false
	boss.play_intro()
	hud.show_namecard()
	_intro_timer = 2.4


func _process(delta: float) -> void:
	if flow == Flow.TITLE and _title_cam != null:
		_update_title_camera(delta)
	if flow == Flow.INTRO and not get_tree().paused:
		_intro_timer -= delta
		if _intro_timer <= 0.0:
			flow = Flow.FIGHT
			player.controls_enabled = true
			boss.start_fight()


func _unhandled_input(event: InputEvent) -> void:
	if menu.is_open():
		# Esc / (B) / Start: back out of Options or Controls; on the pause menu, resume.
		if event.is_action_pressed("ui_cancel") or event.is_action_pressed("pause"):
			get_viewport().set_input_as_handled()
			if not menu.back() and get_tree().paused:
				_toggle_pause()
		return
	if event.is_action_pressed("pause"):
		get_viewport().set_input_as_handled()
		if flow == Flow.DEAD or flow == Flow.VICTORY:
			_to_title()
		elif flow == Flow.FIGHT or flow == Flow.INTRO:
			_toggle_pause()
	elif event.is_action_pressed("help"):
		hud.toggle_help()
	elif event.is_action_pressed("confirm"):
		if flow == Flow.DEAD or flow == Flow.VICTORY:
			get_viewport().set_input_as_handled()
			_restart()


func _toggle_pause() -> void:
	var p := not get_tree().paused
	get_tree().paused = p
	Game.clear_time_effects()
	if p:
		hud.set_panel_visible(false)
		menu.open_pause()
	else:
		menu.close()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if p else Input.MOUSE_MODE_CAPTURED


func _on_player_died() -> void:
	flow = Flow.DEAD
	boss.set_passive(true)
	hud.show_death()


func _on_boss_life_lost(lives_left: int) -> void:
	if lives_left > 0:
		hud.show_callout("SHINOBI EXECUTION")


func _on_boss_defeated() -> void:
	flow = Flow.VICTORY
	player.controls_enabled = false
	player.locked = false
	Sfx.play_ui("victory", 0.0)
	hud.show_victory()


## Straight back into the fight (same options), skipping the title menu.
func _restart() -> void:
	Game.skip_title = true
	get_tree().paused = false
	Game.clear_time_effects()
	get_tree().reload_current_scene()


func _to_title() -> void:
	Game.skip_title = false
	get_tree().paused = false
	Game.clear_time_effects()
	get_tree().reload_current_scene()
