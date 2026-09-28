extends Node3D
## Headless combat lab: spawns the fighters, drives the player with scripted inputs at exact
## game times (through the same press_guard / press_action entry points the controller uses),
## forces boss attacks and checks the outcomes against docs/SEKIRO_MECHANICS.md.
##
## Run (from the project folder):
##   godot --headless --fixed-fps 120 res://tests/combat_lab.tscn -- [suite ...] [--verbose]
## Suites: reach, tells, deflect, flurry, punish, loop, phases, menu, spam, mikiri, dodge, sweep, shuriken, attack, cancel, inferno, soak (default: all).
## Exit code 0 when every check passes, including "no engine or script errors during the run".

const DT := 1.0 / 120.0
const SHURIKEN_POSTURE := 4.0   ## the boss_posture of a thrown shuriken (Boss._throw_shuriken)

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
		suites = ["reach", "tells", "deflect", "flurry", "tempest", "punish", "escape", "loop", "phases", "menu", "camera", "ribbons", "spam", "mikiri", "dodge", "sweep", "shuriken", "attack", "cancel", "hitstop", "deathblow", "inferno", "soak"]
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
	await run_until_boss_done(6.0)
	await ticks(60)                       # shuriken still in flight when he's done
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
	"b_sweep": [1.0, 3.4], "b_leap": [4.8, 8.0], "b_dash_cut": [1.3, 3.8], "b_tempest": [1.0, 4.4],
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
				await run_until_boss_done(maxf(4.0, AnimLibrary.get_clip(clip).length + 0.5))
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
	"b_dash_cut", "b_parry_counter", "b_tempest"]


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
	for clip in ["b_whirl", "b_jab", "b_shuriken_4", "b_shuriken_5", "b_shuriken_4x2", "b_shuriken_5x2", "b_tempest"]:
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
		await run_until_boss_done(6.0)
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
		await run_until_boss_done(6.0)
		await ticks(60)
		got = _results.map(func(r): return res_name(int(r["res"])))
		print("  %-13s spamming guard:     %s" % [clip, " ".join(got)])
		check(got.size() == cts.size() and not got.has("HIT"), "%s: spamming guard blocks every blow (%s)" % [clip, " ".join(got)])
	# A blocked blow breaks the guard while it's held, and the button stays held: once the
	# stagger is over the guard comes back up by itself, as it does after a flinch (a block:
	# the press keeps its old time, so this is no free deflect).
	await setup(2.2)
	player.press_guard(Game.clock)
	await ticks(30)
	player.posture = player.max_posture - 1.0
	boss_attack("b_combo_1")
	var saw_break := false
	var t_end := Game.clock + 5.0
	await ticks(1)
	while (boss.state == Boss.S.ATTACK or player.state == Player.S.GUARD_BREAK) and Game.clock < t_end:
		saw_break = saw_break or player.state == Player.S.GUARD_BREAK
		await ticks(1)
	await ticks(12)
	var up := player.is_guard_up()
	_results.clear()
	boss_attack("b_combo_1")
	await run_until_boss_done()
	var after: Array = _results.map(func(r): return res_name(int(r["res"])))
	print("  guard broken while held, still held: back up %s, next blow %s" % [up, " ".join(after)])
	check(saw_break and up and after == ["BLOCK"],
		"guard broken while held: the held guard is back up after the stagger and blocks the next blow (%s, %s)" % [up, " ".join(after)])


## Phase 3's Tempest of Fangs: six blows in a rhythm (ta-ta . . . ta-ta . . . . ta . . . TAAA),
## tracking you. Deflecting each as its blade comes clears the set and loads his posture;
## pressing on an even beat instead misses the blows that come after a pause; blocking it all
## breaks your guard on the last blow; backing off doesn't get you out of reach; it's only his
## in phase 3.
func suite_tempest() -> void:
	for d in [2.2, 3.4]:
		var r := await _tempest_run("deflect", d)
		var res: Array = r["res"]
		print("  tempest %.1f m, deflecting each: %s  contacts %s  gaps %s  his posture +%.0f" % [d, " ".join(res),
			str(r["times"]), str(r["gaps"]), r["posture"]])
		check(res.size() == 6 and res.count("DEFLECT") == 6 and not bool(r["broke"]),
			"tempest at %.1f m: deflecting each blow as it comes clears all six (%s)" % [d, " ".join(res)])
		check(float(r["posture"]) >= 50.0, "tempest at %.1f m: deflecting the set loads his posture (+%.0f)" % [d, r["posture"]])
		var g: Array = r["gaps"]
		if g.size() == 5:
			check(float(g[0]) < 0.5 and float(g[1]) >= 0.8 and float(g[2]) < 0.5 and float(g[3]) >= 1.0 and float(g[4]) >= 0.8,
				"tempest at %.1f m: the rhythm is two quick, a pause, two quick, a long delay, one, a pause, the last (%s)" % [d, str(g)])
	var rb := await _tempest_run("beat", 2.4)
	var rbr: Array = rb["res"]
	print("  tempest, pressing on an even beat (0.33 s after each blow): %s" % " ".join(rbr))
	check(rbr.size() == 6 and rbr[1] == "DEFLECT" and rbr[3] == "DEFLECT" and rbr[2] != "DEFLECT" and rbr[4] != "DEFLECT"
			and rbr[5] != "DEFLECT",
		"tempest: pressing on the quick beat deflects the quick blows but misses each one after a pause (%s)" % " ".join(rbr))
	var r2 := await _tempest_run("hold", 2.4)
	print("  tempest, holding guard: %s  guard broken %s" % [" ".join(r2["res"]), r2["broke"]])
	check((r2["res"] as Array).count("HIT") == 0 and bool(r2["broke"]) and (r2["res"] as Array).size() == 6,
		"tempest: blocking the whole set breaks your guard on the last blow (%s)" % " ".join(r2["res"]))
	var r3 := await _tempest_run("back", 2.4)
	print("  tempest, backing away locked on: %s" % " ".join(r3["res"]))
	check((r3["res"] as Array).size() >= 5, "tempest: backing away doesn't get you out of it (%d of 6 blows reach you)" % (r3["res"] as Array).size())
	# His in phase 3 only.
	var counts := {1: 0, 2: 0, 3: 0}
	for ph in [1, 2, 3]:
		await setup(2.5)
		boss._enter_phase(ph, false)
		seed(77)
		for k in 600:
			if boss._pick_action(2.5) == "tempest":
				counts[ph] = int(counts[ph]) + 1
	print("  tempest picked out of 600 at 2.5 m: phase 1 %d, phase 2 %d, phase 3 %d" % [counts[1], counts[2], counts[3]])
	check(int(counts[1]) == 0 and int(counts[2]) == 0 and int(counts[3]) >= 30,
		"the Tempest is his in phase 3 only (phase 1 %d, 2 %d, 3 %d of 600 picks)" % [counts[1], counts[2], counts[3]])


## One Tempest (phase 3 speed) against the player at `d`: "deflect" taps guard as each blade
## comes (100 ms before contact, like a player reading it), "hold" holds guard, "back" walks
## away locked on.
func _tempest_run(mode: String, d: float) -> Dictionary:
	await setup(d)
	boss._enter_phase(3, false)
	var p0 := boss.posture
	var broke := false
	if mode == "hold":
		player.press_guard(Game.clock)
		await ticks(30)
	var t0 := boss_attack("b_tempest")
	var handled := {}
	var release_at := -1.0
	var seen := 0
	var beat_at := -1.0
	var t_end := Game.clock + 7.0
	await ticks(1)
	while boss.state == Boss.S.ATTACK and Game.clock < t_end:
		var now := Game.clock
		player.camera_yaw = Combat.yaw_of(Combat.flat(boss.global_position - player.global_position))
		if mode == "back":
			player.bot_move = Vector2(0, 1)
		if release_at > 0.0 and now >= release_at:
			player.release_guard(now)
			release_at = -1.0
		if mode == "beat":
			# (the first blow deflected as it comes, then a press 0.33 s after each blow lands: the
			# quick pairs' beat)
			if _results.size() > seen:
				seen = _results.size()
				beat_at = now + 0.33
			if beat_at > 0.0 and now >= beat_at:
				beat_at = -1.0
				if player.guard_held:
					player.release_guard(now)
				player.press_guard(now)
				release_at = now + 0.05
		if (mode == "deflect" or (mode == "beat" and seen == 0)) and boss.anim.clip != null and not boss.anim.loco_active:
			for i in boss.anim.clip.hits.size():
				var h: Dictionary = boss.anim.clip.hits[i]
				if handled.has(i):
					continue
				# (watch the blade that's coming for this blow, from just before its window opens)
				var ttc := _blade_time_to_contact(str(h["blade"])) if boss.anim.time >= float(h["from"]) - 0.12 else 99.0
				if ttc <= 0.10 or boss.anim.time >= float(h["from"]) + 0.03:
					handled[i] = true
					if player.guard_held:
						player.release_guard(now)
					player.press_guard(now)
					release_at = now + 0.05
					if verbose:
						print("    tap %d at %.3f (clip %.3f, window from %.3f) ttc %.3f state %s window %.3f spam %d dist %.2f" % [i, now - t0,
							boss.anim.time, float(h["from"]), ttc, Player.S.keys()[player.state], player.guard_window, player.spam_level,
							boss.distance_to_opponent()])
				break
		broke = broke or player.state == Player.S.GUARD_BREAK
		await ticks(1)
	player.bot_move = Vector2.ZERO
	for k in 20:
		broke = broke or player.state == Player.S.GUARD_BREAK
		await ticks(1)
	var res: Array = []
	var times: Array = []
	for rr in _results:
		res.append(res_name(int(rr["res"])))
		times.append(snappedf(float(rr["t"]) - t0, 0.01))
	var gaps: Array = []
	for i in range(1, times.size()):
		gaps.append(snappedf(float(times[i]) - float(times[i - 1]), 0.01))
	return {"res": res, "times": times, "gaps": gaps, "posture": boss.posture - p0, "broke": broke}


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


