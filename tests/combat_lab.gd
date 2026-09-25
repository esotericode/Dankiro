extends Node3D
## Headless combat lab: spawns the fighters, drives the player with scripted inputs at exact
## game times (through the same press_guard / press_action entry points the controller uses),
## forces boss attacks and checks the outcomes against docs/SEKIRO_MECHANICS.md.
##
## Run (from the project folder):
##   godot --headless --fixed-fps 120 res://tests/combat_lab.tscn -- [suite ...] [--verbose]
## Suites: reach, tells, deflect, flurry, punish, loop, spam, mikiri, dodge, sweep, shuriken, attack, cancel, soak (default: all).
## Exit code 0 when every check passes, including "no engine or script errors during the run".

const DT := 1.0 / 120.0

var world: Node3D
var player: Player
var boss: Boss
var verbose := false
var failures: Array[String] = []
var checks := 0

var _sched: Array = []          ## [game time, Callable]
var _results: Array = []        ## hit_resolved records for the current scenario
var _errors := ErrorLog.new()


## Collects engine and script errors (not warnings) raised while the lab runs, so a run that
## hits any runtime error fails even if every gameplay check passes.
class ErrorLog extends Logger:
	var lines: Array[String] = []
	var _mutex := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		_mutex.lock()
		lines.append("%s:%d %s: %s" % [file.get_file(), line, function, rationale if rationale != "" else code])
		_mutex.unlock()

	func count() -> int:
		_mutex.lock()
		var n := lines.size()
		_mutex.unlock()
		return n


func _ready() -> void:
	OS.add_logger(_errors)
	process_physics_priority = -500   # after Game's clock tick, before the fighters
	Game.deterministic = true
	Game.time_effects_enabled = false
	var args := OS.get_cmdline_user_args()
	verbose = args.has("--verbose")
	var suites: Array = []
	for a in args:
		if not a.begins_with("--"):
			suites.append(a)
	if suites.is_empty():
		suites = ["reach", "tells", "deflect", "flurry", "punish", "loop", "spam", "mikiri", "dodge", "sweep", "shuriken", "attack", "cancel", "soak"]
	await get_tree().physics_frame
	for s in suites:
		print("\n=== suite: %s ===" % s)
		await call("suite_" + s)
	var errs := _errors.lines.duplicate()
	check(errs.is_empty(), "no engine or script errors during the run (%d)%s" % [errs.size(),
		"" if errs.is_empty() else ": " + " | ".join(errs.slice(0, 5))])
	OS.remove_logger(_errors)
	print("\n%d checks, %d failures" % [checks, failures.size()])
	for f in failures:
		print("  FAIL: " + f)
	get_tree().quit(1 if failures.size() > 0 else 0)


# ---------------------------------------------------------------------------- plumbing
func _physics_process(_delta: float) -> void:
	var due: Array = []
	for item in _sched:
		if Game.clock >= float(item[0]) - 1e-6:
			due.append(item)
	for item in due:
		_sched.erase(item)
		(item[1] as Callable).call()


func at(t: float, fn: Callable) -> void:
	_sched.append([t, fn])


func ticks(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures.append(what)
		print("  FAIL " + what)
	elif verbose:
		print("  ok   " + what)


## Fresh fighters. The player stands `dist` m from the boss at `angle_deg` off his facing.
func setup(dist: float, angle_deg := 0.0) -> void:
	_sched.clear()
	_results.clear()
	Game.clear_time_effects()
	if world != null:
		world.queue_free()
		await get_tree().process_frame
	world = Node3D.new()
	add_child(world)
	var floor_body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80, 2, 80)
	cs.shape = box
	cs.position = Vector3(0, -1, 0)
	floor_body.add_child(cs)
	world.add_child(floor_body)
	# Positions are set before entering the tree so the bodies never spawn overlapping.
	boss = Boss.new()
	boss.position = Vector3.ZERO
	world.add_child(boss)
	boss.set_facing(0.0)                      # facing -Z
	boss.passive = true
	boss.state = Boss.S.NEUTRAL
	player = Player.new()
	player.position = Combat.dir_of(deg_to_rad(angle_deg)) * dist
	world.add_child(player)
	player.face_now(boss.global_position)
	player.camera_yaw = player.facing       # as the lock-on camera would: looking at the boss
	player.opponent = boss
	player.lock_target = boss
	player.bot_enabled = true
	player.max_hp = 1.0e6
	player.hp = player.max_hp
	boss.opponent = player
	Game.player = player
	Game.boss = boss
	player.hit_resolved.connect(func(info: Dictionary, res: int): _results.append({"info": info, "res": res,
		"t": float(info.get("time", Game.clock))}))
	await ticks(6)


## Starts a boss attack now; returns its start clock.
func boss_attack(clip: String) -> float:
	boss.face_now(player.global_position)
	boss._seq.clear()
	boss._play_attack(clip, 0.0)
	return Game.clock


func run_until_boss_done(max_time := 4.0) -> void:
	var t_end := Game.clock + max_time
	await ticks(1)
	while boss.state == Boss.S.ATTACK and Game.clock < t_end:
		await ticks(1)
	await ticks(12)


static func res_name(r: int) -> String:
	return ["none", "DEFLECT", "BLOCK", "HIT", "MIKIRI", "ignored", "evaded"][r]


func first_result() -> int:
	return int(_results[0]["res"]) if _results.size() > 0 else Combat.RESULT_NONE


## Tries to get away from the attack that's playing, starting at game time `t`, then waits for
## it to end. "backstep" / "side step": a tapped step, then keep walking that way.
## "backstep x2": two steps back to back. "backstep + sprint": dodge held, so the step runs
## into a sprint. "walk back": just walk away.
func _run_escape(how: String, t: float) -> void:
	var mv := Vector2(1, 0) if how == "side step" else Vector2(0, 1)
	at(t, func():
		player.bot_move = mv
		if how != "walk back":
			player.press_action("dodge", t))
	if how != "backstep + sprint":
		at(t + 0.05, func(): player.release_dodge())
	if how == "backstep x2":
		at(t + 0.36, func(): player.press_action("dodge", t + 0.36))
		at(t + 0.41, func(): player.release_dodge())
	await run_until_boss_done()
	player.bot_move = Vector2.ZERO
	player.release_dodge()


