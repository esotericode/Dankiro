extends Node3D
## Builds the fight and runs the flow: intro -> fight -> death / victory -> restart.
## Gameplay lives under `World` (pausable); HUD and this node keep running while paused.

enum Flow { INTRO, FIGHT, DEAD, VICTORY }

const PLAYER_START := Vector3(0, 0, 6.5)
const BOSS_START := Vector3(0, 0, -5.0)

var flow: int = Flow.INTRO
var world: Node3D
var arena: Arena
var player: Player
var boss: Boss
var camera: CombatCamera
var hud: Hud
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

	player.died.connect(_on_player_died)
	boss.defeated.connect(_on_boss_defeated)
	boss.life_lost.connect(_on_boss_life_lost)
	Sfx.start_ambience()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_begin_intro()


func _begin_intro() -> void:
	flow = Flow.INTRO
	player.controls_enabled = false
	boss.play_intro()
	hud.show_namecard()
	_intro_timer = 2.4


func _process(delta: float) -> void:
	if flow == Flow.INTRO and not get_tree().paused:
		_intro_timer -= delta
		if _intro_timer <= 0.0:
			flow = Flow.FIGHT
			player.controls_enabled = true
			boss.start_fight()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if flow == Flow.DEAD or flow == Flow.VICTORY:
			return
		_toggle_pause()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("help"):
		hud.toggle_help()
	elif event.is_action_pressed("confirm"):
		if flow == Flow.DEAD or flow == Flow.VICTORY or get_tree().paused:
			get_viewport().set_input_as_handled()
			_restart()


func _toggle_pause() -> void:
	var p := not get_tree().paused
	get_tree().paused = p
	hud.set_panel_visible(p)
	Game.clear_time_effects()
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


func _restart() -> void:
	get_tree().paused = false
	Game.clear_time_effects()
	get_tree().reload_current_scene()