## Shuriken volleys: he leaps back and throws 3 fast + 1 delayed, or 5 fast; from phase 2 on,
## two sets, the second from the ground straight after the first. Every throw can be deflected
## (a little posture to him) or blocked, and hits if ignored.
func suite_shuriken() -> void:
	# Phase 1 throws one set; phase 2 on, the same volleys come twice.
	for ph in [1, 2, 3]:
		await setup(3.0)
		boss.phase = ph
		var picked := []
		for seq in ["shuriken_4", "shuriken_5"]:
			boss._start_sequence(seq)
			picked.append(boss.anim.clip.name)
		var want := ["b_shuriken_4", "b_shuriken_5"] if ph == 1 else ["b_shuriken_4x2", "b_shuriken_5x2"]
		check(picked == want, "phase %d: his volleys are %s (%s)" % [ph, "one set" if ph == 1 else "two sets", str(picked)])
	for clip in ["b_shuriken_4", "b_shuriken_5", "b_shuriken_4x2", "b_shuriken_5x2"]:
		var n_throws: int = {"b_shuriken_4": 4, "b_shuriken_5": 5, "b_shuriken_4x2": 8, "b_shuriken_5x2": 10}[clip]
		# Arrival times against a player standing still.
		await setup(3.0)
		var t0 := boss_attack(clip)
		await run_until_boss_done(4.0)
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
		if clip.begins_with("b_shuriken_4"):
			for k in range(0, gaps.size(), 4):
				check(float(gaps[k]) < 0.22 and float(gaps[k + 1]) < 0.22 and float(gaps[k + 2]) > 0.3,
					"%s: set %d is 3 fast + 1 delayed (gaps %s)" % [clip, k / 4 + 1, str(gaps.slice(k, k + 3))])
		else:
			for k in gaps.size():
				if k != 4:
					check(float(gaps[k]) < 0.22, "%s throws come fast (gap %.2f)" % [clip, float(gaps[k])])
		if n_throws > 5:
			# The second set comes straight after the first: a short pause, not a new attack.
			var between := float(gaps[3 if n_throws == 8 else 4])
			check(between > 0.2 and between < 0.65,
				"%s: the second set follows straight after the first (%.2f s)" % [clip, between])
		check(float(arrivals[0]) > 0.6, "the first shuriken arrives after a readable tell (%.2f s)" % float(arrivals[0]))
		# Deflect each one as it reaches you (a tap 80 ms before, as a player reacting to it): each
		# costs him a little posture, and he doesn't flinch.
		await setup(3.0)
		t0 = boss_attack(clip)
		var answered := {}
		var release_at := -1.0
		var peak := 0.0
		var reacted := false
		var t_end := Game.clock + 4.0
		while Game.clock < t_end:
			await ticks(1)
			release_at = _tap_incoming(answered, release_at)
			peak = maxf(peak, boss.posture)
			reacted = reacted or boss.state == Boss.S.REACT or boss.state == Boss.S.STAGGER
		var got := _results.map(func(r): return res_name(int(r["res"])))
		check(got.count("DEFLECT") == n_throws, "%s: every throw deflected on time (%s)" % [clip, str(got)])
		var want := SHURIKEN_POSTURE * n_throws
		check(absf(peak - want) < 0.01 and not reacted,
			"%s: each deflected shuriken costs him %.0f posture, no flinch (%.1f of %.0f, reacted %s)" % [clip,
				SHURIKEN_POSTURE, peak, want, reacted])
		if clip == "b_shuriken_5":
			# One that fills his posture while he's in the air breaks him as he lands.
			await setup(3.0)
			boss.add_posture(boss.max_posture - 2.0, false)
			t0 = boss_attack(clip)
			_deflect_arrivals(t0, arrivals)
			var in_air_at_first := false
			var broke_at := -1.0
			var grounded_at_break := false
			t_end = Game.clock + 3.0
			while Game.clock < t_end and broke_at < 0.0:
				var n_before := _results.size()
				await ticks(1)
				if n_before == 0 and _results.size() > 0:
					in_air_at_first = boss._airborne()
				if boss.state == Boss.S.STAGGER:
					broke_at = Game.clock - t0
					grounded_at_break = not boss._airborne()
			var first_at := float(_results[0]["t"]) - t0 if _results.size() > 0 else -1.0
			check(in_air_at_first and broke_at > first_at and grounded_at_break,
				"a shuriken deflected in the air that fills his posture breaks him as he lands (deflected at %.2f s in the air %s, broke at %.2f s on the ground %s)" % [
					first_at, in_air_at_first, broke_at, grounded_at_break])
		# Holding guard blocks them all.
		await setup(3.0)
		t0 = boss_attack(clip)
		at(t0 + 0.1, func(): player.press_guard(t0 + 0.1))
		await run_until_boss_done(4.0)
		await ticks(60)
		got = _results.map(func(r): return res_name(int(r["res"])))
		check(got.count("BLOCK") == n_throws, "%s: holding guard blocks every throw (%s)" % [clip, str(got)])
		player.release_guard(Game.clock)


## Taps guard 80 ms before each shuriken in flight reaches you, releasing 40 ms later, as a
## player reacting to them would (a schedule measured against a player standing still drifts
## over a long volley, since each deflect moves you a little). `answered`: the ones already
## met; returns when to release.
func _tap_incoming(answered: Dictionary, release_at: float, lead := 0.08) -> float:
	if release_at > 0.0 and Game.clock >= release_at:
		player.release_guard(Game.clock)
		release_at = -1.0
	for n in player.get_parent().get_children():
		if n is Shuriken and (n as Shuriken)._flying and not answered.has(n.get_instance_id()):
			var cap := player.hurt_capsule()
			var q := Geometry3D.get_closest_point_to_segment(n.global_position, cap[0], cap[1])
			if (q.distance_to(n.global_position) - float(cap[2])) / Shuriken.SPEED <= lead:
				answered[n.get_instance_id()] = true
				if player.guard_held:
					player.release_guard(Game.clock)
				player.press_guard(Game.clock)
				release_at = Game.clock + 0.04
	return release_at


## Taps guard 80 ms before each shuriken lands (`arrivals` from the throw at `t0`).
func _deflect_arrivals(t0: float, arrivals: Array) -> void:
	for a in arrivals:
		var pt: float = t0 + float(a) - 0.08
		at(pt, func(): player.press_guard(pt))
		at(pt + 0.04, func(): player.release_guard(pt + 0.04))


## The menus with a gamepad only (simulated pad events through the real input pipeline): the
## title menu boots with an item highlighted, the D-pad and the left stick move one row per
## press, A presses, left / right change an option, B goes back, Start pauses the fight and A on
## Resume carries on. Closing a menu lets go of the highlight so A in the fight can't press it.
## The hint bar shows the keyboard's keys until a pad is used, then the pad's buttons.
func suite_menu() -> void:
	var saved := [Game.start_phase, Game.debug, Game.save_enabled]
	Game.save_enabled = false
	Game.skip_title = false
	Game.start_phase = 1
	Game.debug = false
	if world != null:
		world.queue_free()
		world = null
	GameInput.gamepad = false
	var main: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(main)
	await ticks(10)
	var menu: GameMenu = main.get("menu")
	var focus := func() -> String:
		var f := get_viewport().gui_get_focus_owner()
		return (f as Button).text if f is Button else "(none)"
	check(menu.is_open() and str(focus.call()) == "Start fight", "title menu opens with Start fight highlighted (%s)" % focus.call())
	check("Enter" in _hint_keys(menu), "the hints show the keyboard's keys (%s)" % [_hint_keys(menu)])
	await _pad_button(JOY_BUTTON_DPAD_DOWN)
	check(str(focus.call()) == "Options", "D-pad down highlights Options (%s)" % focus.call())
	check(GameInput.gamepad and "A" in _hint_keys(menu) and not "Enter" in _hint_keys(menu),
		"once a pad is used, the hints show its buttons (%s)" % [_hint_keys(menu)])
	await _pad_stick(JOY_AXIS_LEFT_Y, [0.3, 0.7, 0.9, 1.0, 0.8, 0.2, 0.0])
	check(str(focus.call()) == "Controls", "one push of the stick moves one row (%s)" % focus.call())
	await _pad_stick(JOY_AXIS_LEFT_Y, [-0.5, -0.9, -1.0, -0.4, 0.0])
	check(str(focus.call()) == "Options", "a push up moves one row back (%s)" % focus.call())
	await _pad_button(JOY_BUTTON_A)
	check(menu._page == "options", "A on Options opens the Options page (%s)" % menu._page)
	check(str(focus.call()).begins_with("Starting phase"), "Options opens on Starting phase (%s)" % focus.call())
	await _pad_button(JOY_BUTTON_DPAD_RIGHT)
	check(Game.start_phase == 2, "D-pad right steps the starting phase to 2 (%d)" % Game.start_phase)
	await _pad_stick(JOY_AXIS_LEFT_X, [0.8, 1.0, 0.0])
	check(Game.start_phase == 3, "stick right steps it to 3 (%d)" % Game.start_phase)
	await _pad_button(JOY_BUTTON_A)
	check(Game.start_phase == 1, "A on the option steps it round to 1 (%d)" % Game.start_phase)
	await _pad_button(JOY_BUTTON_DPAD_DOWN)
	await _pad_button(JOY_BUTTON_DPAD_RIGHT)
	check(Game.debug, "D-pad right on Diagnostics turns it on")
	await _pad_button(JOY_BUTTON_DPAD_LEFT)
	check(not Game.debug, "D-pad left turns it off again")
	await _pad_button(JOY_BUTTON_B)
	check(menu._page == "title" and str(focus.call()) == "Options", "B goes back to the title menu, on Options (%s, %s)" % [
		menu._page, focus.call()])
	# Lore: the whole Chronicle of the Dried Root, in type too small to read.
	await _pad_button(JOY_BUTTON_DPAD_DOWN)
	await _pad_button(JOY_BUTTON_DPAD_DOWN)
	check(str(focus.call()) == "Lore", "Lore sits below Controls (%s)" % focus.call())
	await _pad_button(JOY_BUTTON_A)
	await ticks(2)
	var lore: LoreSheet = menu._lore
	var shown := lore.body.get_parsed_text()
	var px := lore.body.get_theme_font_size("normal_font_size")
	var bottom := lore.body.get_global_rect().end.y
	check(menu._page == "lore" and lore.is_visible_in_tree() and not menu._controls.visible and str(focus.call()) == "Back",
		"A on Lore opens the Lore page, on Back (%s, %s)" % [menu._page, focus.call()])
	check(shown.length() > 26000 and shown.begins_with("The castle was called Nagatsuki") and shown.strip_edges().ends_with("with dried root."),
		"the Lore page shows the whole chronicle (%d characters)" % shown.length())
	check(px <= 5 and bottom < 1000.0,
		"in comically small type (%d px on the 1080p canvas), all of it on one screen (it ends %.0f px down)" % [px, bottom])
	await _pad_button(JOY_BUTTON_B)
	check(menu._page == "title" and str(focus.call()) == "Lore", "B goes back to the title menu, on Lore (%s, %s)" % [
		menu._page, focus.call()])
	await _pad_button(JOY_BUTTON_DPAD_UP)
	await _pad_button(JOY_BUTTON_DPAD_UP)
	await _pad_button(JOY_BUTTON_DPAD_UP)
	await _pad_button(JOY_BUTTON_DPAD_UP)
	check(str(focus.call()) == "Quit", "D-pad up wraps round from the top to Quit (%s)" % focus.call())
	await _pad_button(JOY_BUTTON_DPAD_DOWN)
	check(str(focus.call()) == "Start fight", "and down wraps back to Start fight (%s)" % focus.call())
	await _pad_button(JOY_BUTTON_A)
	await ticks(4)
	check(not menu.is_open() and int(main.get("flow")) != 4, "A on Start fight starts the fight (flow %d)" % int(main.get("flow")))
	check(str(focus.call()) == "(none)", "the menu lets go of the highlight once closed (%s)" % focus.call())
	await _pad_button(JOY_BUTTON_START)
	check(get_tree().paused and menu.is_open() and menu._page == "pause", "Start pauses the fight into the pause menu")
	check(str(focus.call()) == "Resume", "the pause menu opens on Resume (%s)" % focus.call())
	var items := menu._buttons.get_children().map(func(c): return (c as Button).text)
	check("Lore" in items, "the pause menu has Lore too (%s)" % ", ".join(items))
	await _pad_button(JOY_BUTTON_DPAD_DOWN)
	await _pad_button(JOY_BUTTON_DPAD_DOWN)
	await _pad_button(JOY_BUTTON_A)
	check(menu._page == "options", "A on Options (pause menu) opens Options (%s)" % menu._page)
	await _pad_button(JOY_BUTTON_B)
	check(menu._page == "pause" and str(focus.call()) == "Options", "B goes back to the pause menu, on Options (%s, %s)" % [
		menu._page, focus.call()])
	await _pad_button(JOY_BUTTON_DPAD_UP)
	await _pad_button(JOY_BUTTON_DPAD_UP)
	check(str(focus.call()) == "Resume", "up twice reaches Resume (%s)" % focus.call())
	await _pad_button(JOY_BUTTON_A)
	await ticks(4)
	check(not get_tree().paused and not menu.is_open(), "A on Resume carries on with the fight")
	await _pad_button(JOY_BUTTON_START)
	await _pad_button(JOY_BUTTON_B)
	check(not get_tree().paused and not menu.is_open(), "B on the pause menu resumes too")
	get_tree().paused = false
	main.queue_free()
	await ticks(2)
	Game.camera = null
	Game.hud = null
	Game.player = null
	Game.boss = null
	Game.clear_time_effects()
	Game.start_phase = int(saved[0])
	Game.debug = bool(saved[1])
	Game.save_enabled = bool(saved[2])
	GameInput.gamepad = false