## Contact times (relative to attack start) of every hit window of `clip` against a
## player standing still at `dist`.
func contact_times(clip: String, dist: float) -> Array:
	await setup(dist)
	var t0 := boss_attack(clip)
	await run_until_boss_done()
	var out: Array = []
	for r in _results:
		out.append({"rel": float(r["t"]) - t0, "index": int((r["info"] as Dictionary).get("index", 0)),
			"kind": str((r["info"] as Dictionary).get("kind", "normal"))})
	return out


# ---------------------------------------------------------------------------- suites
const BOSS_ATTACKS := {
	# clip: [min, max] player distance at which every hit window must connect. The max is the
	# far end of the range the AI uses the attack from (Boss.SEQUENCES) plus a little.
	"b_combo_1": [1.0, 3.4], "b_combo_2": [1.0, 3.4], "b_combo_3": [1.0, 3.4], "b_backhand": [1.0, 3.4],
	"b_jab": [1.0, 3.5], "b_whirl": [1.0, 3.0], "b_parry_counter": [1.0, 3.0], "b_thrust": [1.0, 5.6],
	"b_sweep": [1.0, 3.4], "b_leap": [4.8, 8.0], "b_dash_cut": [1.3, 3.8],
}


## Every hit window of every boss attack must connect with a player standing anywhere from
## point-blank to the attack's intended range, straight ahead or a little to the side.
func suite_reach() -> void:
	for clip in BOSS_ATTACKS:
		var rng: Array = BOSS_ATTACKS[clip]
		var n_hits: int = AnimLibrary.get_clip(clip).hits.size()
		var row := PackedStringArray()
		var dists: Array = [1.0, 1.3, 1.6, 2.0, 2.4, 2.8, 3.2, 3.8, 4.5, 5.4] if clip != "b_leap" else [4.8, 5.5, 6.5, 8.0]
		for d in dists:
			if d < float(rng[0]) - 0.01 or d > float(rng[1]) + 0.01:
				continue
			for ang in [-25.0, 0.0, 25.0]:
				await setup(d, ang)
				boss_attack(clip)
				await run_until_boss_done()
				var got := {}
				for r in _results:
					got[int((r["info"] as Dictionary).get("index", -1))] = true
				row.append("%.1fm/%+.0f°:%d/%d" % [d, ang, got.size(), n_hits])
				check(got.size() == n_hits, "%s at %.1f m, %+.0f°: %d of %d hit windows connected" % [clip, d, ang, got.size(), n_hits])
		print("  %-16s %s" % [clip, " ".join(row)])


## How each attack reads from where you stand: when its blows land (seconds from the start of
## the attack) at a few distances. Every blow must land when the blade actually reaches you,
## not the instant its hit window opens (that means the blade was already inside you, and the
## deflect timing wouldn't match what you see), and an attack that opens a string must give
## at least TELL_MIN of warning before its first blow.
const TELL_MIN := 0.45
const TELL_OPENERS := ["b_combo_1", "b_backhand", "b_jab", "b_whirl", "b_thrust", "b_sweep", "b_leap",
	"b_dash_cut", "b_parry_counter"]


func suite_tells() -> void:
	for clip in BOSS_ATTACKS:
		var c := AnimLibrary.get_clip(clip)
		var dists: Array = [5.0, 6.5] if clip == "b_leap" else [1.4, 2.0, 2.6]
		for d in dists:
			var cts := await contact_times(clip, d)
			var row := PackedStringArray()
			for r in cts:
				var h: Dictionary = c.hits[int(r["index"])]
				var at_open := float(r["rel"]) - float(h["from"]) < 1.5 * DT
				row.append("%.3f%s" % [float(r["rel"]), "*" if at_open else ""])
				check(not at_open, "%s at %.1f m: blow %d lands the instant its window opens (%.3f s)" % [clip, d,
					int(r["index"]), float(r["rel"])])
			if not cts.is_empty() and clip in TELL_OPENERS:
				check(float(cts[0]["rel"]) >= TELL_MIN, "%s at %.1f m: first blow after %.3f s (want >= %.2f)" % [clip, d,
					float(cts[0]["rel"]), TELL_MIN])
			print("  %-16s %.1fm: %s" % [clip, d, " ".join(row)])


