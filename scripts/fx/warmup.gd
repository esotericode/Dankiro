class_name Warmup
extends Node
## Gets the game ready to run smoothly before you can play. The first time the renderer draws a
## material it has to build GPU pipelines for it (compile its shaders for this machine's driver),
## and doing that mid-fight is a stutter: the first deflect, the first blood, the first Inferno.
## Godot keeps what it built on disk (the shader and pipeline caches in user://), which is why
## it happens on a first launch, or after a driver update, and not after.
##
## So when the game starts, this draws everything the fight can show once, behind a loading
## screen: every kind of spark, blood and a splatter in each texture, dust, fire, the kanji, a
## shuriken, the weapon trails, the gourd, the deathblow mark, the staff ablaze, every part of
## the Inferno and the HUD's overlays. It waits until the renderer has stopped building pipelines
## (RenderingServer's counters), puts it all back as it was, and the loading screen fades over
## the title. Once per launch (quick when the caches are warm), never headless (the lab: nothing
## is drawn there) and not in Movie Maker captures unless they ask (Game.warmup).
##
## A new effect has to be added to its class's warm_up (Fx, FireFx, Boss, Player, Inferno,
## StaffFire, WeaponTrail, Hud), or its first appearance will stutter. The capture shot
## `stutter` measures it (see CLAUDE.md).

const MIN_FRAMES := 12          ## at least this many frames with everything shown...
const SETTLE_FRAMES := 8        ## ...and this many in a row with no pipeline built, the background ones too
const MIN_SECONDS := 0.5        ## (no flash of black on a fast machine)
## Enough is enough, even if something keeps building: this many frames, or seconds after the
## first frame (that one compiles everything in view, which on a first launch takes a while).
const MAX_FRAMES := 900
const MAX_SECONDS := 60.0

var screen: LoadingScreen
var frames := 0
var seconds := 0.0
var built := 0                  ## pipelines the renderer built meanwhile


## Whether to warm up: once per launch, and only where something is drawn.
static func wanted() -> bool:
	return Game.warmup and not Game.warmed_up and DisplayServer.get_name() != "headless"


## Pipelines the renderer has built so far, whatever for (they only ever go up).
static func pipelines() -> int:
	var n := 0
	for info in [RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS,
			RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH,
			RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE,
			RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW,
			RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION]:
		n += RenderingServer.get_rendering_info(info)
	return n


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	screen = LoadingScreen.new()        # up from the first frame
	add_child(screen)


## Draws it all under the loading screen and waits for the renderer, then clears it away. Returns
## with the screen still up: finish() fades it once the title (or the fight) is under it.
func run(main: Node) -> void:
	var tree := get_tree()
	var t0 := Time.get_ticks_msec()
	var p0 := pipelines()
	var world: Node3D = main.get("world")
	var player: Player = main.get("player")
	var boss: Boss = main.get("boss")
	var hud: Hud = main.get("hud")
	var cam: Camera3D = (main.get("camera") as CombatCamera).cam
	player.controls_enabled = false
	cam.current = true
	Music.preload_tracks()
	for i in 3:                                    # (the lock-on camera settles behind you)
		await tree.process_frame
	var view := cam.global_transform
	var ahead := -view.basis.z
	var at := view.origin + ahead * 3.2
	var floor_at := view.origin + Combat.flat(ahead).normalized() * 6.0
	floor_at.y = 0.0
	var root := Node3D.new()
	root.name = "Warmup"
	world.add_child(root)
	Fx.warm_up(root, at, floor_at, null)
	FireFx.warm_up(root, at + view.basis.x * 0.8)
	var star := Shuriken.new()
	root.add_child(star)
	star.global_position = at - view.basis.x * 0.6
	boss.warm_up(true, root, at)
	player.warm_up(true, at + view.basis.x * 0.3)
	hud.warm_up(true)
	var last := pipelines()
	var still := 0
	var t1 := 0
	while true:
		await tree.process_frame
		frames += 1
		if frames == 1:
			t1 = Time.get_ticks_msec()
		if frames % 3 == 0:                        # (a trail fades in a fraction of a second)
			player.trail.warm_up(at + view.basis.x * 0.3)
			for t in boss.trails:
				(t as WeaponTrail).warm_up(at)
		var now := pipelines()
		still = still + 1 if now == last else 0
		last = now
		seconds = (Time.get_ticks_msec() - t0) / 1000.0
		screen.set_progress(0.9 * (1.0 - exp(-float(frames) / 30.0)))
		if frames >= MIN_FRAMES and still >= SETTLE_FRAMES and seconds >= MIN_SECONDS:
			break
		if frames >= MAX_FRAMES or Time.get_ticks_msec() - t1 > MAX_SECONDS * 1000.0:
			break
	boss.warm_up(false, root, at)
	player.warm_up(false, at)
	hud.warm_up(false)
	root.queue_free()
	built = pipelines() - p0
	Game.warmed_up = true
	print("Warm-up: every effect drawn once; the renderer built %d pipelines in %.1f s (%d frames)." % [
		built, seconds, frames])


## The title (or the fight) is under the loading screen now: it draws there for a couple of
## frames (its own first-frame work, unseen), then the screen fades away and this goes.
func finish() -> void:
	for i in 2:
		await get_tree().process_frame
	screen.finish()
	await screen.tree_exited
	queue_free()