## The ribbons and his mane (SpringChain): cloth and hair should sway and trail, not buzz. First a
## bench, the scarf's settings on a synthetic anchor that walks (bobbing and swaying as a body
## does) and turns on the spot: its tip must move smoothly and slowly and the chain must never
## fold up. Then the real arena: every tip while you both stand and while you walk round him must
## move at under 2.5 Hz (RMS frequency: velocity and acceleration together), and through his combo
## his hair and sashes must move no quicker than his body does (the chain smooths its anchor's
## motion instead of adding its own). The old solver buzzed at 5-9 Hz and snaked when towed.
##
## For tuning: RIBBON_SET="flutter=0,breeze=0" sets those on every chain, RIBBON_NOCOLLIDE=1 drops
## the colliders, RIBBON_DUMP=<file.json> writes every tip and root track (world space, per
## scenario), and RIBBON_BENCH=1 runs only the bench (with RIBBON_SET) and dumps it.
func suite_ribbons() -> void:
	var scarf: Dictionary = (_models_json()["player"]["chains"] as Array)[0]
	var bench := {}
	for motion in ["walk", "turn"]:
		bench[motion] = await _ribbon_bench(scarf, motion)
	if OS.get_environment("RIBBON_BENCH") != "":
		_ribbon_dump_write({"bench": bench})
		return
	var walk := _track_stats(bench["walk"])
	var turn := _track_stats(bench["turn"])
	print("  bench: walking, tip %.2f m/s at %.1f Hz (anchor %.2f at %.1f); turning, tip %.2f m/s at %.1f Hz" % [
		walk["tip"], walk["tip_hz"], walk["root"], walk["root_hz"], turn["tip"], turn["tip_hz"]])
	check(walk["tip"] < 1.5 and walk["tip_hz"] < 2.5,
		"a scarf on a walking body sways and ripples slowly (tip %.2f m/s at %.1f Hz)" % [walk["tip"], walk["tip_hz"]])
	check(walk["fold"] > 0.7 and turn["fold"] > 0.7,
		"towed or turned, the chain never folds up (tip at least %.0f%% / %.0f%% of its length from the root)" % [
		walk["fold"] * 100.0, turn["fold"] * 100.0])
	var saved := [Game.skip_title, Game.start_phase]
	Game.skip_title = true
	Game.start_phase = 1
	if world != null:
		world.queue_free()
		world = null
	var main: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(main)
	await ticks(4)
	var p: Player = main.get("player")
	var b: Boss = main.get("boss")
	b.set_passive(true)
	await ticks(320)                          # the intro plays out and the fight starts
	p.bot_enabled = true
	b.global_position = Vector3(0, 0, -1.5)
	p.global_position = Vector3(0, 0, 1.5)
	p.face_now(b.global_position)
	b.face_now(p.global_position)
	await ticks(240)
	var chains: Array = []
	for who in [p, b]:
		for c in (who as Node).find_children("*", "SpringChain", true, false):
			c.set_meta("who", "you" if who == p else "him")
			chains.append(c)
	if OS.get_environment("RIBBON_NOCOLLIDE") != "":
		for c in chains:
			c.colliders = []
	for kv in OS.get_environment("RIBBON_SET").split(",", false):
		var parts := kv.split("=")
		var key := parts[0].strip_edges()
		var only := ""                    # "you.chest:flutter=9": only chains named "you, chest ..."
		if key.contains(":"):
			only = key.get_slice(":", 0).replace(".", ", ")
			key = key.get_slice(":", 1)
		for c in chains:
			var name := "%s, %s" % [c.get_meta("who", "?"), c.anchor.name]
			if only == "" or name == only:
				c.set(key, float(parts[1]))
	var dump := {"bench": bench}
	dump["standing"] = await _chain_tracks(chains, 360)
	p.bot_move = Vector2(1, 0)
	dump["walking round him"] = await _chain_tracks(chains, 240)
	p.bot_move = Vector2.ZERO
	p.press_action("dodge", Game.clock)
	dump["after a dodge"] = await _chain_tracks(chains, 180)
	b.set_passive(false)
	b._seq.clear()
	b._seq.append(["b_combo_2", 1.0])
	b._seq.append(["b_combo_3", 1.0])
	b.face_now(p.global_position)
	b._play_attack("b_combo_1", 0.0)
	b.set_passive(true)
	dump["his combo"] = await _chain_tracks(chains, 300)
	if OS.get_environment("RIBBON_DUMP") != "":
		_ribbon_dump_write(dump)
	for scen in ["standing", "walking round him", "after a dodge", "his combo"]:
		var worst_hz := 0.0
		var worst_speed := 0.0
		var body_hz := 0.0
		var hair_hz := 0.0
		var n_him := 0
		for chain in dump[scen]:
			var st := _track_stats(dump[scen][chain])
			worst_hz = maxf(worst_hz, st["tip_hz"])
			worst_speed = maxf(worst_speed, st["tip"])
			if verbose:
				print("    %-18s %-16s tip %5.2f m/s %4.1f Hz   root %5.2f m/s %4.1f Hz" % [scen, chain, st["tip"],
					st["tip_hz"], st["root"], st["root_hz"]])
			if str(chain).begins_with("him") and not str(chain).contains("weapon"):
				body_hz += st["root_hz"]
				hair_hz += st["tip_hz"]
				n_him += 1
		print("  %s: fastest tip %.2f m/s, quickest %.1f Hz" % [scen, worst_speed, worst_hz])
		if scen == "standing" or scen == "walking round him":
			check(worst_hz < 2.5, "%s, every ribbon and his hair sway slowly (quickest tip %.1f Hz)" % [scen, worst_hz])
		if scen == "his combo":
			check(hair_hz <= body_hz, "through his combo his hair and sashes move no quicker than his body (%.1f Hz, body %.1f Hz)" % [
				hair_hz / maxf(1.0, n_him), body_hz / maxf(1.0, n_him)])
	main.queue_free()
	await ticks(2)
	Game.camera = null
	Game.hud = null
	Game.player = null
	Game.boss = null
	Game.skip_title = bool(saved[0])
	Game.start_phase = int(saved[1])


func _models_json() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://data/models.json"))


func _ribbon_dump_write(dump: Dictionary) -> void:
	var f := FileAccess.open(OS.get_environment("RIBBON_DUMP"), FileAccess.WRITE)
	f.store_string(JSON.stringify(dump))
	f.close()


## One chain with `spec`'s settings (as in data/models.json) on a synthetic anchor, away from any
## fighter: `motion` is "walk" (forward at 1.4 m/s, bobbing 3 cm at 2 Hz and swaying 2 cm at 1 Hz)
## or "turn" (on the spot at 1.5 rad/s). Its tip's and root's world tracks after a second.
func _ribbon_bench(spec: Dictionary, motion: String, n := 480) -> Dictionary:
	var anchor := Node3D.new()
	add_child(anchor)
	anchor.global_position = Vector3(40, 1.4, 0)
	var c := SpringChain.new()
	c.setup(anchor, StandardMaterial3D.new())
	var rd: Array = spec["rest_dir"]
	c.rest_dir = Vector3(rd[0], rd[1], rd[2])
	c.segments = int(spec["segments"])
	c.seg_len = float(spec["seg_len"])
	for key in ["gravity", "sway_hz", "sway_damping", "air_drag", "edge_drag", "breeze", "flutter", "flutter_hz",
			"max_speed"]:
		if spec.has(key):
			c.set(key, float(spec[key]))
	for kv in OS.get_environment("RIBBON_SET").split(",", false):
		var parts := kv.split("=")
		c.set(parts[0].strip_edges().get_slice(":", parts[0].count(":")), float(parts[1]))
	add_child(c)
	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	var track := []
	for i in n + 120:
		var t := float(i) * dt
		if motion == "walk":
			anchor.global_position = Vector3(40.0 + 0.02 * sin(TAU * t), 1.4 + 0.03 * sin(TAU * 2.0 * t), -1.4 * t)
		else:
			anchor.global_transform = Transform3D(Basis(Vector3.UP, 1.5 * t), Vector3(40, 1.4, 0))
		await ticks(1)
		if i >= 120:
			var tip: Vector3 = c._pts[c.segments]
			var root: Vector3 = c._pts[0]
			track.append([tip.x, tip.y, tip.z, root.x, root.y, root.z, c.seg_len * c.segments])
	c.queue_free()
	anchor.queue_free()
	return {"world": track}


## Every chain's tip and root in world space for `n` ticks: {"who, anchor k": {"world": [[tip, root,
## length]...]}}.
func _chain_tracks(chains: Array, n: int) -> Dictionary:
	var out := {}
	var names := []
	for k in chains.size():
		var c: SpringChain = chains[k]
		names.append("%s, %s %d" % [c.get_meta("who", "?"), c.anchor.name, k])
		out[names[k]] = {"world": []}
	for _i in n:
		await ticks(1)
		for k in chains.size():
			var c: SpringChain = chains[k]
			var tip: Vector3 = c._pts[c.segments]
			var root: Vector3 = c._pts[0]
			(out[names[k]]["world"] as Array).append([tip.x, tip.y, tip.z, root.x, root.y, root.z, c.seg_len * c.segments])
	return out


## A track's tip and root: RMS speed (m/s, steady drift removed) and RMS frequency (Hz: how quick
## the motion is, from velocity and acceleration together), and how close the tip came to the root
## as a share of the chain's length (a folded chain comes close).
func _track_stats(entry: Dictionary) -> Dictionary:
	var tr: Array = entry["world"]
	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	var out := {"fold": 1.0}
	for part in ["tip", "root"]:
		var o := 0 if part == "tip" else 3
		var vs: Array = []
		for i in range(1, tr.size()):
			var a: Array = tr[i - 1]
			var b: Array = tr[i]
			vs.append(Vector3(b[o] - a[o], b[o + 1] - a[o + 1], b[o + 2] - a[o + 2]) / dt)
		var vmean := Vector3.ZERO
		for v: Vector3 in vs:
			vmean += v
		vmean /= float(vs.size())
		var v2 := 0.0
		var a2 := 0.0
		for i in vs.size():
			v2 += ((vs[i] as Vector3) - vmean).length_squared()
			if i > 0:
				a2 += (((vs[i] as Vector3) - (vs[i - 1] as Vector3)) / dt).length_squared()
		v2 /= float(vs.size())
		a2 /= float(vs.size() - 1)
		out[part] = sqrt(v2)
		out[part + "_hz"] = sqrt(a2 / maxf(v2, 1e-9)) / TAU
	for q: Array in tr:
		var d := Vector3(q[0] - q[3], q[1] - q[4], q[2] - q[5]).length()
		out["fold"] = minf(out["fold"], d / float(q[6]))
	return out