## Pressing guard `o` seconds before contact: deflect for 0 <= o <= 0.200, block after that
## while the guard is up (held, or within GUARD_MIN_TIME of a tap), hit when late.
## Perilous thrusts can be deflected but not blocked.
func suite_deflect() -> void:
	var offsets := [-0.03, -0.005, 0.0, 0.01, 0.05, 0.1, 0.15, 0.19, 0.199, 0.205, 0.22, 0.3, 0.34, 0.4, 0.6]
	for clip in ["b_combo_1", "b_combo_3", "b_jab", "b_thrust", "b_backhand"]:
		var cts := await contact_times(clip, 2.2)
		if cts.is_empty():
			check(false, "%s: no contact to deflect" % clip)
			continue
		var c0: Dictionary = cts[0]
		var rel := float(c0["rel"])
		var thrust: bool = str(c0["kind"]) == "thrust"
		for hold in [true, false]:
			var row := PackedStringArray()
			for o in offsets:
				await setup(2.2)
				var t0 := boss_attack(clip)
				var press_t: float = t0 + rel - float(o)
				at(press_t, func(): player.press_guard(press_t))
				if not hold:
					at(press_t + 0.1, func(): player.release_guard(press_t + 0.1))
				await run_until_boss_done()
				var got := first_result()
				var want := Combat.RESULT_HIT
				if float(o) >= 0.0 and float(o) <= Combat.DEFLECT_WINDOW:
					want = Combat.RESULT_DEFLECT
				elif float(o) > Combat.DEFLECT_WINDOW and not thrust and (hold or float(o) < Combat.GUARD_MIN_TIME):
					want = Combat.RESULT_BLOCK
				elif float(o) < 0.0 and float(o) >= -Combat.DEFLECT_GRACE:
					want = Combat.RESULT_DEFLECT
				row.append("%+4.0fms:%s" % [float(o) * 1000.0, res_name(got)[0]])
				# A press stamped just after contact still counts if it arrives in the same physics
				# tick (evaluated first, like frame-based games); in a later tick it's a hit.
				if float(o) < 0.0 and float(o) >= -Combat.DEFLECT_GRACE and got == Combat.RESULT_HIT:
					want = Combat.RESULT_HIT
				check(got == want, "%s %s guard %.0f ms before contact -> %s (want %s)" % [clip,
					"held" if hold else "tapped", float(o) * 1000.0, res_name(got), res_name(want)])
		print("  %-12s contact @%.3fs  %s" % [clip, rel, "ok" if failures.is_empty() else ""])
	# Deflects never break the player's posture.
	await setup(2.2)
	player.posture = player.max_posture - 1.0
	var cts2 := await contact_times("b_combo_3", 2.2)
	await setup(2.2)
	player.posture = player.max_posture - 1.0
	var t1 := boss_attack("b_combo_3")
	var pt: float = t1 + float(cts2[0]["rel"]) - 0.08
	at(pt, func(): player.press_guard(pt))
	await run_until_boss_done()
	check(first_result() == Combat.RESULT_DEFLECT and player.state != Player.S.GUARD_BREAK,
		"deflect at full posture does not guard-break (state %s)" % Player.S.keys()[player.state])
	# A deflect that breaks his posture partway through a multi-hit attack switches his clip
	# while that attack's hit windows are being processed: he must go down cleanly, with no
	# runtime error (this used to index the new clip's hits with the old clip's indices).
	for clip in ["b_whirl", "b_jab"]:
		var cts3 := await contact_times(clip, 2.2)
		await setup(2.2)
		var e0 := _errors.count()
		var t2 := boss_attack(clip)
		var pk: float = t2 + float(cts3[0]["rel"]) - 0.06
		at(pk, func():
			boss.posture = boss.max_posture - 0.5       # one deflect from breaking (after regen)
			player.press_guard(pk))
		await run_until_boss_done()
		await ticks(30)
		check(first_result() == Combat.RESULT_DEFLECT and boss.state == Boss.S.STAGGER,
			"%s: a deflect that breaks his posture mid-attack staggers him (%s, %s)" % [clip,
			res_name(first_result()), Boss.S.keys()[boss.state]])
		check(_errors.count() == e0, "%s: posture break mid-attack raises no runtime error (%d)" % [clip, _errors.count() - e0])


## Flurries (whirl, jabs, shuriken): one missed deflect must not cost the whole string. After
## the first blow lands, holding guard blocks (or deflects) everything that follows, and
## spamming guard through a string never lets a blow through.
func suite_flurry() -> void:
	for clip in ["b_whirl", "b_jab", "b_shuriken_4", "b_shuriken_5"]:
		var cts := await contact_times(clip, 2.4)
		if cts.size() < 2:
			check(false, "%s: expected several blows against a still player (%d)" % [clip, cts.size()])
			continue
		var first := float(cts[0]["rel"])
		# Get hit by the first blow, then press and hold guard.
		await setup(2.4)
		var t0 := boss_attack(clip)
		var pg: float = t0 + first + 0.02
		at(pg, func(): player.press_guard(pg))
		await run_until_boss_done(4.5)
		await ticks(60)
		var got: Array = _results.map(func(r): return res_name(int(r["res"])))
		print("  %-13s hit, then hold guard: %s" % [clip, " ".join(got)])
		check(got.size() == cts.size() and got[0] == "HIT" and not got.slice(1).has("HIT"),
			"%s: after the first blow lands, holding guard stops the rest (%s)" % [clip, " ".join(got)])
		# Tap guard every 0.14 s from well before the first blow to the end.
		await setup(2.4)
		t0 = boss_attack(clip)
		for k in 32:
			var tp: float = t0 + first - 0.5 + 0.14 * k
			at(tp, func():
				if player.guard_held:
					player.release_guard(tp)
				player.press_guard(tp))
			var tr: float = tp + 0.07
			at(tr, func(): player.release_guard(tr))
		await run_until_boss_done(4.5)
		await ticks(60)
		got = _results.map(func(r): return res_name(int(r["res"])))
		print("  %-13s spamming guard:     %s" % [clip, " ".join(got)])
		check(got.size() == cts.size() and not got.has("HIT"), "%s: spamming guard blocks every blow (%s)" % [clip, " ".join(got)])


## Spam penalty: window per press depends on the time since the last *release*.
func suite_spam() -> void:
	await setup(3.0)
	var t := Game.clock
	var windows: Array = []
	# Mash: press/release every 0.12 s.
	for i in 6:
		player.press_guard(t)
		windows.append(player.guard_window)
		player.release_guard(t + 0.04)
		t += 0.12
	print("  mash windows (ms): %s" % str(windows.map(func(w): return int(round(w * 1000.0)))))
	check(is_equal_approx(windows[0], 0.2), "first press = 200 ms")
	check(windows[1] < 0.2 and windows[2] < windows[1] and windows[3] < windows[2], "mashing shrinks the window")
	check(windows[4] == 0.0, "5th mash press gets no deflect window")
	# Waiting 0.5 s after a release clears it.
	player.press_guard(t + 0.55)
	check(is_equal_approx(player.guard_window, 0.2), "penalty clears 0.5 s after release (%.0f ms)" % (player.guard_window * 1000.0))
	player.release_guard(t + 0.6)
	# Hold then release-and-repress quickly is penalised.
	await setup(3.0)
	t = Game.clock
	player.press_guard(t)
	player.release_guard(t + 1.5)
	player.press_guard(t + 1.6)
	check(player.guard_window < 0.2, "release then quick re-press is penalised (%.0f ms)" % (player.guard_window * 1000.0))
	player.release_guard(t + 1.62)
	# A successful deflect clears the penalty immediately.
	var cts := await contact_times("b_jab", 2.2)
	await setup(2.2)
	var t0 := boss_attack("b_jab")
	var c0: float = t0 + float(cts[0]["rel"])
	var c1: float = t0 + float(cts[1]["rel"])
	# Mash three times before the first hit (the last press, inside its shrunken 100 ms window,
	# lands the deflect), then re-press quickly for the second jab.
	for k in 3:
		var pk: float = c0 - 0.06 - 0.12 * (2 - k)
		at(pk, func(): player.press_guard(pk))
		at(pk + 0.03, func(): player.release_guard(pk + 0.03))
	var w_second := [0.0]
	at(c1 - 0.08, func():
		player.press_guard(c1 - 0.08)
		w_second[0] = player.guard_window)
	await run_until_boss_done()
	var r0 := res_name(int(_results[0]["res"])) if _results.size() > 0 else "none"
	var r1 := res_name(int(_results[1]["res"])) if _results.size() > 1 else "none"
	print("  jab: mashed deflect -> %s, next press window %.0f ms -> %s" % [r0, w_second[0] * 1000.0, r1])
	check(r0 == "DEFLECT" or r0 == "HIT", "mashed first jab resolves")
	if r0 == "DEFLECT":
		check(is_equal_approx(w_second[0], 0.2), "deflect resets the penalty (window %.0f ms)" % (w_second[0] * 1000.0))
		check(r1 == "DEFLECT", "rhythmic second deflect works after a deflect")


## Mikiri (Sekiro): only a *neutral* step (no direction held) counters, and only once the
## thrust is released (the spear starts going forward). Stepping during the pull-back is too
## early; holding forward gives a plain dodge; side steps never counter.
func suite_mikiri() -> void:
	var rel_t := AnimLibrary.get_clip("b_thrust").get_float("mikiri_from", 0.74)
	for d in [2.4, 3.4, 4.4]:
		var cts := await contact_times("b_thrust", d)
		if cts.is_empty():
			check(false, "thrust never reaches a player at %.1f m" % d)
			continue
		var contact := float(cts[0]["rel"])
		var row := PackedStringArray()
		for o in [-0.45, -0.3, -0.16, -0.12, -0.09, -0.05, 0.0, 0.05, 0.1]:
			var press_rel: float = rel_t + float(o)
			if press_rel >= contact - 0.01:
				continue
			for dir_name in ["neutral", "fwd", "side"]:
				if dir_name != "neutral" and float(o) != 0.0:
					continue
				await setup(d)
				var t0 := boss_attack("b_thrust")
				var pt: float = t0 + press_rel
				var mv := Vector2.ZERO
				if dir_name == "fwd":
					mv = Vector2(0, -1)
				elif dir_name == "side":
					mv = Vector2(1, 0)
				at(pt, func():
					player.bot_move = mv
					player.press_action("dodge", pt))
				at(pt + 0.05, func(): player.bot_move = Vector2.ZERO)
				await run_until_boss_done()
				var got := res_name(first_result())
				row.append("%s%+.2f:%s" % [dir_name[0], o, got[0]])
				if dir_name == "neutral":
					if float(o) >= -Combat.MIKIRI_EARLY_GRACE:
						check(got == "MIKIRI", "neutral step %+.2f s from the release at %.1f m mikiris (%s)" % [o, d, got])
					else:
						check(got != "MIKIRI", "neutral step during the pull-back (%+.2f s) at %.1f m is too early (%s)" % [o, d, got])
				elif dir_name == "fwd":
					# A forward step's i-frames don't cover thrusts: holding forward gets you stabbed.
					check(got == "HIT", "fwd step at the release gets stabbed, no mikiri (%.1f m, %s)" % [d, got])
				else:
					check(got != "MIKIRI", "%s step at the release never mikiris (%.1f m, %s)" % [dir_name, d, got])
		print("  thrust @%.1fm release %.2fs contact %.3fs  %s" % [d, rel_t, contact, " ".join(row)])
	# Getting away instead: a backstep or a side step at the release, two backsteps, or a
	# backstep into a sprint as the kanji shows must still get stabbed - he tracks through
	# the release and the lunge stretches.
	for d in [2.4, 3.4, 4.4]:
		for how in ["backstep", "side step", "backstep x2", "backstep + sprint"]:
			await setup(d)
			var t2 := boss_attack("b_thrust")
			await _run_escape(how, t2 + (rel_t - 0.05 if how == "backstep" or how == "side step" else 0.1))
			check(first_result() == Combat.RESULT_HIT, "%s away from the thrust at %.1f m still gets stabbed (%s)" % [how, d, res_name(first_result())])
	# Posture damage of a clean counter.
	await setup(3.0)
	var t1 := boss_attack("b_thrust")
	var p2: float = t1 + rel_t
	at(p2, func(): player.press_action("dodge", p2))
	await run_until_boss_done()
	check(first_result() == Combat.RESULT_MIKIRI, "neutral step on the release at 3.0 m -> MIKIRI (%s)" % res_name(first_result()))
	check(boss.posture >= Combat.MIKIRI_POSTURE - 0.5, "mikiri deals heavy posture damage (%.0f)" % boss.posture)


## Dodge (Sekiro): a short, quick step. It repositions you; it doesn't carry you out of an
## attack's reach. I-frames match Sekiro's: 0.2 s for side and back steps, 0.3 s for forward
## steps, which don't cover thrusts (the mikiri suite checks that).
func suite_dodge() -> void:
	for dir_name in ["back", "side", "neutral"]:
		await setup(6.0)
		var p0 := player.global_position
		var mv := Vector2(0, 1) if dir_name == "back" else (Vector2(1, 0) if dir_name == "side" else Vector2.ZERO)
		var t0 := Game.clock
		at(t0, func():
			player.bot_move = mv
			player.press_action("dodge", t0))
		await ticks(3)
		player.bot_move = Vector2.ZERO
		await ticks(90)
		var moved := Combat.flat(player.global_position - p0).length()
		print("  %s step: moved %.2f m" % [dir_name, moved])
		check(moved <= (1.2 if dir_name == "neutral" else 1.6), "%s step is short (%.2f m)" % [dir_name, moved])
	for clip_name in ["p_dodge_back", "p_dodge_left", "p_dodge_right", "p_dodge_fwd"]:
		var c := AnimLibrary.get_clip(clip_name)
		var ifr: Array = c.raw.get("iframes", [0, 0])
		var want := 0.3 if clip_name == "p_dodge_fwd" else 0.2
		var got := float(ifr[1]) - float(ifr[0])
		check(absf(got - want) < 0.005, "%s has Sekiro's %.1f s of i-frames (%.2f s)" % [clip_name, want, got])
	check(AnimLibrary.get_clip("p_dodge_fwd").raw.get("iframes_except", []).has("thrust"),
		"a forward step's i-frames don't cover thrusts")