## The lock-on camera at the plaza's rim, in the real arena: the invisible wall that keeps the
## fighters in must not squeeze the camera onto your back (it pulled in to 0.4 m); the camera
## swings out over the low fence instead. The wall must still stop both fighters.
func suite_camera() -> void:
	var saved := [Game.skip_title, Game.start_phase]
	Game.skip_title = true
	Game.start_phase = 1
	if world != null:
		world.queue_free()
		world = null
	var main: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(main)
	await ticks(4)
	var p: Player = main.get("player")
	var b: Boss = main.get("boss")
	var cam: CombatCamera = main.get("camera")
	var rim: float = (main.get("arena") as Arena).radius
	b.set_passive(true)
	await ticks(320)                          # the intro plays out and the fight starts
	b.global_position = Vector3.ZERO
	var lens := PackedFloat32Array()
	for k in 8:
		var a := TAU * float(k) / 8.0 + 0.2
		p.global_position = Combat.dir_of(a) * (rim - 0.7)
		p.face_now(b.global_position)
		p.locked = true
		await ticks(90)
		var shortest := 99.0
		for _i in 12:
			shortest = minf(shortest, cam.arm.get_hit_length())
			await ticks(1)
		lens.append(shortest)
	var worst := 99.0
	for l in lens:
		worst = minf(worst, l)
	print("  camera distance with your back to the fence, 8 places round the rim: %s" % " ".join(
		Array(lens).map(func(l): return "%.2f" % l)))
	check(worst >= 3.0, "at the rim the lock-on camera keeps its distance (shortest %.2f m, normal %.1f m)" % [worst, cam.distance])
	# Walk away from him, into the wall, for a while: it still holds.
	var far := 0.0
	for k in 3:
		var a := TAU * float(k) / 3.0 + 0.5
		p.global_position = Combat.dir_of(a) * (rim - 3.0)
		p.face_now(b.global_position)
		p.bot_enabled = true
		p.bot_move = Vector2(0, 1)
		await ticks(360)
		p.bot_move = Vector2.ZERO
		far = maxf(far, Combat.flat(p.global_position).length())
	check(far < rim - 0.1, "walking out against the wall keeps you inside the fence (%.2f m of %.1f)" % [far, rim])
	# Shove him outward at the wall too.
	var bfar := 0.0
	for k in 3:
		var a := TAU * float(k) / 3.0 + 1.1
		b.global_position = Combat.dir_of(a) * (rim - 2.0)
		p.global_position = Combat.dir_of(a) * (rim - 5.0)
		for _i in 90:
			b.push(Combat.dir_of(a) * 9.0)
			await ticks(1)
		await ticks(30)
		bfar = maxf(bfar, Combat.flat(b.global_position).length())
	check(bfar < rim - 0.1, "shoving him out against the wall keeps him inside the fence (%.2f m of %.1f)" % [bfar, rim])
	main.queue_free()
	await ticks(2)
	Game.camera = null
	Game.hud = null
	Game.player = null
	Game.boss = null
	Game.clear_time_effects()
	Game.skip_title = bool(saved[0])
	Game.start_phase = int(saved[1])


## A pad button press and release, as a pad sends them (device 0), a few frames apart.
## The keys and buttons the menu's hint bar shows.
func _hint_keys(menu: GameMenu) -> Array:
	var keys := []
	for c in (menu.get("_hints") as Node).find_children("*", "Control", true, false):
		if c is UiTheme.Chip:
			keys.append((c as UiTheme.Chip).key)
	return keys


func _pad_button(button: JoyButton) -> void:
	for pressed in [true, false]:
		var ev := InputEventJoypadButton.new()
		ev.device = 0
		ev.button_index = button
		ev.pressed = pressed
		ev.pressure = 1.0 if pressed else 0.0
		Input.parse_input_event(ev)
		await get_tree().process_frame
		await get_tree().process_frame


## A stick movement: the axis passes through `values`, one event per frame.
func _pad_stick(axis: JoyAxis, values: Array) -> void:
	for v in values:
		var ev := InputEventJoypadMotion.new()
		ev.device = 0
		ev.axis = axis
		ev.axis_value = float(v)
		Input.parse_input_event(ev)
		await get_tree().process_frame