## Sweep: can't be blocked or deflected, dodging doesn't help, jumping clears it and a
## second jump kicks off him for posture damage.
func suite_sweep() -> void:
	var cts := await contact_times("b_sweep", 2.2)
	check(not cts.is_empty(), "sweep reaches a standing player")
	if cts.is_empty():
		return
	var rel := float(cts[0]["rel"])
	# Deflect attempt -> hit.
	await setup(2.2)
	var t0 := boss_attack("b_sweep")
	var pg: float = t0 + rel - 0.08
	at(pg, func(): player.press_guard(pg))
	await run_until_boss_done()
	check(first_result() == Combat.RESULT_HIT, "guarding a sweep fails (%s)" % res_name(first_result()))
	# Dodge i-frames don't help against a sweep (step into it -> hit).
	await setup(2.2)
	t0 = boss_attack("b_sweep")
	var pd: float = t0 + rel - 0.1
	at(pd, func(): player.press_action("dodge", pd))
	await run_until_boss_done()
	check(first_result() == Combat.RESULT_HIT, "dodging into a sweep fails: i-frames don't apply (%s)" % res_name(first_result()))
	# Getting away instead of jumping: stepping, walking or sprinting away (locked on) as the
	# kanji shows must still get caught - he chases you down and the sweep is long and low.
	for how in ["backstep", "side step", "backstep x2", "backstep + sprint", "walk back"]:
		for d in [1.5, 2.5, 3.4]:
			await setup(d)
			t0 = boss_attack("b_sweep")
			await _run_escape(how, t0 + 0.1)
			check(first_result() == Combat.RESULT_HIT, "%s away from the sweep at %.1f m still gets hit (%s)" % [how, d, res_name(first_result())])
	# Jump windows.
	var row := PackedStringArray()
	var cleared := 0
	for o in [0.6, 0.45, 0.35, 0.25, 0.15, 0.08, 0.0]:
		await setup(2.2)
		t0 = boss_attack("b_sweep")
		var pj: float = t0 + rel - float(o)
		at(pj, func(): player.press_action("jump", pj))
		await run_until_boss_done()
		var got := res_name(first_result())
		if got == "none":
			cleared += 1
		row.append("%.2f:%s" % [o, got[0]])
	print("  sweep contact %.3fs, jump offsets %s" % [rel, " ".join(row)])
	check(cleared >= 3, "jumping 0.1-0.4 s before the sweep clears it (%d offsets clear)" % cleared)
	# Jump + kick.
	await setup(2.0)
	t0 = boss_attack("b_sweep")
	var pj2: float = t0 + rel - 0.3
	at(pj2, func(): player.press_action("jump", pj2))
	at(pj2 + 0.3, func(): player.press_action("jump", pj2 + 0.3))
	await run_until_boss_done()
	print("  jump+kick: boss posture %.0f, boss state %s" % [boss.posture, Boss.S.keys()[boss.state]])
	check(boss.posture >= Combat.KICK_POSTURE, "kicking off him during the sweep deals posture (%.0f)" % boss.posture)


## Shuriken volleys: he leaps back and throws 3 fast + 1 delayed, or 5 fast. Every throw can
## be deflected (no posture to him, as in Sekiro) or blocked, and hits if ignored.
func suite_shuriken() -> void:
	for clip in ["b_shuriken_4", "b_shuriken_5"]:
		var n_throws := 4 if clip == "b_shuriken_4" else 5
		# Arrival times against a player standing still.
		await setup(3.0)
		var t0 := boss_attack(clip)
		await run_until_boss_done(3.0)
		await ticks(60)
		var arrivals: Array = []
		for r in _results:
			arrivals.append(float(r["t"]) - t0)
		var gaps: Array = []
		for i in range(1, arrivals.size()):
			gaps.append(snappedf(float(arrivals[i]) - float(arrivals[i - 1]), 0.01))
		print("  %s: %d hits, arrivals %s, gaps %s" % [clip, arrivals.size(), str(arrivals.map(func(x): return snappedf(x, 0.01))), str(gaps)])
		check(arrivals.size() == n_throws, "%s: all %d shuriken reach a still player (%d)" % [clip, n_throws, arrivals.size()])
		if arrivals.size() != n_throws:
			continue
		if clip == "b_shuriken_4":
			check(float(gaps[0]) < 0.22 and float(gaps[1]) < 0.22 and float(gaps[2]) > 0.3,
				"b_shuriken_4 is 3 fast + 1 delayed (gaps %s)" % str(gaps))
		else:
			for g in gaps:
				check(float(g) < 0.22, "b_shuriken_5 throws come fast (gap %.2f)" % float(g))
		check(float(arrivals[0]) > 0.6, "the first shuriken arrives after a readable tell (%.2f s)" % float(arrivals[0]))
		# Deflect each one 80 ms before it lands (tap).
		await setup(3.0)
		t0 = boss_attack(clip)
		for a in arrivals:
			var pt: float = t0 + float(a) - 0.08
			at(pt, func(): player.press_guard(pt))
			at(pt + 0.04, func(): player.release_guard(pt + 0.04))
		await run_until_boss_done(3.0)
		await ticks(60)
		var got := _results.map(func(r): return res_name(int(r["res"])))
		check(got.count("DEFLECT") == n_throws, "%s: every throw deflected on time (%s)" % [clip, str(got)])
		check(boss.posture <= 0.01, "%s: deflecting shuriken costs him no posture (%.1f)" % [clip, boss.posture])
		# Holding guard blocks them all.
		await setup(3.0)
		t0 = boss_attack(clip)
		at(t0 + 0.1, func(): player.press_guard(t0 + 0.1))
		await run_until_boss_done(3.0)
		await ticks(60)
		got = _results.map(func(r): return res_name(int(r["res"])))
		check(got.count("BLOCK") == n_throws, "%s: holding guard blocks every throw (%s)" % [clip, str(got)])
		player.release_guard(Game.clock)


## The punish loop over whole fights (three seeds each) against bots that deflect everything:
## one hits him only when he's open, the other whenever he's in reach. Deflecting should earn
## hits, but he must not be locked into "attack, get deflected, eat a combo, same attack again"
## (or "guard, parry, get deflected, eat a combo"): a string of hits that leave him reeling is
## short, and after being punished he changes his plan.
const LOOP_TIME := 90.0


func suite_loop() -> void:
	for style in ["punisher", "aggressor"]:
		var agg := {"cycles": 0, "reeling": 0, "worst": 0, "punished": 0, "repeats": 0}
		for sd in [4242, 777, 31337]:
			var r := await _loop_fight(style, sd)
			for k in agg:
				agg[k] = maxi(int(agg[k]), int(r[k])) if k == "worst" else int(agg[k]) + int(r[k])
		print("  %-9s %d of his attacks, %d hits left him reeling (%.2f per attack, most %d in a row), punished %d times, same attack right after %d" % [
			style, agg["cycles"], agg["reeling"], float(agg["reeling"]) / maxf(1.0, agg["cycles"]), agg["worst"],
			agg["punished"], agg["repeats"]])
		check(int(agg["worst"]) <= 3, "loop (%s): at most 3 hits leave him reeling between his attacks (%d)" % [style, agg["worst"]])
		check(int(agg["repeats"]) * 5 <= maxi(int(agg["punished"]), 1), "loop (%s): after being punished he rarely opens with the same attack (%d of %d)" % [
			style, agg["repeats"], agg["punished"]])


## "punisher" only swings when he's open (recoil, flinch, recovery); "aggressor" swings
## whenever he's in reach and no blow is about to land. Returns the fight's tallies.
func _loop_fight(style: String, sd: int) -> Dictionary:
	seed(sd)
	await setup(3.0)
	player.max_hp = 1.0e6
	player.hp = player.max_hp
	boss.passive = false
	boss.start_fight()
	var t_end := Game.clock + LOOP_TIME
	var cycles: Array = []          ## [sequence, hits that left him reeling before his next sequence]
	var cur := ["", 0]
	var prev_state := [boss.state]
	var was_counter := [false, 0.0]
	boss.struck.connect(func(r):
		if int(r) == Combat.RESULT_HIT and boss.state == Boss.S.REACT:
			cur[1] = int(cur[1]) + 1)
	var handled := {}
	var serial := [0, ""]
	var next_attack := 0.0
	var breaks := [0]
	boss.posture_broken.connect(func(): breaks[0] += 1)
	while Game.clock < t_end:
		await ticks(1)
		var now := Game.clock
		# A new "cycle" whenever he starts attacking again: a sequence, or his parry counter.
		var in_counter := boss.state == Boss.S.ATTACK and boss.anim.clip != null and not boss.anim.loco_active \
				and boss.anim.clip.name == "b_parry_counter"
		var counter := in_counter and (not bool(was_counter[0]) or boss.anim.time < float(was_counter[1]))
		was_counter[0] = in_counter
		was_counter[1] = boss.anim.time
		if counter or (boss.state == Boss.S.ATTACK and prev_state[0] != Boss.S.ATTACK and boss._seq_name != ""):
			if str(cur[0]) != "":
				cycles.append(cur.duplicate())
			cur[0] = "counter" if counter else boss._seq_name
			cur[1] = 0
		prev_state[0] = boss.state
		var d := player.distance_to_opponent()
		player.camera_yaw = Combat.yaw_of(Combat.flat(boss.global_position - player.global_position))
		player.bot_move = Vector2(0, -1) if d > 2.6 and boss.state != Boss.S.ATTACK else Vector2.ZERO
		if player.guard_held and now - player.guard_start > 0.1:
			player.release_guard(now)
		var ttc := _blade_time_to_contact()
		for sh in world.get_children():
			if sh is Shuriken and (sh as Shuriken)._flying and not handled.has(sh.get_instance_id()):
				var cap := player.hurt_capsule()
				var dist := Geometry3D.get_closest_point_to_segment(sh.global_position, cap[0], cap[1]).distance_to(sh.global_position)
				if (dist - float(cap[2])) / Shuriken.SPEED <= 0.08:
					handled[sh.get_instance_id()] = true
					if player.guard_held:
						player.release_guard(now)
					player.press_guard(now)
		if boss.state == Boss.S.ATTACK and boss.anim.clip != null and not boss.anim.loco_active:
			var c := boss.anim.clip
			if c.name != serial[1] or boss.anim.time < 0.02:
				serial[1] = c.name
				serial[0] += 1
			for i in c.hits.size():
				var h: Dictionary = c.hits[i]
				var key := "%d:%d" % [serial[0], i]
				if handled.has(key):
					continue
				if str(c.raw.get("perilous", "")) == "sweep":
					if boss.anim.time >= float(h["from"]) - 0.3:
						handled[key] = true
						player.press_action("jump", now)
						var kt := now + 0.32
						at(kt, func(): player.press_action("jump", kt))
					continue
				if boss.anim.time >= float(h["from"]) - 0.35 and ttc <= 0.08:
					handled[key] = true
					if player.guard_held:
						player.release_guard(now)
					player.press_guard(now)
		elif boss.is_deathblow_ready() and d < 3.0:
			player.press_action("attack", now)
		if now >= next_attack and d < 2.8 and not boss.is_deathblow_ready():
			var open := boss.state == Boss.S.REACT or (boss.state == Boss.S.ATTACK and boss._in_vuln())
			if open or (style == "aggressor" and ttc > 0.35 and boss.state != Boss.S.ATTACK):
				player.press_action("attack", now)
				next_attack = now + 0.12
	if str(cur[0]) != "":
		cycles.append(cur)
	var total := 0
	var free_runs := 0
	var punished_repeats := 0
	var worst := 0
	var names := PackedStringArray()
	for k in cycles.size():
		var n := int(cycles[k][1])
		total += n
		worst = maxi(worst, n)
		names.append("%s:%d" % [cycles[k][0], n])
		if n >= 2:
			free_runs += 1
			# (his parry counter is a reaction to you hitting his guard, not a choice)
			if k + 1 < cycles.size() and str(cycles[k][0]) != "counter" and str(cycles[k + 1][0]) == str(cycles[k][0]):
				punished_repeats += 1
	if verbose:
		print("    %s seed %d: posture breaks %d: %s" % [style, sd, breaks[0], " ".join(names)])
	return {"cycles": cycles.size(), "reeling": total, "worst": worst, "punished": free_runs, "repeats": punished_repeats}