## Three lives, one per phase. The starting-phase option starts a fight in a later phase with
## the earlier lives taken; each deathblow raises him into the next phase, and the third one
## ends the fight. Phase 3 is a copy of phase 2 for now.
func suite_phases() -> void:
	for n in [1, 2, 3]:
		await setup(3.0)
		boss.set_start_phase(n)
		var want: Dictionary = Boss.PHASES.get(n, {"attack_speed": 1.0, "aggression": 1.0})
		check(boss.phase == n and boss.lives_left == Combat.BOSS_LIVES - (n - 1) and boss.hp == boss.max_hp,
			"start in phase %d: phase %d, lives %d, full vitality" % [n, boss.phase, boss.lives_left])
		check(is_equal_approx(boss.attack_speed, float(want["attack_speed"])) and is_equal_approx(boss.aggression,
			float(want["aggression"])), "phase %d tuning (speed %.2f, aggression %.2f)" % [n, boss.attack_speed, boss.aggression])
	await setup(3.0)
	var row := PackedStringArray()
	for k in Combat.BOSS_LIVES:
		boss._posture_break()
		boss.begin_deathblow(player)
		var t_end := Game.clock + 12.0
		while Game.clock < t_end and boss.state != Boss.S.NEUTRAL and boss.state != Boss.S.DEAD:
			await ticks(1)
		row.append("deathblow %d -> %s, phase %d, lives %d" % [k + 1, Boss.S.keys()[boss.state], boss.phase, boss.lives_left])
		if k + 1 < Combat.BOSS_LIVES:
			check(boss.state == Boss.S.NEUTRAL and boss.phase == k + 2 and boss.lives_left == Combat.BOSS_LIVES - k - 1,
				"deathblow %d raises him into phase %d (%s)" % [k + 1, k + 2, row[k]])
		else:
			check(boss.state == Boss.S.DEAD and boss.lives_left == 0, "the last deathblow ends the fight (%s)" % row[k])
	print("  " + "; ".join(row))


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
	boss.struck.connect(func(r, _point):
		if int(r) == Combat.RESULT_HIT and boss.state == Boss.S.REACT:
			cur[1] = int(cur[1]) + 1)
	var handled := {}
	var serial := [0, ""]
	var next_attack := 0.0
	var breaks := [0]
	boss.posture_broken.connect(func(): breaks[0] += 1)
	var ibot := {"jumped": [-1]}
	while Game.clock < t_end:
		await ticks(1)
		var now := Game.clock
		if boss.state == Boss.S.INFERNO:          # phase 2's fire move: get clear, jump the arms
			_inferno_bot_tick("escape", ibot)
			prev_state[0] = boss.state
			continue
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
		boss.struck.connect(func(r, _point):
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
		check(got.has("B") or got.has("D") or player.hp < player.max_hp or boss.escape_count > 0,
			"%s: he stops the mash (guards, parries, escapes or hits back)" % clip)


## Getting out of trouble, and moving like a fighter. A pummeling (he's reeling and you keep
## hitting): he takes a few hits (3 in his first life, 2 or 3 in his second, 2 in his last),
## then escapes instead of reeling again, a different way each time (never the same twice
## running), and only where there's room for it (not backwards into the wall). Running round
## you to a new spot: he backs off facing you, then runs an arc (never his back to you up
## close, never nearer than he started), his speed building and easing off with no jumps,
## stays inside the plaza, and squares up to you before he acts.
func suite_escape() -> void:
	for ph in [1, 2, 3]:
		var hist: Array = []
		var kinds := {}
		var runs: Array = []
		var repeats := 0
		var over := 0
		var endure_max := 3 if ph < 3 else 2
		for trial in 12:
			seed(5100 + 37 * ph + trial)
			var r := await _pummel_run(ph, hist, Vector3.ZERO)
			hist = r["hist"]
			runs.append("%d%s" % [r["hits"], str(r["out"]).substr(0, 3)])
			if int(r["hits"]) > endure_max:
				over += 1
			if str(r["out"]) != "attack" and str(r["out"]) != "none":
				kinds[r["out"]] = true
		for k in range(hist.size() - 1):
			if str(hist[k]) == str(hist[k + 1]):
				repeats += 1
		print("  phase %d pummelings (hits, then how he got out): %s   escapes used: %s" % [ph, " ".join(runs), ", ".join(kinds.keys())])
		check(over == 0, "phase %d: he reels from at most %d hits, then gets out of it (%d runs went over)" % [ph, endure_max, over])
		check(kinds.size() >= 4, "phase %d: he escapes in at least 4 different ways over 12 pummelings (%d)" % [ph, kinds.size()])
		check(repeats == 0, "phase %d: never the same escape twice running (%s)" % [ph, str(hist)])
	# Backed up against the wall: no leaping, volleying or hopping backwards into it.
	var wall_bad := 0
	var wall_kinds := {}
	for trial in 10:
		seed(6200 + trial)
		var r := await _pummel_run(2, [], Vector3(0, 0, -11.6))
		if str(r["out"]) in ["evade", "shuriken", "retreat"]:
			wall_bad += 1
		wall_kinds[r["out"]] = true
	print("  back to the wall: %s" % ", ".join(wall_kinds.keys()))
	check(wall_bad == 0, "with his back to the wall he escapes aside or through you, never backwards (%d)" % wall_bad)
	# Running round you.
	for sd in [11, 12, 13, 14, 15, 16]:
		seed(sd)
		var near_wall: bool = int(sd) >= 15
		await setup(2.4)
		if near_wall:
			# (both of you near the wall: he has to run round inside it)
			boss.global_position = Vector3(0, 0, -10.8)
			player.global_position = Vector3(0, 0, -8.4)
			player.face_now(boss.global_position)
			boss.face_now(player.global_position)
		boss.passive = false
		boss.cooldown = 99.0
		boss._begin_action("reposition", boss.distance_to_opponent())
		var a0 := Combat.yaw_of(Combat.flat(boss.global_position - player.global_position))
		var prev_v := Vector3.ZERO
		var max_acc := 0.0
		var min_d := 99.0
		var back_close := 0.0
		var max_r := 0.0
		var squared := 999.0
		var t0 := Game.clock
		while boss.state == Boss.S.NEUTRAL and boss._mode == "reposition" and Game.clock - t0 < 6.0:
			await ticks(1)
			var v := boss._move_vel
			max_acc = maxf(max_acc, (v - prev_v).length() / DT)
			prev_v = v
			var d := boss.distance_to_opponent()
			min_d = minf(min_d, d)
			max_r = maxf(max_r, Combat.flat(boss.global_position).length())
			var away := Combat.angle_to(boss.global_position, boss.forward(), player.global_position)
			if d < 3.2:
				back_close = maxf(back_close, away)
			squared = away
		var turned := rad_to_deg(absf(wrapf(Combat.yaw_of(Combat.flat(boss.global_position - player.global_position)) - a0, -PI, PI)))
		var dist := boss.distance_to_opponent()
		print("  run %d%s: %.1f s, %.0f° round you to %.1f m, closest %.2f m, facing away up close at most %.0f°, max accel %.1f m/s², " % [
			sd, " (by the wall)" if near_wall else "", Game.clock - t0, turned, dist, min_d, back_close, max_acc] +
			"furthest from the centre %.1f m, facing you %.0f° off when he acts" % [max_r, squared])
		check(max_acc <= Boss.CHARGE_ACCEL + 0.5, "run %d: his speed builds and eases off (max %.1f m/s²)" % [sd, max_acc])
		check(back_close <= 100.0, "run %d: never his back to you up close (%.0f°)" % [sd, back_close])
		check(min_d >= 2.2, "run %d: he never runs nearer to you than he started (%.2f m)" % [sd, min_d])
		check(turned >= 45.0 and dist >= 3.4 and dist <= 7.6, "run %d: he ends up somewhere else round you (%.0f°, %.1f m)" % [sd, turned, dist])
		check(squared <= 25.0, "run %d: he squares up to you before he acts (%.0f° off)" % [sd, squared])
		check(max_r <= Boss.ARENA_RADIUS - 0.3, "run %d: he stays inside the plaza (%.1f m from the centre)" % [sd, max_r])


## One pummeling: he's reeling (a deflected final blow's recoil) and you mash attack at him.
## Returns how many hits left him reeling before he got out of it, and how: an escape (its
## kind), "attack" (he went straight back on the attack) or "none".
func _pummel_run(ph: int, hist: Array, at_pos: Vector3) -> Dictionary:
	await setup(2.2)
	if at_pos != Vector3.ZERO:
		boss.global_position = at_pos
		player.global_position = at_pos + Vector3(0, 0, 2.2)
		boss.face_now(player.global_position)
		player.face_now(boss.global_position)
	if ph > 1:
		boss._enter_phase(ph, false)
	boss.passive = false
	boss._escapes = hist.duplicate()
	player.max_hp = 1.0e6
	player.hp = player.max_hp
	var hits := [0]
	boss.struck.connect(func(r, _point):
		if int(r) == Combat.RESULT_HIT and boss.state == Boss.S.REACT:
			hits[0] += 1)
	boss._react("b_recoil")
	var n0 := boss.escape_count
	var out := "none"
	var t_end := Game.clock + 4.0
	var next := Game.clock
	while Game.clock < t_end:
		await ticks(1)
		var now := Game.clock
		player.camera_yaw = Combat.yaw_of(Combat.flat(boss.global_position - player.global_position))
		if boss.escape_count > n0:
			out = str(boss._escapes[0])
			break
		if boss.state == Boss.S.ATTACK and boss._seq_name != "":
			out = "attack"
			break
		if now >= next and boss.distance_to_opponent() < 2.8:
			player.press_action("attack", now)
			next = now + 0.1
	return {"hits": hits[0], "out": out, "hist": boss._escapes.duplicate()}


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
## held during the committed swing is queued until the recovery.
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
	# A tap released early in the committed swing must not open a fresh deflect window in the
	# recovery 0.3 s later, when the button has long been up (it outlives the input buffer)...
	await setup(3.5)
	boss.set_facing(PI)
	player.press_action("attack", Game.clock)
	await ticks(12)
	check(player.state == Player.S.ATTACK and not player._can_guard_now(),
		"guard-release probe begins in the committed swing")
	player.press_guard(Game.clock)
	await ticks(2)
	player.release_guard(Game.clock)
	await ticks(38)
	check(not player._pending_guard and player.state != Player.S.GUARD,
		"a tap long before the recovery doesn't come up in it (%s)" % Player.S.keys()[player.state])
	# ...but one a moment before the recovery opens still comes up with it (input buffer).
	await setup(3.5)
	boss.set_facing(PI)
	player.press_action("attack", Game.clock)
	await ticks(36)
	check(player.state == Player.S.ATTACK and not player._can_guard_now(),
		"late-tap probe begins in the committed swing")
	player.press_guard(Game.clock)
	await ticks(2)
	player.release_guard(Game.clock)
	await ticks(16)
	check(player.state == Player.S.GUARD,
		"a tap just before the recovery comes up with it (%s)" % Player.S.keys()[player.state])
	# A quick deflect tap during a light hit's stun (released before the stun ends) still comes
	# up the moment it can: a tap a moment too early mustn't just vanish.
	await setup(3.5)
	boss.set_facing(PI)
	var hit_at := Game.clock
	player.receive_attack({"dmg": 12.0, "kind": "normal", "time": Game.clock}, boss)
	check(player.state == Player.S.HIT, "hit-stun probe: a light hit flinches you (%s)" % Player.S.keys()[player.state])
	await ticks(5)
	player.press_guard(Game.clock)
	await ticks(5)
	player.release_guard(Game.clock)
	await ticks(14)
	var late := player.guard_start - (hit_at + Combat.HIT_STUN_LIGHT)
	check(player.state == Player.S.GUARD and late >= 0.0 and late < 0.02,
		"a deflect tap during hit-stun comes up as the stun ends (%s, %.0f ms after)" % [
		Player.S.keys()[player.state], late * 1000.0])
	# Release events can be missed while paused or focus changes. The device's current state
	# must clear the held-dodge sprint after play resumes.
	await setup(3.5)
	player.bot_enabled = false
	Input.action_press("dodge")
	player.press_action("dodge", Game.clock)
	await ticks(2)
	Input.action_release("dodge")
	await ticks(2)
	check(player._dodge_held_since < 0.0, "a lost dodge release cannot leave sprint latched")
	# A guard held from before a slash (never let go) comes back up, as a block, the moment the
	# slash's recovery opens, not when the whole animation ends. It doesn't stop the slash itself,
	# nor a second slash you queue during it.
	var rec := Player._recovery_from(c)
	await setup(2.2)
	boss.set_facing(PI)
	player.press_guard(Game.clock)
	await ticks(30)
	var hp0 := boss.hp
	var t0 := Game.clock
	player.press_action("attack", t0)
	var up_at := -1.0
	while Game.clock - t0 < 0.467:
		await ticks(1)
		if up_at < 0.0 and player.state == Player.S.GUARD:
			up_at = Game.clock - t0
	var r := player.receive_attack({"dmg": 12.0, "kind": "normal", "time": Game.clock}, boss)
	check(boss.hp < hp0, "holding guard doesn't stop a slash: it lands (%.0f damage)" % (hp0 - boss.hp))
	check(up_at >= rec - 0.001 and up_at <= rec + 0.02 and r == Combat.RESULT_BLOCK,
		"a guard held since before the slash is up as its recovery opens (%.3f s, recovery at %.2f s); a blow at 0.467 s is blocked, no fresh deflect window (%s)" % [
		up_at, rec, res_name(r)])
	await setup(2.2)
	boss.set_facing(PI)
	player.press_guard(Game.clock)
	await ticks(30)
	t0 = Game.clock
	player.press_action("attack", t0)
	await ticks(36)
	player.press_action("attack", Game.clock)
	await ticks(36)
	check(player.state == Player.S.ATTACK and player.anim.clip.name == "p_attack_2",
		"with guard held, a slash queued during the first still follows it (%s %s)" % [Player.S.keys()[player.state],
		player.anim.clip.name if player.anim.clip != null else "-"])
	# A dodge with guard held: the step keeps its length, then the guard is up.
	await setup(3.0)
	player.press_guard(Game.clock)
	await ticks(20)
	var p0 := player.global_position
	player.bot_move = Vector2(0, 1)
	player.press_action("dodge", Game.clock)
	await ticks(2)
	player.bot_move = Vector2.ZERO
	await ticks(46)
	var moved := Combat.flat(player.global_position - p0).length()
	check(player.state == Player.S.GUARD and moved >= 1.35,
		"a step with guard held keeps its length (%.2f m), then the guard is up (%s)" % [moved, Player.S.keys()[player.state]])
	# ...and a neutral step (the mikiri step) keeps its whole mikiri window before the guard's up.
	await setup(3.0)
	player.press_guard(Game.clock)
	await ticks(20)
	var s0 := Game.clock
	player.press_action("dodge", s0)
	var guard_at := -1.0
	while Game.clock - s0 < 0.6 and guard_at < 0.0:
		await ticks(1)
		if player.state == Player.S.GUARD:
			guard_at = Game.clock - s0
	var mk_end := float((AnimLibrary.get_clip("p_dodge_fwd").raw["mikiri"] as Array)[1])
	check(player.dodge_neutral and guard_at >= mk_end - 0.001 and guard_at <= mk_end + 0.02,
		"a neutral step with guard held keeps its mikiri window: the guard's up at %.2f s (the window ends at %.2f s)" % [
		guard_at, mk_end])
	# Guard (or dodge) held down while paused: nothing's listening then, but the button's still
	# down when play resumes, so it's held: the guard comes up as a block (that press wasn't timed
	# against anything, so no deflect window), the dodge as a sprint about to start (no step).
	await setup(2.2)
	player.bot_enabled = false
	get_tree().paused = true
	Input.action_press("guard")
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().paused = false
	await ticks(3)
	var held := player.guard_held
	r = player.receive_attack({"dmg": 12.0, "kind": "normal", "time": Game.clock}, boss)
	check(held and r == Combat.RESULT_BLOCK, "a guard pressed while paused is held when play resumes, and blocks (%s, %s)" % [
		held, res_name(r)])
	Input.action_release("guard")
	await ticks(2)
	check(not player.guard_held, "...and lets go when the button does")
	get_tree().paused = true
	Input.action_press("dodge")
	await get_tree().process_frame
	get_tree().paused = false
	await ticks(3)
	check(player._dodge_held_since >= 0.0 and player.state != Player.S.DODGE,
		"a dodge held through a pause is held when play resumes (a sprint, not a step: %s)" % Player.S.keys()[player.state])
	Input.action_release("dodge")
	await ticks(2)


## Hit-stop and slow motion last their real length, however the frame they start in goes: Godot
## scales a frame's delta by the time scale in force as the frame began, so a freeze started
## during a frame (a deflect, in a physics step) must count that frame by the old scale. (Counting
## it by the new one ended a deflect's 75 ms freeze at once.) At the lab's 120 fps each frame is
## 8.3 ms of real time, and each effect lasts exactly its length in frames (the frame it starts in
## isn't part of it: that one ran at full speed).
func suite_hitstop() -> void:
	Game.time_effects_enabled = true
	var cases := [["a hit-stop started in a physics step", "physics", 0.075, 0.02],
		["a hit-stop started in physics before Game sees the frame begin", "early", 0.075, 0.02],
		["a hit-stop started at the end of a frame (deferred)", "deferred", 0.075, 0.02],
		["slow motion started in a physics step", "physics", 0.5, 0.25]]
	for cs in cases:
		await setup(3.0)
		await ticks(1)
		var dur: float = cs[2]
		if str(cs[1]) == "deferred":
			await get_tree().process_frame
			Game.call_deferred("hitstop", dur, float(cs[3]))   # (runs once this frame's been counted)
		elif str(cs[1]) == "early":
			# As if from an Area3D signal (the physics server's, before physics_frame) or a
			# physics_frame handler connected before Game's: it still sees last frame as counted.
			Game._frame_counted = true
			Game.hitstop(dur, float(cs[3]))
		elif dur > 0.2:
			Game.slowmo(dur, float(cs[3]))
		else:
			Game.hitstop(dur, float(cs[3]))
		var n := await _slowed_frames()
		var want := int(round(dur * 120.0))
		print("  %s (%.0f ms): %d frames = %.0f ms" % [cs[0], dur * 1000.0, n, n * 1000.0 / 120.0])
		check(n == want, "%s lasts its %.0f ms (%.0f ms)" % [cs[0], dur * 1000.0, n * 1000.0 / 120.0])
		Game.clear_time_effects()
	# The real thing: a deflect's hit-stop.
	await setup(2.2)
	player.press_guard(Game.clock)
	await ticks(2)
	var r := player.receive_attack({"dmg": 12.0, "kind": "normal", "time": Game.clock}, boss)
	var frames := await _slowed_frames()
	var want_ms := Combat.HITSTOP_DEFLECT * 1000.0
	check(r == Combat.RESULT_DEFLECT and frames == int(round(Combat.HITSTOP_DEFLECT * 120.0)),
		"a deflect freezes the action for its %.0f ms (%s, %.0f ms)" % [want_ms, res_name(r), frames * 1000.0 / 120.0])
	Game.clear_time_effects()
	Game.time_effects_enabled = false


## How many frames from now run slowed (their delta scaled down), until the first one that doesn't.
func _slowed_frames() -> int:
	var n := 0
	for k in 400:
		await get_tree().process_frame
		if get_process_delta_time() < DT * 0.99:
			n += 1
		elif n > 0:
			break
	return n


## The deathblow prompt never offers an execution the attack won't make, nor hides one it would:
## from in front, beside and behind him, near and far, the HUD's check (Player.can_deathblow) and
## what an attack press does agree. From behind you must be within 1.8 m, elsewhere 3 m.
func suite_deathblow() -> void:
	# [degrees off his facing (0 in front of him), distance, an execution?]
	for cs in [[0.0, 2.8, true], [0.0, 1.4, true], [90.0, 2.5, true], [180.0, 1.5, true], [180.0, 2.5, false],
			[140.0, 2.2, false], [0.0, 3.3, false]]:
		await setup(float(cs[1]), float(cs[0]))
		boss._posture_break()
		await ticks(2)
		var offered := player.can_deathblow()
		player.press_action("attack", Game.clock)
		await ticks(3)
		var executed := player.state == Player.S.DEATHBLOW
		check(offered == executed and executed == bool(cs[2]),
			"%.0f° off his facing at %.1f m: the prompt %s, the attack %s" % [float(cs[0]), float(cs[1]),
			"shows" if offered else "doesn't show", "executes him" if executed else "doesn't"])


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
	boss.executed.connect(func(final: bool): bump.call("executed_final" if final else "executed"))
	var over := [""]
	boss.defeated.connect(func(): over[0] = "boss defeated")
	player.died.connect(func(): over[0] = "player died")
	var handled := {}
	var leads := {}
	var serial := [0, ""]
	var next_attack := 0.0
	var t_end := Game.clock + SOAK_TIME
	var last_desc := ""
	var ibot := {"jumped": [-1]}
	while Game.clock < t_end and over[0] == "":
		await ticks(1)
		var now := Game.clock
		if boss.state == Boss.S.INFERNO:          # phase 2's fire move: get clear, jump the arms
			_inferno_bot_tick("escape", ibot)
			continue
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
	print("  soak: %s after %.0f s  %s  boss lives %d, infernos %d, player hp %.0f" % [over[0] if over[0] != "" else "time up",
		Game.clock - (t_end - SOAK_TIME), str(counts), boss.lives_left, boss.inferno_uses, player.hp])
	check(int(counts.get("DEFLECT", 0)) >= 10, "soak: deflects happen (%d)" % int(counts.get("DEFLECT", 0)))
	check(int(counts.get("BLOCK", 0)) >= 1, "soak: early presses block")
	check(int(counts.get("posture_break", 0)) >= 1, "soak: his posture breaks")
	check(int(counts.get("life_lost", 0)) >= 1, "soak: a deathblow takes a life (phase two)")
	# (The blade goes in two seconds before the life is taken: one may be under way at time-up.)
	var execs := int(counts.get("executed", 0)) + int(counts.get("executed_final", 0))
	var under_way := 1 if boss.state == Boss.S.DEATHBLOWN else 0
	var finals := int(counts.get("executed_final", 0))
	check(execs == int(counts.get("life_lost", 0)) + under_way and finals <= 1 and (finals == 1 or over[0] != "boss defeated"),
		"soak: each deathblow's blade signals 忍殺 once, the last one as final (%d, final %d, lives taken %d)" % [execs,
			finals, int(counts.get("life_lost", 0))])
	if boss.phase >= 2:
		check(boss.inferno_uses >= 1, "soak: he opens phase two with the Inferno (%d uses)" % boss.inferno_uses)


# ---------------------------------------------------------------------------- the Inferno
## Phase 2's fire move. The tell (a leap to the middle of the arena, a long channel with the
## blast radius glowing on the floor) gives you time to walk out of the blast; inside it you're
## knocked down and thrown out. Then each arm of fire has to be jumped: guarding, dodging and
## standing still all get burned. Three passes on an even beat, a faster fourth that catches
## anyone jumping on the beat; the beat holds wherever you stand; after a burn you always get
## up in time to jump the next arm; the ring keeps you off him and his fire turns your sword;
## afterwards he's open. He opens phase 2 with it and uses it again later.
func suite_inferno() -> void:
	# Opens phase 2: starting the fight there, and rising into it after a deathblow.
	await setup(4.0)
	boss.set_start_phase(2)
	boss.passive = false
	boss.start_fight()
	await _wait_state(Boss.S.INFERNO, 2.0)
	check(boss.state == Boss.S.INFERNO, "starting in phase 2, he opens with the Inferno (%s)" % Boss.S.keys()[boss.state])
	await setup(3.0)
	boss.passive = false
	boss._posture_break()
	boss.begin_deathblow(player)
	await _wait_state(Boss.S.INFERNO, 12.0)
	check(boss.state == Boss.S.INFERNO and boss.phase == 2, "rising into phase 2, he opens with the Inferno (%s, phase %d)" % [
		Boss.S.keys()[boss.state], boss.phase])

	# The leap lands him in the middle of the arena, wherever he was.
	var r := await _inferno_run(Vector3(5.0, 0, -4.0), Vector3(0, 0, 9.0), "jump")
	check(float(r["landed_off"]) < 0.2, "he leaps to the middle of the arena (lands %.2f m off)" % r["landed_off"])

	# The blast: out of the glow you're safe; in it you're knocked down and thrown out of it;
	# the channel is long enough to walk out of it locked on from right beside where he lands.
	r = await _inferno_run(Vector3(0, 0, -3.0), Vector3(0, 0, 8.0), "jump")
	check(not bool(r["blast_hit"]), "the blast doesn't reach you outside its radius")
	r = await _inferno_run(Vector3(0, 0, -3.0), Vector3(0, 0, 2.0), "stand")
	check(bool(r["blast_hit"]) and float(r["blast_out"]) >= Inferno.BLAST_R - 0.3,
		"inside the blast radius it knocks you down and throws you out (%.1f m from him)" % r["blast_out"])
	for start in [Vector3(0, 0, 1.6), Vector3(1.2, 0, -0.5), Vector3(-2.5, 0, 1.0)]:
		r = await _inferno_run(Vector3(0, 0, -4.0), start, "escape")
		check(not bool(r["blast_hit"]), "walking away (locked on) from %.1f m out gets clear of the blast in time" % Combat.flat(start).length())
	r = await _inferno_run(Vector3(0, 0, -3.0), Vector3(0, 0, 2.0), "dodge_blast")
	check(bool(r["blast_hit"]), "dodging through the blast doesn't work (i-frames don't cover it)")

	# Jumping each arm as it comes clears all four, wherever you stand.
	var worst_gap := 0.0
	for spot in [[6.0, 0.0], [10.0, 120.0], [14.0, 240.0], [4.2, 60.0]]:
		var pos := Combat.dir_of(deg_to_rad(float(spot[1]))) * float(spot[0])
		r = await _inferno_run(Vector3(0, 0, -2.0), pos, "jump")
		check(int(r["passes"]) == Inferno.PASSES and int(r["hits"]) == 0 and int(r["erupt_hits"]) == 0,
			"jumping each arm and the eruption at %.0f m clears them all (%d passes, %d burns, eruption %d)" % [spot[0],
				r["passes"], r["hits"], r["erupt_hits"]])
		check(bool(r["spent"]), "at %.0f m: afterwards he's spent (b_fire_spent)" % spot[0])
		var gaps: Array = r["gaps"]
		if gaps.size() == 3:
			worst_gap = maxf(worst_gap, maxf(absf(float(gaps[0]) - Inferno.GAP), maxf(absf(float(gaps[1]) - Inferno.GAP),
				absf(float(gaps[2]) - Inferno.GAP_FAST))))
		print("  inferno at %4.1f m %3.0f deg: passes %s, gaps %s" % [spot[0], spot[1], str(r["pass_rel"]), str(gaps)])
	check(worst_gap < 0.12, "the beat holds wherever you stand: %.1f, %.1f, then %.2f s (off by at most %.2f s)" % [
		Inferno.GAP, Inferno.GAP, Inferno.GAP_FAST, worst_gap])
	# His posture holds through it: you can't touch him for its ~12 s (your sword glances off
	# the flames), so what you'd built doesn't drain away while you survive it.
	r = await _inferno_run(Vector3(0, 0, -2.0), Vector3(0, 0, 8.0), "jump", {"posture": 240.0})
	print("  inferno from 240 posture: %.1f when he hands back after %.1f s" % [r["posture_handback"], r["inferno_s"]])
	check(absf(float(r["posture_handback"]) - 240.0) < 0.5 and float(r["inferno_s"]) > 8.0,
		"his posture holds through the Inferno (240 before, %.1f when he hands back %.1f s later)" % [
			r["posture_handback"], r["inferno_s"]])
	# ...even while you walk round him (the turn is steered to keep the beat)
	r = await _inferno_run(Vector3(0, 0, -2.0), Vector3(0, 0, 7.0), "jump_strafe")
	var sg: Array = r["gaps"]
	print("  inferno walking round him: gaps %s, %d burns" % [str(sg), r["hits"]])
	check(int(r["hits"]) == 0 and sg.size() == 3 and absf(float(sg[0]) - Inferno.GAP) < 0.25 and absf(float(sg[2]) - Inferno.GAP_FAST) < 0.25,
		"walking round him, the beat still holds and jumping still clears it (%s)" % str(sg))

	# Everything else gets burned: standing still, guarding, dodging into the arm.
	for mode in ["stand", "guard", "dodge"]:
		r = await _inferno_run(Vector3(0, 0, -2.0), Vector3(0, 0, 8.0), mode)
		check(int(r["hits"]) == Inferno.PASSES and int(r["guarded"]) == 0 and int(r["erupt_hits"]) == 1,
			"%s: every arm burns you, and so does the eruption (%d of %d, eruption %d)" % [mode, r["hits"], Inferno.PASSES,
				r["erupt_hits"]])
		if mode == "stand":
			check(float(r["erupt_after_burn"]) >= Inferno.FAIR - 0.1,
				"burned by the last arm, the eruption waits until you're up (%.2f s after)" % r["erupt_after_burn"])
	# The eruption: one jump, timed to it. In the air you're clear, rising or falling; too early
	# and you land in it, too late and you're still on the ground when the flames reach you.
	var clear: Array = []
	var row := PackedStringArray()
	for lead in [-0.1, -0.04, 0.02, 0.06, 0.1, 0.14, 0.18, 0.22, 0.26, 0.3, 0.34, 0.38, 0.42, 0.5, 0.65]:
		r = await _inferno_run(Vector3(0, 0, -2.0), Vector3(0, 0, 8.0), "erupt_lead", {"erupt_lead": lead})
		var ok := int(r["erupt_hits"]) == 0
		if ok:
			clear.append(lead)
		row.append("%.2f:%s" % [lead, "clear" if ok else "burned"])
	print("  eruption 8 m out, jumping this long before its flames reach you (negative: after): " + " ".join(row))
	check(clear.has(0.02) and clear.has(0.38) and clear.size() >= 9 and not clear.has(-0.04) and not clear.has(0.5)
		and not clear.has(0.65),
		"one jump timed to the eruption clears it (%.2f-%.2f s before its flames reach you); in the air you're clear, earlier or later burns" % [
			float(clear.min()) if not clear.is_empty() else -1.0, float(clear.max()) if not clear.is_empty() else -1.0])
	# It rolls out from his staff: the flames reach the wall a moment after they burst beside him.
	var near := await _inferno_run(Vector3(0, 0, -2.0), Vector3(0, 0, 6.5), "erupt_lead", {"after_burst": 0.17})
	var far := await _inferno_run(Vector3(0, 0, -2.0), Vector3(0, 0, 14.0), "erupt_lead", {"after_burst": 0.17})
	check(int(near["erupt_hits"]) == 1 and int(far["erupt_hits"]) == 0,
		"the eruption rolls outward: jumping 0.17 s after it bursts is too late 6.5 m out, in time 14 m out (burns %d, %d)" % [
			near["erupt_hits"], far["erupt_hits"]])
	# Jumping on the beat of the first three instead of watching: the fast fourth catches you.
	r = await _inferno_run(Vector3(0, 0, -2.0), Vector3(0, 0, 8.0), "beat")
	check(int(r["hits"]) == 1 and int(r["hit_pass"]) == Inferno.PASSES - 1,
		"jumping on the beat clears three, the faster fourth burns you (%d burns, on pass %d)" % [r["hits"], int(r["hit_pass"]) + 1])
	# Burned once, you get up in time to jump the next arm (it waits for you).
	r = await _inferno_run(Vector3(0, 0, -2.0), Vector3(0, 0, 8.0), "stand_first")
	check(int(r["hits"]) == 1 and float(r["after_hit"]) >= Inferno.FAIR - 0.1,
		"after a burn the next arm comes %.2f s later and you can jump it (%d burns)" % [r["after_hit"], r["hits"]])

	# Phase 3: waves of fire roll out from his ring between the passes. Jumping each arm and each
	# wave as it comes clears them all, wherever you stand, and there's always time to land and
	# jump again.
	var min_gap := 99.0
	for spot in [[4.2, 60.0], [6.0, 0.0], [10.0, 120.0], [14.0, 240.0]]:
		var pos3 := Combat.dir_of(deg_to_rad(float(spot[1]))) * float(spot[0])
		r = await _inferno_run(Vector3(0, 0, -2.0), pos3, "jump", {"phase": 3})
		check(int(r["passes"]) == Inferno.PASSES and int(r["waves"]) == Inferno.WAVE_BEATS.size()
			and int(r["hits"]) == 0 and int(r["wave_hits"]) == 0 and int(r["erupt_hits"]) == 0,
			"phase 3 at %.0f m: jumping each arm, each wave and the eruption clears them all (%d passes, %d waves, burns: %d arm, %d wave, %d eruption)" % [
				spot[0], r["passes"], r["waves"], r["hits"], r["wave_hits"], r["erupt_hits"]])
		var tg3: Array = r["threat_gaps"]
		for g3 in tg3:
			min_gap = minf(min_gap, float(g3))
		# each wave on its half-beat: midway between the passes either side of it
		var pr: Array = r["pass_rel"]
		var wr: Array = r["wave_rel"]
		var off := 0.0
		for k in wr.size():
			if pr.size() > k + 1:
				off = maxf(off, absf(float(wr[k]) - (float(pr[k]) + float(pr[k + 1])) * 0.5))
		check(wr.size() == Inferno.WAVE_BEATS.size() and off < 0.12,
			"phase 3 at %.0f m: each wave comes on the half-beat between two arms (off by at most %.2f s)" % [spot[0], off])
		print("  phase 3 at %4.1f m %3.0f deg: arms %s, waves %s, gaps between jumps %s" % [spot[0], spot[1], str(pr), str(wr), str(tg3)])
	check(min_gap >= 0.8, "phase 3: never less than %.2f s between two things to jump (a jump and landing take ~0.77 s)" % min_gap)
	for mode3 in ["jump_strafe", "jump_away"]:
		r = await _inferno_run(Vector3(0, 0, -2.0), Vector3(0, 0, 7.0), mode3, {"phase": 3})
		check(int(r["hits"]) == 0 and int(r["wave_hits"]) == 0 and int(r["waves"]) == Inferno.WAVE_BEATS.size(),
			"phase 3, %s: the waves keep their beat and jumping still clears everything (burns %d arm, %d wave; gaps %s)" % [
				"walking round him" if mode3 == "jump_strafe" else "backing away from him", r["hits"], r["wave_hits"],
				str(r["threat_gaps"])])
	# The waves are real: watching only the arms, they burn you.
	r = await _inferno_run(Vector3(0, 0, -2.0), Vector3(0, 0, 8.0), "arms_only", {"phase": 3})
	check(int(r["wave_hits"]) >= 1, "phase 3: jumping only the arms, a wave burns you (%d wave burns)" % r["wave_hits"])
	# Burned, you get up before anything else reaches you: the next arm waits, the waves coming
	# at you die down.
	for mode4 in ["arms_only", "stand"]:
		r = await _inferno_run(Vector3(0, 0, -2.0), Vector3(0, 0, 8.0), mode4, {"phase": 3})
		check(float(r["burn_to_next"]) >= Inferno.FAIR - 0.1,
			"phase 3, %s: after each burn nothing reaches you for %.2f s (time to get up and jump)" % [mode4, r["burn_to_next"]])
	# How exact the jump over a wave has to be (8 m out, jumping the arms 0.28 s ahead).
	var wclear: Array = []
	var wrow := PackedStringArray()
	for wl in [0.0, 0.04, 0.08, 0.14, 0.2, 0.28, 0.36, 0.44, 0.52, 0.6]:
		r = await _inferno_run(Vector3(0, 0, -2.0), Vector3(0, 0, 8.0), "wave_lead", {"phase": 3, "wave_lead": wl})
		var ok := int(r["wave_hits"]) == 0 and int(r["hits"]) == 0
		if ok:
			wclear.append(wl)
		wrow.append("%.2f:%s" % [wl, "clear" if ok else "burned"])
	print("  phase 3 waves 8 m out, jumping this long before one reaches you: " + " ".join(wrow))
	check(wclear.size() >= 5 and wclear.has(0.28), "phase 3: a wave is cleared by a jump %.2f-%.2f s before it reaches you" % [
		float(wclear.min()) if not wclear.is_empty() else -1.0, float(wclear.max()) if not wclear.is_empty() else -1.0])
	# Phase 2 has no waves.
	r = await _inferno_run(Vector3(0, 0, -2.0), Vector3(0, 0, 8.0), "jump")
	check(int(r["waves"]) == 0 and int(r["wave_hits"]) == 0, "phase 2 has no waves (%d)" % r["waves"])

	# The ring of fire keeps you off him (and burns), and his fire turns your sword.
	r = await _inferno_run(Vector3(0, 0, -2.0), Vector3(0, 0, 7.0), "rush")
	check(float(r["closest"]) >= Inferno.RING_R - 0.5 and int(r["burns"]) >= 1,
		"walking at him during the turn: the ring stops you %.2f m out and burns (%d)" % [r["closest"], r["burns"]])
	r = await _inferno_run(Vector3(0, 0, 0.0), Vector3(0, 0, 1.7), "slash")
	check(int(r["slashes"]) >= 1 and int(r["slash_hits"]) == 0 and float(r["boss_hp_lost"]) == 0.0 and float(r["boss_posture"]) == 0.0,
		"your sword glances off him while he burns (%d contacts, %d hit, %.0f damage, %.0f posture)" % [r["slashes"],
			r["slash_hits"], r["boss_hp_lost"], r["boss_posture"]])
	# Spent: he's open, hits land.
	r = await _inferno_run(Vector3(0, 0, -2.0), Vector3(0, 0, 6.0), "punish")
	check(int(r["punished"]) >= 1, "while he's spent your hits land (%d)" % r["punished"])

	# He uses it again later in phase 2, not before the cooldown.
	await setup(4.0)
	seed(2024)
	boss.set_start_phase(2)
	boss.passive = false
	boss.start_fight()
	var starts: Array = []
	var ends: Array = []
	var was := false
	var t_end := Game.clock + 110.0
	var bot := {"jumped": [-1]}
	while Game.clock < t_end:
		await ticks(1)
		var now_on := boss.state == Boss.S.INFERNO
		if now_on and not was:
			starts.append(Game.clock)
		if was and not now_on:
			ends.append(Game.clock)
		was = now_on
		_inferno_bot_tick("jump", bot)
		if player.guard_held and Game.clock - player.guard_start > 0.1:
			player.release_guard(Game.clock)
	var gap_ok := starts.size() >= 2 and ends.size() >= 1 and float(starts[1]) - float(ends[0]) >= Boss.INFERNO_COOLDOWN - 0.5
	check(gap_ok, "he uses it again in phase 2 once it's off cooldown (%d uses, gap %s s)" % [starts.size(),
		("%.1f" % (float(starts[1]) - float(ends[0]))) if starts.size() >= 2 and ends.size() >= 1 else "-"])


func _wait_state(s: int, max_time: float) -> void:
	var t_end := Game.clock + max_time
	while boss.state != s and Game.clock < t_end:
		await ticks(1)


## Runs one Inferno with the boss starting at `boss_at` (it leaps to the middle) and the player
## at `player_at`, the player bot doing `mode`. Returns what happened.
func _inferno_run(boss_at: Vector3, player_at: Vector3, mode: String, opts := {}) -> Dictionary:
	await setup(4.0)
	boss.global_position = boss_at
	player.global_position = player_at
	await ticks(2)
	boss.face_now(player.global_position)
	player.face_now(boss.global_position)
	boss._enter_phase(int(opts.get("phase", 2)), false)
	var hp0 := boss.hp
	var out := {"wave_hits": 0, "waves": 0, "wave_rel": [], "threat_gaps": [], "burn_to_next": 99.0,
		"blast_hit": false, "blast_out": 0.0, "passes": 0, "hits": 0, "guarded": 0, "hit_pass": -1, "gaps": [],
		"pass_rel": [], "spent": false, "landed_off": 99.0, "after_hit": 99.0, "closest": 99.0, "burns": 0,
		"slashes": 0, "slash_hits": 0, "boss_hp_lost": 0.0, "boss_posture": 0.0, "punished": 0,
		"erupt_hits": 0, "erupt_after_burn": 99.0, "posture_handback": -1.0, "inferno_s": 0.0}
	var burned := [0]
	var hp_prev := [player.hp]
	boss.struck.connect(func(res: int, _p: Vector3):
		out["slashes"] = int(out["slashes"]) + 1
		if res == Combat.RESULT_HIT and boss.state == Boss.S.INFERNO:
			out["slash_hits"] = int(out["slash_hits"]) + 1)
	if opts.has("posture"):
		boss.posture = float(opts["posture"])
	boss.begin_inferno()
	var inf := boss.inferno
	var st := {"jumped": [-1], "last_hit_t": -1.0, "stood": false}
	st.merge(opts, true)
	var t0 := Game.clock
	var t_end := Game.clock + 24.0
	var hit_times: Array = []
	var seen_spent := false
	while Game.clock < t_end:
		await ticks(1)
		if inf.stage == Inferno.St.IGNITE and float(out["landed_off"]) > 90.0:
			out["landed_off"] = Combat.flat(boss.global_position - inf.center).length()
		if inf.blast_hit and not bool(out["blast_hit"]):
			out["blast_hit"] = true
		if bool(out["blast_hit"]) and player.state == Player.S.KNOCKDOWN and inf.stage == Inferno.St.IGNITE:
			out["blast_out"] = maxf(float(out["blast_out"]), Combat.flat(player.global_position - inf.center).length())
		if inf.stage >= Inferno.St.SPIN:
			out["closest"] = minf(float(out["closest"]), Combat.flat(player.global_position - inf.center).length())
		if player.hp < float(hp_prev[0]) - 0.01 and inf.stage >= Inferno.St.SPIN and player.state != Player.S.KNOCKDOWN:
			burned[0] += 1
		hp_prev[0] = player.hp
		if boss.state == Boss.S.ATTACK and boss.anim.is_playing("b_fire_spent"):
			seen_spent = true
		if boss.state != Boss.S.INFERNO and float(out["posture_handback"]) < 0.0:
			out["posture_handback"] = boss.posture
			out["inferno_s"] = Game.clock - t0
		# (closing in as soon as you've landed from the eruption, like a player going for the opening)
		if mode == "punish" and (seen_spent or inf.erupt_time > 0.0 and Game.clock > inf.erupt_time + 0.45):
			_inferno_close_in()
		_inferno_bot_tick(mode, st)
		if mode == "slash" and inf.stage == Inferno.St.IGNITE and boss.anim.time < 1.3 and player.state == Player.S.MOVE:
			player.press_action("attack", Game.clock)
		if seen_spent and boss.state == Boss.S.NEUTRAL:
			break
	for rr in _results:
		var info: Dictionary = rr["info"]
		if str(info.get("clip", "")) != "inferno" or str(info.get("kind", "")) != "sweep":
			continue
		if str(info.get("part", "")) == "eruption":
			if int(rr["res"]) == Combat.RESULT_HIT:
				out["erupt_hits"] = int(out["erupt_hits"]) + 1
			continue
		if str(info.get("part", "")) == "wave":
			if int(rr["res"]) == Combat.RESULT_HIT:
				out["wave_hits"] = int(out["wave_hits"]) + 1
				hit_times.append(float(rr["t"]))
			continue
		if int(rr["res"]) == Combat.RESULT_HIT:
			out["hits"] = int(out["hits"]) + 1
			out["hit_pass"] = int(info.get("index", -1))
			hit_times.append(float(rr["t"]))
		elif int(rr["res"]) == Combat.RESULT_BLOCK or int(rr["res"]) == Combat.RESULT_DEFLECT:
			out["guarded"] = int(out["guarded"]) + 1
	out["passes"] = inf.passes
	out["waves"] = inf.waves_passed
	var wrel: Array = []
	for w in inf.wave_times:
		wrel.append(snappedf(float(w) - t0, 0.01))
	out["wave_rel"] = wrel
	# everything you had to jump, in order, and the gaps between them
	var threats: Array = inf.pass_times.duplicate()
	threats.append_array(inf.wave_times)
	threats.sort()
	var tg: Array = []
	for i in range(1, threats.size()):
		tg.append(snappedf(float(threats[i]) - float(threats[i - 1]), 0.01))
	out["threat_gaps"] = tg
	# after each burn, how long until the next thing reaches you
	hit_times.sort()
	for h in hit_times:
		for th in threats:
			if float(th) > float(h) + 0.3:
				out["burn_to_next"] = minf(float(out["burn_to_next"]), float(th) - float(h))
				break
	var pt: Array = inf.pass_times
	var rel: Array = []
	for p in pt:
		rel.append(snappedf(float(p) - t0, 0.01))
	out["pass_rel"] = rel
	var gaps: Array = []
	for i in range(1, pt.size()):
		gaps.append(snappedf(float(pt[i]) - float(pt[i - 1]), 0.01))
	out["gaps"] = gaps
	out["spent"] = seen_spent
	out["burns"] = burned[0]
	if not hit_times.is_empty() and inf.erupt_time > 0.0:
		out["erupt_after_burn"] = inf.erupt_time - float(hit_times[hit_times.size() - 1])
	if hit_times.size() == 1:
		for p in pt:
			if float(p) > float(hit_times[0]) + 0.3:
				out["after_hit"] = float(p) - float(hit_times[0])
				break
	out["boss_hp_lost"] = hp0 - boss.hp if mode == "slash" else 0.0
	out["boss_posture"] = boss.posture if mode == "slash" else 0.0
	if mode == "punish":
		out["punished"] = int(hp0 - boss.hp > 0.0)
	if verbose:
		print("    %s: %s" % [mode, str(out)])
	return out


## Keeps the player next to him and swinging (his punish window).
func _inferno_close_in() -> void:
	var d := player.distance_to_opponent()
	player.camera_yaw = Combat.yaw_of(Combat.flat(boss.global_position - player.global_position))
	player.bot_move = Vector2(0, -1) if d > 2.2 else Vector2.ZERO
	if d <= 2.6 and player.state == Player.S.MOVE:
		player.press_action("attack", Game.clock)


## The player bot during the Inferno. Modes: "jump" (jump each arm 0.28 s before it arrives),
## "escape" (walk out of the blast radius during the channel, then jump), "stand", "guard",
## "dodge" (step into each arm), "beat" (watch the first arm, then jump on the beat),
## "stand_first" (take the first arm, jump the rest), "jump_strafe" (jump while walking round
## him), "rush" (walk at him during the turn), "slash" / "punish", "dodge_blast".
func _inferno_bot_tick(mode: String, st: Dictionary) -> void:
	var inf := boss.inferno
	var now := Game.clock
	player.camera_yaw = Combat.yaw_of(Combat.flat(boss.global_position - player.global_position))
	var to_c := Combat.flat(player.global_position - inf.center)
	var channel := boss.state == Boss.S.INFERNO and inf.stage <= Inferno.St.IGNITE and not inf.blast_hit and inf.blast_radius() < 0.0
	var move := Vector2.ZERO
	if mode == "escape" and channel and to_c.length() < Inferno.BLAST_R + 1.2:
		move = Vector2(0, 1)
	if mode == "jump_strafe" and inf.stage == Inferno.St.SPIN:
		move = Vector2(1, 0)
	if mode == "jump_away" and inf.stage == Inferno.St.SPIN and to_c.length() < 14.5:
		move = Vector2(0, 1)          # (the lab has no wall: stop where the arena's would stop you)
	if mode == "rush" and inf.stage == Inferno.St.SPIN:
		move = Vector2(0, -1)
	if mode != "punish":
		player.bot_move = move
	if mode == "dodge_blast" and channel and boss.anim.is_playing("b_fire_ignite") and boss.anim.time >= 1.52 \
			and not st.get("dodged", false):
		st["dodged"] = true
		player.press_action("dodge", now)
	if mode == "guard":
		if inf.stage >= Inferno.St.SPIN and not player.guard_held:
			player.press_guard(now)
		return
	if inf.stage != Inferno.St.SPIN and inf.stage != Inferno.St.PLUNGE:
		return
	var jumped: Array = st["jumped"]
	var erupt := inf.stage == Inferno.St.PLUNGE
	var key := 100 if erupt else inf.passes + inf.waves_passed   # one jump per arm and wave, one for the eruption
	var n := inf.next_jump_in()
	var lead := float(st.get("erupt_lead", 0.28)) if erupt else 0.28
	if mode == "arms_only" and not erupt:
		key = inf.passes          # (watches the arms only: the waves catch it)
		n = inf._lead_deg() / inf._omega if inf._omega >= 1.0 else INF
	if mode == "wave_lead" and not erupt and inf.next_wave_in() < inf._lead_deg() / maxf(inf._omega, 1.0):
		lead = float(st["wave_lead"])     # jump the waves `wave_lead` s before they reach you
	# (a real player can jump out of a landing after 0.08 s: Player's LAND state)
	var free := player.state == Player.S.MOVE or player.state == Player.S.GUARD \
		or (player.state == Player.S.LAND and player.state_time > 0.08)
	if mode == "erupt_lead" and erupt:
		# jump `erupt_lead` s before the flames reach you (negative: after), or `after_burst` s
		# after the eruption bursts from his staff
		if int(jumped[0]) != key and free:
			var at := INF
			if st.has("after_burst"):
				if inf.erupt_time > 0.0:
					at = inf.erupt_time + float(st["after_burst"])
			elif inf.erupt_time > 0.0:
				at = inf.erupt_time + inf.eruption_delay(player.global_position) - lead
			elif n < INF:
				at = now + n - lead
			if now >= at:
				jumped[0] = key
				player.press_action("jump", now)
		return
	match mode:
		"jump", "escape", "jump_strafe", "jump_away", "punish", "rush", "erupt_lead", "arms_only", "wave_lead":
			if int(jumped[0]) != key and n <= lead and free:
				jumped[0] = key
				player.press_action("jump", now)
		"stand_first":
			if (inf.passes >= 1 or erupt) and int(jumped[0]) != key and n <= 0.28 and free:
				jumped[0] = key
				player.press_action("jump", now)
		"dodge":
			if int(jumped[0]) != key and n <= 0.08 and free:
				jumped[0] = key
				player.press_action("dodge", now)
		"beat":
			# first arm: watch it; after that jump when the beat says the next one is due (the
			# eruption it watches for)
			var due := INF
			if inf.passes == 0 or erupt:
				due = now + n
			else:
				due = float(inf.pass_times[inf.passes - 1]) + Inferno.GAP
			if int(jumped[0]) != key and due - now <= 0.28 and free:
				jumped[0] = key
				player.press_action("jump", now)


var _ttc_prev: Dictionary = {}


## Seconds until the boss's weapon reaches the player's hurtbox at its current closing speed
## (99 when it isn't closing in).
func _blade_time_to_contact(only := "") -> float:
	var cap := player.hurt_capsule()
	var best := 99.0
	for bn in boss.rig.blades:
		if only != "" and bn != only:
			continue
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