## Deflect his attack, then mash attack at him (the stun-lock the fight must not allow). He
## may eat a hit or two in his recoil - that's the reward - but then he has to break out
## (parry, guard, back off or counter) instead of flinching again and again.
func suite_punish() -> void:
	var clips := ["b_backhand", "b_combo_3", "b_jab", "b_whirl", "b_combo_1"]
	for ci in clips.size():
		var clip: String = clips[ci]
		var cts := await contact_times(clip, 2.2)
		seed(900 + ci)          # his break-out is a random pick: keep each scenario reproducible
		await setup(2.2)
		boss.passive = false
		var got: Array = []
		# H: a hit that left him reeling; h: one he took while attacking anyway (a trade).
		boss.struck.connect(func(r):
			got.append("H" if int(r) == Combat.RESULT_HIT and boss.state == Boss.S.REACT else
				("h" if int(r) == Combat.RESULT_HIT else res_name(int(r))[0])))
		var t0 := boss_attack(clip)
		var last := 0.0
		for c in cts:
			var pt: float = t0 + float(c["rel"]) - 0.08
			at(pt, func():
				if player.guard_held:
					player.release_guard(pt)
				player.press_guard(pt))
			at(pt + 0.06, func(): player.release_guard(pt + 0.06))
			last = maxf(last, pt + 0.1)
		# Then mash: an attack press every 0.1 s for 4 s.
		for k in 40:
			var tk := last + 0.1 * k
			at(tk, func(): player.press_action("attack", tk))
		await ticks(int(ceil((last + 4.2 - Game.clock) / DT)))
		var reeling := 0
		var worst := 0
		for r in got:
			reeling = reeling + 1 if str(r) == "H" else 0
			worst = maxi(worst, reeling)
		print("  %-12s deflected, then mashed: %s  (player hp -%.0f)" % [clip, "".join(got), player.max_hp - player.hp])
		check(got.size() >= 2, "%s: the mash reaches him (%d)" % [clip, got.size()])
		check(worst <= 3, "%s: he stops reeling after at most 3 hits in a row (%d)" % [clip, worst])
		check(got.has("B") or got.has("D") or player.hp < player.max_hp,
			"%s: he stops the mash (guards, parries or hits back)" % clip)


## Player attacks: reach and rhythm. Mashing attack must not produce hits faster than the
## intended cadence, and each slash must reach a boss standing a sword's length away.
func suite_attack() -> void:
	for d in [1.6, 2.0, 2.4, 2.9]:
		await setup(d)
		boss.set_facing(PI)      # facing away: hits land instead of being blocked
		var hits_at: Array = []
		var t0 := Game.clock
		var t := t0
		while t < t0 + 3.0:
			var tt := t
			at(tt, func(): player.press_action("attack", tt))
			t += 0.06
		var hp0 := boss.hp
		var last_hp := boss.hp
		while Game.clock < t0 + 3.0:
			await ticks(1)
			if boss.hp < last_hp:
				hits_at.append(Game.clock - t0)
				last_hp = boss.hp
			if boss.state == Boss.S.REACT:
				boss.state = Boss.S.NEUTRAL
				boss.set_facing(PI)
		var gaps: Array = []
		for i in range(1, hits_at.size()):
			gaps.append(snappedf(float(hits_at[i]) - float(hits_at[i - 1]), 0.01))
		print("  mash @%.1fm: %d hits in 3 s, first at %.2fs, gaps %s" % [d, hits_at.size(),
			float(hits_at[0]) if hits_at.size() > 0 else -1.0, str(gaps)])
		if d <= 2.4:
			check(hits_at.size() >= 4, "slashes reach a boss %.1f m away (%d hits)" % [d, hits_at.size()])
		check(hits_at.size() <= 7, "mashing is rate-limited at %.1f m (%d hits in 3 s)" % [d, hits_at.size()])
		for g in gaps:
			check(float(g) >= 0.38, "no two slashes land within 0.38 s (gap %.2f)" % float(g))
		if hits_at.size() > 0:
			check(float(hits_at[0]) >= 0.18, "first slash lands no sooner than 0.18 s after the press (%.2f)" % float(hits_at[0]))


## Guard cancel: guard during the wind-up start or the recovery takes effect at once; guard
## during the committed swing is queued until the recovery.
func suite_cancel() -> void:
	var c := AnimLibrary.get_clip("p_attack_1")
	var wins: Array = c.raw.get("guard_cancel", [])
	print("  p_attack_1 guard_cancel %s, hits %s" % [str(wins), str(c.hits.map(func(h): return [h["from"], h["to"]]))])
	check(wins.size() >= 2, "attack has an early and a late guard-cancel window")
	for probe in [0.02, _first_hit(c), float(c.hits[0]["to"]) + 0.12]:
		await setup(3.5)
		boss.set_facing(PI)
		var t0 := Game.clock
		at(t0, func(): player.press_action("attack", t0))
		var pg: float = t0 + float(probe)
		at(pg, func(): player.press_guard(pg))
		await ticks(int(ceil((float(probe) + 0.02) / DT)) + 1)
		var guarded := player.state == Player.S.GUARD
		var expect := Player._in_guard_cancel(c, float(probe) - DT)
		print("  guard at %.2fs into slash -> state %s" % [probe, Player.S.keys()[player.state]])
		check(guarded == expect, "guard press %.2f s into the slash %s" % [probe, "cancels" if expect else "waits for the recovery"])
		await ticks(90)
		check(player.state == Player.S.GUARD, "queued guard comes up after the slash (%s)" % Player.S.keys()[player.state])
		player.release_guard(Game.clock)


## Full fight against the real boss AI with a bot that plays like a decent player: deflects
## with imperfect timing (sometimes early -> block, sometimes late -> hit), mikiris thrusts,
## jumps and kicks sweeps, attacks into openings, heals, and deathblows. Exercises the whole
## flow: posture breaks, deathblows, phase two, victory/death.
const SOAK_TIME := 480.0


func suite_soak() -> void:
	seed(12345)
	await setup(4.0)
	# The bot mistimes on purpose, and his posture takes a lot of work: give it the health to
	# play the whole fight through (this suite checks the flow, not the balance).
	player.max_hp = Combat.PLAYER_HP * 6.0
	player.hp = player.max_hp
	boss.passive = false
	boss.start_fight()
	var counts := {}
	var t_start := Game.clock
	var bump := func(k: String): counts[k] = int(counts.get(k, 0)) + 1
	player.hit_resolved.connect(func(i, r):
		bump.call(res_name(r))
		if verbose:
			print("    %6.2f %-16s hit %d -> %-7s player %-10s dt %+.0f ms (window %.0f, guard_up %s)" % [Game.clock,
				str(i.get("clip", "")), int(i.get("index", 0)), res_name(r), Player.S.keys()[player.state],
				(float(i.get("time", 0.0)) - player.guard_start) * 1000.0, player.guard_window * 1000.0, player.is_guard_up()]))
	boss.posture_broken.connect(func():
		bump.call("posture_break")
		if not counts.has("first_break_s"):
			counts["first_break_s"] = snappedf(Game.clock - t_start, 0.1))
	boss.life_lost.connect(func(_l): bump.call("life_lost"))
	var over := [""]
	boss.defeated.connect(func(): over[0] = "boss defeated")
	player.died.connect(func(): over[0] = "player died")
	var handled := {}
	var leads := {}
	var serial := [0, ""]
	var next_attack := 0.0
	var t_end := Game.clock + SOAK_TIME
	var last_desc := ""
	while Game.clock < t_end and over[0] == "":
		await ticks(1)
		var now := Game.clock
		if verbose:
			var desc := "%s %s %s" % [Boss.S.keys()[boss.state], boss._mode,
				boss.anim.clip.name if boss.anim.clip != null and not boss.anim.loco_active else "loco"]
			if desc != last_desc:
				print("    %6.2f boss %-40s d=%.1f cd=%.2f" % [now - (t_end - SOAK_TIME), desc, player.distance_to_opponent(), boss.cooldown])
				last_desc = desc
		var d := player.distance_to_opponent()
		# The lock-on camera keeps looking at him, so "forward" always means toward him.
		player.camera_yaw = Combat.yaw_of(Combat.flat(boss.global_position - player.global_position))
		player.bot_move = Vector2(0, -1) if d > 3.2 and boss.state != Boss.S.ATTACK else Vector2.ZERO
		if player.guard_held and now - player.guard_start > 0.1:
			player.release_guard(now)
		var ttc := _blade_time_to_contact()
		for sh in world.get_children():
			if sh is Shuriken and (sh as Shuriken)._flying and not handled.has(sh.get_instance_id()):
				var cap := player.hurt_capsule()
				var dist := Geometry3D.get_closest_point_to_segment(sh.global_position, cap[0], cap[1]).distance_to(sh.global_position)
				var lead_s := randf_range(0.04, 0.16)
				if (dist - float(cap[2])) / Shuriken.SPEED <= lead_s:
					handled[sh.get_instance_id()] = true
					if player.guard_held:
						player.release_guard(now)
					player.press_guard(now)
		if boss.state == Boss.S.ATTACK and boss.anim.clip != null and not boss.anim.loco_active:
			var c := boss.anim.clip
			if c.name != serial[1] or boss.anim.time < 0.02:
				serial[1] = c.name
				serial[0] += 1
			var peril := str(c.raw.get("perilous", ""))
			for i in c.hits.size():
				var h: Dictionary = c.hits[i]
				var key := "%d:%d" % [serial[0], i]
				if handled.has(key):
					continue
				if peril == "sweep":
					if boss.anim.time >= float(h["from"]) - 0.3:
						handled[key] = true
						player.press_action("jump", now)
						var kt := now + 0.32
						at(kt, func(): player.press_action("jump", kt))
					continue
				if peril == "thrust" and randf() < 0.75:
					if boss.anim.time >= float(h["from"]) - 0.16:
						handled[key] = true
						player.press_action("dodge", now)
					continue
				# React to the blade itself, like a player: press when its time-to-contact drops
				# to the intended lead. Mostly well-timed (30-170 ms before contact); 15% early
				# (-> block) to exercise the block path too.
				if not leads.has(key):
					leads[key] = randf_range(0.03, 0.17) if randf() > 0.15 else randf_range(0.24, 0.32)
				if boss.anim.time >= float(h["from"]) - 0.35 and ttc <= float(leads[key]):
					handled[key] = true
					if player.guard_held:
						player.release_guard(now)
					player.press_guard(now)
		elif boss.is_deathblow_ready() and d < 3.0:
			player.press_action("attack", now)
		elif now >= next_attack and d < 2.8:
			# Punish openings (his recoil / flinch / recovery); only occasionally poke from neutral.
			var opening := boss.state == Boss.S.REACT or (boss.state == Boss.S.ATTACK and boss._in_vuln())
			if opening or (boss.state == Boss.S.NEUTRAL and randf() < 0.25):
				player.press_action("attack", now)
			next_attack = now + randf_range(0.3, 0.9)
		if player.hp < player.max_hp * 0.35 and player.heal_charges > 0 and d > 3.0:
			player.press_action("heal", now)
	print("  soak: %s after %.0f s  %s  boss lives %d, player hp %.0f" % [over[0] if over[0] != "" else "time up",
		Game.clock - (t_end - SOAK_TIME), str(counts), boss.lives_left, player.hp])
	check(int(counts.get("DEFLECT", 0)) >= 10, "soak: deflects happen (%d)" % int(counts.get("DEFLECT", 0)))
	check(int(counts.get("BLOCK", 0)) >= 1, "soak: early presses block")
	check(int(counts.get("posture_break", 0)) >= 1, "soak: his posture breaks")
	check(int(counts.get("life_lost", 0)) >= 1, "soak: a deathblow takes a life (phase two)")


var _ttc_prev: Dictionary = {}


## Seconds until the boss's weapon reaches the player's hurtbox at its current closing speed
## (99 when it isn't closing in).
func _blade_time_to_contact() -> float:
	var cap := player.hurt_capsule()
	var best := 99.0
	for bn in boss.rig.blades:
		var pts := boss.rig.blade_world(bn)
		var dmin := 99.0
		for k in range(pts.size() - 1):
			var cp := Geometry3D.get_closest_points_between_segments(pts[k], pts[k + 1], cap[0], cap[1])
			dmin = minf(dmin, cp[0].distance_to(cp[1]) - float(cap[2]))
		var prev := float(_ttc_prev.get(bn, dmin))
		_ttc_prev[bn] = dmin
		var closing := (prev - dmin) / DT
		if dmin <= 0.0:
			best = 0.0
		elif closing > 0.3:
			best = minf(best, dmin / closing)
	return best


func _first_hit(c: ClipData) -> float:
	return float(c.hits[0]["from"])
