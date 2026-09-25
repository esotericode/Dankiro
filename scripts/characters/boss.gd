class_name Boss
extends Combatant
## Sojin, the Twin Fang. Staff-and-blades duelist with Sekiro-style behaviour:
##  * Attack strings with mix-up enders (thrust / sweep / delayed overhead).
##  * Guards most attacks from neutral; blocked hits build HIS posture; mashing gets parried
##    and punished with a counter.
##  * Posture regenerates unless pressured; regen slows as his vitality drops.
##  * Posture break (or 0 vitality) -> kneels, deathblow window. Two lives; phase 2 is faster.

signal posture_broken
signal life_lost(lives_left: int)
signal defeated
signal perilous_warning(kind: String)

enum S { INTRO, NEUTRAL, ATTACK, GUARD, REACT, STAGGER, DEATHBLOWN, REVIVE, DEAD }

const LOCO := {"idle": "b_idle", "fwd": "b_walk_fwd", "back": "b_walk_back", "left": "b_walk_left",
	"right": "b_walk_right", "run": "b_run"}
const WALK := 1.8
const STRAFE := 1.25
const RUN := 4.8
const CHARGE := 6.4                  ## running at you: faster than your run, a touch under your sprint
const ARENA_RADIUS := 13.5
const DEATHBLOW_WINDOW_END := 2.75   ## b_posture_break time when he starts rising

## steps: [options ("a|b"), chance]; range: [min_d, max_d] meters; weight
const SEQUENCES := {
	"fang_string": {"steps": [["b_combo_1", 1.0], ["b_combo_2", 0.85], ["b_combo_3|b_thrust|b_sweep|b_sweep|b_backhand", 0.75]],
		"range": [0.0, 3.3], "weight": 3.0},
	"double_fang": {"steps": [["b_combo_1", 1.0], ["b_combo_2", 0.9], ["b_backhand", 0.4]], "range": [0.0, 3.2], "weight": 1.4},
	"backhand": {"steps": [["b_backhand", 1.0], ["b_combo_2|b_sweep", 0.45]], "range": [0.0, 3.1], "weight": 1.0},
	"heavens_fall": {"steps": [["b_combo_3", 1.0]], "range": [0.0, 3.0], "weight": 1.1},
	"jabs": {"steps": [["b_jab", 1.0], ["b_sweep|b_combo_2|b_thrust", 0.6]], "range": [0.0, 3.4], "weight": 1.6},
	"whirl": {"steps": [["b_whirl", 1.0]], "range": [0.0, 2.8], "weight": 1.2},
	"thrust": {"steps": [["b_thrust", 1.0]], "range": [2.8, 5.6], "weight": 1.8},
	"sweep": {"steps": [["b_sweep", 1.0]], "range": [0.0, 3.4], "weight": 2.0},
	"leap": {"steps": [["b_leap", 1.0], ["b_combo_2", 0.35]], "range": [4.6, 11.0], "weight": 2.6},
	"retreat": {"steps": [["b_backstep", 1.0], ["b_thrust|b_leap", 0.9]], "range": [0.0, 2.0], "weight": 0.9},
	"shuriken_4": {"steps": [["b_shuriken_4", 1.0], ["b_leap|b_thrust", 0.4]], "range": [0.0, 4.5], "weight": 1.1},
	"shuriken_5": {"steps": [["b_shuriken_5", 1.0], ["b_leap", 0.35]], "range": [0.0, 4.5], "weight": 0.8},
	"dash_cut": {"steps": [["b_dash_cut", 1.0], ["b_combo_2|b_sweep|b_thrust", 0.5]], "range": [3.0, 4.2], "weight": 1.0},
}

## Non-attack behaviours that compete with the sequences: [min, max] distance and weight.
##  charge     - run at you and flow into a running cut
##  reposition - run to another spot around you, then open with a special from there
##  hold       - stand and watch for a moment (breaks his rhythm)
##  flourish   - twirl the staff while you keep your distance (you can punish it)
const MOVES := {
	"charge": {"range": [5.0, 40.0], "weight": 2.4},
	"reposition": {"range": [1.5, 6.5], "weight": 0.7},
	"hold": {"range": [2.2, 9.0], "weight": 0.55},
	"flourish": {"range": [5.5, 12.0], "weight": 0.3},
}
## Specials he opens with after repositioning, by distance.
const SPECIALS := ["leap", "thrust", "shuriken_4", "shuriken_5", "charge"]

var state: int = S.INTRO
var state_time := 0.0
var lives_left := Combat.BOSS_LIVES
var phase := 1
var display_name := "Sojin, the Twin Fang"
var attack_speed := 1.0
var aggression := 1.0

var cooldown := 1.0
var strafe_dir := 1.0
var _strafe_timer := 2.0
var _seq: Array = []
var _seq_name := ""
var _last_seq := ""
var _repeat := 0
var _guard_count := 0
var _parry_threshold := 3
var _since_blocked := 99.0
var _guard_timer := 0.0
var _flinches := 0
var _last_step_phase := 0.0
var _mode := ""                     ## "" (stalk), "charge", "reposition", "hold"
var _mode_time := 0.0
var _mode_target := Vector3.ZERO
var _strafe_speed := 1.0
var _dist_prev := 0.0
var _retreat := 0.0                 ## seconds the player has spent backing away from him

var blade_mat: StandardMaterial3D
var eye_mat: StandardMaterial3D
var eye_light: OmniLight3D
var trails: Array = []
var aura: CPUParticles3D
var _glow := 0.35
var _glow_target := 0.35
var _base_glow := 0.35
var deathblow_marker: Sprite3D
var _perilous_clip := ""
var _danger_tex: Texture2D
var passive := false


func _ready() -> void:
	max_hp = Combat.BOSS_HP
	hp = max_hp
	max_posture = Combat.BOSS_POSTURE
	posture_regen = Combat.BOSS_POSTURE_REGEN
	posture_delay = Combat.BOSS_POSTURE_DELAY
	min_opponent_distance = 1.35
	_setup_rig("boss")
	var built := ModelBuilder.build(rig, "boss")
	var mats: Dictionary = built["materials"]
	blade_mat = mats.get("blade")
	eye_mat = mats.get("ember")
	var lights: Array = built["lights"]
	if lights.size() > 0:
		eye_light = lights[0]
	for bname in ["upper", "lower"]:
		var tr := WeaponTrail.new()
		tr.setup(rig, bname, Color(1.0, 0.5, 0.26, 0.42))
		tr.brightness = 1.15
		tr.min_speed = 7.0
		tr.life = 0.16
		tr.inner = 0.4
		rig.add_child(tr)
		trails.append(tr)
	_build_aura()
	deathblow_marker = Fx.glow_sprite(Fx.radial_texture("deathblow", Color(1.0, 0.12, 0.08, 1.0), Color(0.6, 0.0, 0.0, 0.0)),
		Color(1, 1, 1, 1), 0.45)
	deathblow_marker.visible = false
	add_child(deathblow_marker)
	deathblow_marker.position = Vector3(0, 1.45, 0)
	if ResourceLoader.exists("res://textures/kanji_danger.png"):
		_danger_tex = load("res://textures/kanji_danger.png")
	_parry_threshold = randi_range(2, 4)
	anim.play("b_idle", 0.0)
	anim.update(0.0)


func _build_aura() -> void:
	aura = CPUParticles3D.new()
	aura.amount = 26
	aura.lifetime = 1.8
	aura.local_coords = false
	aura.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	aura.emission_sphere_radius = 0.35
	aura.direction = Vector3(0, 1, 0)
	aura.spread = 35.0
	aura.gravity = Vector3(0, 0.5, 0)
	aura.initial_velocity_min = 0.1
	aura.initial_velocity_max = 0.45
	aura.scale_amount_min = 0.5
	aura.scale_amount_max = 1.2
	var fade := Curve.new()
	fade.add_point(Vector2(0.0, 0.2))
	fade.add_point(Vector2(0.2, 1.0))
	fade.add_point(Vector2(1.0, 0.0))
	aura.scale_amount_curve = fade
	aura.mesh = MeshKit.sphere(0.009, -1.0, 6)
	aura.material_override = MeshKit.glow(Color(1.0, 0.42, 0.12), 5.0)
	(rig.joint("chest") as Node3D).add_child(aura)
	aura.position = Vector3(0, 0.12, 0)


func is_dead() -> bool:
	return state == S.DEAD


## Stops attacking (used after the player dies).
func set_passive(v: bool) -> void:
	passive = v


func start_fight() -> void:
	state = S.NEUTRAL
	state_time = 0.0
	cooldown = 1.4
	anim.play_locomotion(LOCO, 0.25)


func play_intro() -> void:
	state = S.INTRO
	state_time = 0.0
	anim.play("b_intro", 0.2)


# ====================================================================== main loop
func _physics_process(delta: float) -> void:
	state_time += delta
	_since_blocked += delta
	if _since_blocked > 1.6:
		_guard_count = 0
	var planar := Vector3.ZERO
	match state:
		S.INTRO:
			if opponent:
				turn_toward(opponent.global_position, 120.0, delta)
			if anim.finished:
				anim.play_locomotion(LOCO, 0.3)
		S.NEUTRAL:
			planar = _state_neutral(delta)
		S.ATTACK:
			planar = _state_attack(delta)
		S.GUARD:
			_state_guard(delta)
		S.REACT:
			if anim.finished:
				_to_neutral(0.25 / aggression)
		S.STAGGER:
			deathblow_marker.visible = anim.time < DEATHBLOW_WINDOW_END
			var pulse := 1.0 + 0.18 * sin(Game.clock * 9.0)
			deathblow_marker.scale = Vector3.ONE * pulse
			if anim.finished:
				posture = max_posture * 0.3
				if hp <= 0.0:
					hp = max_hp * 0.12
				vitals_changed.emit()
				deathblow_marker.visible = false
				_to_neutral(0.4)
		S.DEATHBLOWN:
			if anim.finished:
				_after_deathblow()
		S.REVIVE:
			if anim.finished:
				_to_neutral(0.8)
		S.DEAD:
			pass
	anim.update(delta)
	process_weapon_hits()
	if state == S.ATTACK:
		_check_mikiri()
	planar += root_motion_velocity(delta)
	apply_motion(delta, planar)
	_update_glow(delta)
	if state != S.STAGGER and state != S.DEATHBLOWN and state != S.DEAD:
		tick_posture(delta, 0.3 + 0.7 * (hp / max_hp))
	_footsteps()


func _to_neutral(cd: float) -> void:
	state = S.NEUTRAL
	state_time = 0.0
	_mode = ""
	cooldown = cd
	_seq.clear()
	root_scale = 1.0
	_end_perilous()
	anim.play_locomotion(LOCO, 0.2)


# ---------------------------------------------------------------------------- neutral / AI
func _state_neutral(delta: float) -> Vector3:
	if opponent == null or passive:
		anim.play_locomotion(LOCO)
		anim.set_locomotion_velocity(Vector3.ZERO, WALK, false)
		return Vector3.ZERO
	var d := distance_to_opponent()
	var to := Combat.flat(opponent.global_position - global_position)
	var dirp := to.normalized() if to.length() > 0.01 else forward()
	cooldown -= delta
	_mode_time += delta
	# Backing away from him doesn't work: he notices and closes the gap.
	if d > 3.6 and d - _dist_prev > 1.4 * delta:
		_retreat += delta
	else:
		_retreat = maxf(0.0, _retreat - delta * 0.5)
	_dist_prev = d
	if opponent is Player:
		var p: Player = opponent
		# React to the player's windups by raising the guard.
		if p.state == Player.S.ATTACK and d < 3.4 and p.anim.time < 0.12 and _mode != "charge" \
				and Combat.angle_to(global_position, forward(), p.global_position) < 70.0 and randf() < 0.85:
			_mode = ""
			_enter_guard(0.8)
			return Vector3.ZERO
		# Punish healing
		if p.state == Player.S.HEAL and cooldown > 0.2:
			cooldown = 0.15
	if _retreat > 0.45 and _mode == "":
		_retreat = 0.0
		cooldown = 0.0
	match _mode:
		"charge":
			return _mode_charge(delta, d, dirp)
		"reposition":
			return _mode_reposition(delta, d)
		"hold":
			anim.play_locomotion(LOCO)
			anim.set_locomotion_velocity(Vector3.ZERO, WALK, false)
			turn_toward(opponent.global_position, 200.0, delta)
			if _mode_time > _mode_target.x:
				_mode = ""
				cooldown = minf(cooldown, 0.1)
			return Vector3.ZERO
	return _mode_stalk(delta, d, dirp)


## Default footsies: strafe at a varying pace, drift in and out of range, then pick an action.
func _mode_stalk(delta: float, d: float, dirp: Vector3) -> Vector3:
	var side := Vector3(-dirp.z, 0.0, dirp.x) * strafe_dir
	_strafe_timer -= delta
	if _strafe_timer <= 0.0:
		_strafe_timer = randf_range(0.9, 2.6)
		strafe_dir = -strafe_dir if randf() < 0.6 else strafe_dir
		_strafe_speed = randf_range(0.55, 1.35)
	var vel := Vector3.ZERO
	var running := false
	if d > 6.5:
		vel = dirp * RUN
		running = true
	elif d > 3.3:
		vel = dirp * WALK + side * 0.4 * _strafe_speed
	elif d < 1.9:
		vel = -dirp * 1.2 + side * 0.6
	else:
		vel = side * STRAFE * _strafe_speed + dirp * (d - 2.5) * 0.9
	if running:
		turn_toward(global_position + vel, 360.0, delta)
	else:
		turn_toward(opponent.global_position, 300.0, delta)
	var local := Basis(Vector3.UP, -facing) * vel
	anim.play_locomotion(LOCO)
	anim.set_locomotion_velocity(local, WALK, running)
	if cooldown <= 0.0:
		var pick := _pick_action(d)
		if pick != "" and _begin_action(pick, d):
			return Vector3.ZERO
	return vel


## Runs straight at the player; in range, flows into the running cut.
func _mode_charge(delta: float, d: float, dirp: Vector3) -> Vector3:
	turn_toward(opponent.global_position, 540.0, delta)
	var vel := dirp * CHARGE
	anim.play_locomotion(LOCO)
	anim.set_locomotion_velocity(Basis(Vector3.UP, -facing) * vel, WALK, true)
	if d < 3.6:
		_mode = ""
		_start_sequence("dash_cut")
		return Vector3.ZERO
	if _mode_time > 3.5:
		_mode = ""
		cooldown = 0.2
	return vel


## Runs to a spot around the player, then opens with a special from there.
func _mode_reposition(delta: float, d: float) -> Vector3:
	var to_t := Combat.flat(_mode_target - global_position)
	if to_t.length() < 0.7 or _mode_time > 2.6:
		_mode = ""
		face_now(opponent.global_position)
		var special := _pick_special(d)
		if special == "charge":
			_begin_action("charge", d)
		elif special != "":
			_start_sequence(special)
		else:
			cooldown = 0.1
		return Vector3.ZERO
	var vel := to_t.normalized() * RUN
	turn_toward(global_position + vel, 540.0, delta)
	anim.play_locomotion(LOCO)
	anim.set_locomotion_velocity(Basis(Vector3.UP, -facing) * vel, WALK, true)
	return vel


func _pick_special(d: float) -> String:
	var options: Array = []
	for sname in SPECIALS:
		var r: Array = MOVES[sname]["range"] if MOVES.has(sname) else SEQUENCES[sname]["range"]
		if d >= float(r[0]) - 0.3 and d <= float(r[1]) + 0.5:
			options.append(sname)
	if options.is_empty():
		return ""
	return str(options[randi() % options.size()])


## Starts an attack sequence or a movement mode. Returns false if nothing started.
func _begin_action(pick: String, d: float) -> bool:
	_mode_time = 0.0
	match pick:
		"charge":
			_mode = "charge"
			return true
		"reposition":
			var from_p := Combat.flat(global_position - opponent.global_position)
			if from_p.length() < 0.1:
				from_p = -forward()
			var ang := deg_to_rad(randf_range(55.0, 115.0)) * (1.0 if randf() < 0.5 else -1.0)
			var spot := opponent.global_position + (Basis(Vector3.UP, ang) * from_p.normalized()) * randf_range(5.8, 7.6)
			var flat_spot := Combat.flat(spot)
			if flat_spot.length() > ARENA_RADIUS:
				spot = flat_spot.normalized() * ARENA_RADIUS
			_mode_target = Vector3(spot.x, global_position.y, spot.z)
			_mode = "reposition"
			return true
		"hold":
			_mode = "hold"
			_mode_target = Vector3(randf_range(0.6, 1.4), 0, 0)
			return true
		"flourish":
			_seq.clear()
			_play_attack("b_intro", 0.0)
			return true
	_start_sequence(pick)
	return true


func _pick_action(d: float) -> String:
	var options: Array = []
	var total := 0.0
	var healing := opponent is Player and (opponent as Player).state == Player.S.HEAL
	var catalog := {}
	for sname in SEQUENCES:
		catalog[sname] = SEQUENCES[sname]
	for mname in MOVES:
		catalog[mname] = MOVES[mname]
	for sname in catalog:
		var sd: Dictionary = catalog[sname]
		var r: Array = sd["range"]
		if d < float(r[0]) or d > float(r[1]):
			continue
		var w := float(sd["weight"])
		if sname == _last_seq:
			w *= 0.35 if _repeat >= 1 else 0.7
		if healing and (sname == "thrust" or sname == "leap" or sname == "fang_string" or sname == "charge"):
			w *= 3.0
		if phase >= 2 and (sname == "fang_string" or sname == "whirl" or sname == "leap" or sname == "charge"):
			w *= 1.4
		if phase >= 2 and sname == "hold":
			w *= 0.5
		options.append([sname, w])
		total += w
	if options.is_empty():
		return ""
	var roll := randf() * total
	for o in options:
		roll -= float(o[1])
		if roll <= 0.0:
			return str(o[0])
	return str(options[options.size() - 1][0])


func _start_sequence(seq_name: String) -> void:
	_mode = ""
	if seq_name == _last_seq:
		_repeat += 1
	else:
		_repeat = 0
	_last_seq = seq_name
	_seq_name = seq_name
	_seq = (SEQUENCES[seq_name]["steps"] as Array).duplicate(true)
	_flinches = 0
	var first: Array = _seq.pop_front()
	_play_attack(_choose(str(first[0])), 0.0)


func _choose(options: String) -> String:
	var parts := options.split("|")
	return parts[randi() % parts.size()]


func _play_attack(clip_name: String, start: float) -> void:
	state = S.ATTACK
	state_time = 0.0
	_end_perilous()
	anim.play(clip_name, 0.14 if start <= 0.0 else 0.1, attack_speed, start)
	reset_hits()
	root_scale = 1.0
	if anim.clip.raw.has("nominal_reach") and opponent != null:
		var reach := float(anim.clip.raw["nominal_reach"])
		root_scale = clampf((distance_to_opponent() - 2.1) / reach, 0.35, 1.7)


func _state_attack(delta: float) -> Vector3:
	var c := anim.clip
	if c == null:
		_to_neutral(0.5)
		return Vector3.ZERO
	var t := anim.time
	# Tracking windows: [from, to, deg/s]
	for tr in c.raw.get("track", []):
		var ta: Array = tr
		if t >= float(ta[0]) and t <= float(ta[1]) and opponent != null:
			turn_toward(opponent.global_position, float(ta[2]) * attack_speed, delta)
	# Root-motion scale only applies inside its window (leaps).
	if c.raw.has("root_scale_window"):
		var w: Array = c.raw["root_scale_window"]
		if t > float(w[1]):
			root_scale = 1.0
	# Chain into the next step of the sequence.
	var chain_t := c.get_float("chain", c.length)
	if t >= chain_t and not _seq.is_empty():
		var step: Array = _seq.pop_front()
		var chance := float(step[1]) if step.size() > 1 else 1.0
		if randf() < chance * (1.15 if phase >= 2 else 1.0):
			var next_clip := _choose(str(step[0]))
			var start_t := 0.0
			if AnimLibrary.has_clip(next_clip):
				start_t = AnimLibrary.get_clip(next_clip).get_float("chain_in", 0.0)
			_play_attack(next_clip, start_t)
			return Vector3.ZERO
		_seq.clear()
	if anim.finished:
		var cd := randf_range(0.45, 1.25) / aggression
		if distance_to_opponent() > 5.0:
			cd = minf(cd, 0.2)          # you got away from that one: he comes after you
		_to_neutral(cd)
		return Vector3.ZERO
	return _close_distance(c, t)


## Gap-closing during a wind-up (clip "close": [from, to, ideal distance, max speed]): he
## shuffles in so a strike started at the edge of his range still arrives, like Souls bosses.
func _close_distance(c: ClipData, t: float) -> Vector3:
	var close: Array = c.raw.get("close", [])
	if close.size() < 4 or opponent == null or t < float(close[0]) or t > float(close[1]):
		return Vector3.ZERO
	var to := Combat.flat(opponent.global_position - global_position)
	var d := to.length()
	var ideal := float(close[2])
	if d <= ideal or d < 0.01:
		return Vector3.ZERO
	var t_left := maxf(0.05, float(close[1]) - t)
	return to / d * minf((d - ideal) / (t_left + 0.1), float(close[3]) * attack_speed)


## A perilous thrust meets a player who is in the mikiri frames of a forward step: count it
## as contact as soon as the blade tip reaches them (the stomp lands on the blade even if the
## thin polyline would have slipped past the capsule).
func _check_mikiri() -> void:
	if anim.clip == null or anim.loco_active or not (opponent is Player):
		return
	var p: Player = opponent
	var t := anim.time
	for i in anim.clip.hits.size():
		var h: Dictionary = anim.clip.hits[i]
		if str(h.get("kind", "")) != "thrust" or _hits_done.has(i):
			continue
		if t < float(h["from"]) - 0.06 or t > float(h["to"]):
			continue
		var release := _release_time(h)
		if not p.can_mikiri(self, release):
			return
		var pts := rig.blade_world(str(h.get("blade", "upper")))
		if pts.is_empty():
			return
		var tip := pts[pts.size() - 1]
		var reach := Combat.flat(tip - global_position).dot(forward())
		var pd := distance_to_opponent()
		if reach + 0.3 >= pd - p.hurt_radius and Combat.angle_to(global_position, forward(), p.global_position) < 40.0:
			_hits_done[i] = true
			var info := h.duplicate()
			info["index"] = i
			info["clip"] = anim.clip.name
			info["point"] = tip
			info["time"] = Game.clock
			_on_weapon_contact(info)
			return


## Game time at which this hit's thrust was released (clip time "mikiri_from"); -INF if none.
func _release_time(h: Dictionary) -> float:
	if not h.has("mikiri_from") or anim.clip == null:
		return -INF
	return Game.clock - (anim.time - float(h["mikiri_from"])) / maxf(anim.speed, 0.01)


func _in_vuln() -> bool:
	if anim.clip == null or anim.loco_active:
		return false
	var v: Variant = anim.clip.raw.get("vuln", null)
	if v == null:
		return false
	var a: Array = v
	return anim.time >= float(a[0]) and anim.time <= float(a[1])


# ---------------------------------------------------------------------------- guarding
func _enter_guard(hold: float) -> void:
	state = S.GUARD
	state_time = 0.0
	_guard_timer = hold
	anim.play("b_guard", 0.08)


func _state_guard(delta: float) -> void:
	_guard_timer -= delta
	if opponent:
		turn_toward(opponent.global_position, 240.0, delta)
	if anim.is_playing("b_guard_hit") and anim.finished:
		anim.play("b_guard", 0.1)
	if _guard_timer <= 0.0:
		# Sekiro enemies love to strike right after you stop hitting their guard.
		_to_neutral(0.05 if randf() < 0.6 else 0.35)


## The player's katana touched us. Returns Combat.RESULT_* for the player to react to.
func receive_player_attack(info: Dictionary, p: Player) -> int:
	match state:
		S.INTRO, S.STAGGER, S.DEATHBLOWN, S.REVIVE, S.DEAD:
			return Combat.RESULT_IGNORED
	var pos: Vector3 = info.get("point", global_position + Vector3.UP * 1.3)
	var facing_ok := Combat.angle_to(global_position, forward(), p.global_position) < 100.0
	if state == S.ATTACK:
		return _take_hit(info, _in_vuln())
	if state == S.REACT:
		_flinches += 1
		if _flinches >= 3 and facing_ok:
			return _parry(pos)
		return _take_hit(info, true)
	if facing_ok:
		_guard_count += 1
		_since_blocked = 0.0
		if _guard_count >= _parry_threshold:
			return _parry(pos)
		_block(info, pos)
		return Combat.RESULT_BLOCK
	return _take_hit(info, true)


func _block(info: Dictionary, pos: Vector3) -> void:
	if state != S.GUARD:
		_enter_guard(0.9)
	_guard_timer = maxf(_guard_timer, 0.7)
	anim.play("b_guard_hit", 0.04)
	Fx.sparks(get_parent(), pos, Vector3.UP, Fx.SPARK_BLOCK)
	Sfx.play("block", pos, 0.0, 0.92, 0.06)
	Game.hitstop(0.03)
	Game.shake(0.08, 0.1)
	if add_posture(float(info.get("posture", 7.0)) * 0.9):
		_posture_break()


func _parry(pos: Vector3) -> int:
	_guard_count = 0
	_parry_threshold = randi_range(2, 4) if phase == 1 else randi_range(1, 3)
	_seq.clear()
	_play_attack("b_parry_counter", 0.0)
	Fx.sparks(get_parent(), pos, Vector3.UP, Fx.SPARK_PARRY)
	Sfx.play("boss_parry", pos, 3.0, 1.0, 0.04)
	Game.hitstop(0.06)
	Game.shake(0.2, 0.15)
	return Combat.RESULT_DEFLECT


func _take_hit(info: Dictionary, flinch: bool) -> int:
	var pos: Vector3 = info.get("point", global_position + Vector3.UP * 1.3)
	damage(float(info.get("dmg", 40.0)))
	var broke := add_posture(float(info.get("posture", 7.0)))
	var away := Combat.flat(global_position - opponent.global_position).normalized() if opponent else Vector3.BACK
	Fx.blood(get_parent(), pos, away + Vector3.UP * 0.3, 30)
	Sfx.play("hit", pos, 1.0, 0.95, 0.08)
	Game.hitstop(0.045)
	Game.shake(0.14, 0.12)
	if hp <= 0.0 or broke:
		_posture_break()
	elif flinch:
		_react("b_flinch")
	else:
		anim.kick(Vector3(0, 0.2, 0.6), Vector3(0.8, 0, 0))
	return Combat.RESULT_HIT


func _react(clip_name: String) -> void:
	state = S.REACT
	state_time = 0.0
	_seq.clear()
	_end_perilous()
	root_scale = 1.0
	anim.play(clip_name, 0.05)
	reset_hits()


# ---------------------------------------------------------------------------- our hits
func _on_weapon_contact(info: Dictionary) -> void:
	if not (opponent is Player):
		return
	var p: Player = opponent
	if info.has("mikiri_from") and not info.has("release_time"):
		info["release_time"] = _release_time(info)
	var res := p.receive_attack(info, self)
	match res:
		Combat.RESULT_DEFLECT:
			var final_hit := bool(info.get("final", false))
			var gain := float(info.get("boss_posture", 10.0)) * (Combat.FINAL_DEFLECT_BONUS if final_hit else 1.0)
			# Deflecting several strikes in quick succession hits his posture harder.
			gain *= 1.0 + Combat.DEFLECT_CHAIN_BONUS * float(clampi(p.deflect_chain - 1, 0, Combat.DEFLECT_CHAIN_MAX_STEPS))
			if add_posture(gain):
				_posture_break()
			elif final_hit:
				_react("b_recoil")
			else:
				anim.kick(Vector3(0.0, 0.8, 1.6), Vector3(2.4, 0.0, 0.0))
		Combat.RESULT_MIKIRI:
			_react("b_mikiri_react")
			if add_posture(Combat.MIKIRI_POSTURE):
				_posture_break()
		Combat.RESULT_BLOCK:
			anim.kick(Vector3(0.0, 0.3, 0.6), Vector3(0.8, 0.0, 0.0))


func receive_kick(p: Player, foot: Vector3) -> void:
	match state:
		S.INTRO, S.STAGGER, S.DEATHBLOWN, S.REVIVE, S.DEAD:
			return
	var bonus := 1.6 if anim.is_playing("b_sweep") else 1.0
	Sfx.play("kick", foot, 2.0)
	Fx.dust(get_parent(), foot, 8, 0.3)
	Game.hitstop(0.05)
	Game.shake(0.22, 0.15)
	if add_posture(Combat.KICK_POSTURE * bonus):
		_posture_break()
		return
	if state != S.ATTACK or _in_vuln() or anim.is_playing("b_sweep"):
		_react("b_kicked")
	face_now(p.global_position)


# ---------------------------------------------------------------------------- posture break / deathblow
func _posture_break() -> void:
	state = S.STAGGER
	state_time = 0.0
	_seq.clear()
	_end_perilous()
	root_scale = 1.0
	posture = max_posture
	vitals_changed.emit()
	anim.play("b_posture_break", 0.06)
	var chest := rig.joint_world("chest") + Vector3(0, 0.15, 0)
	Fx.sparks(get_parent(), chest + forward() * 0.3, Vector3.UP, Fx.SPARK_BREAK)
	Sfx.play_ui("posture_break", 0.0)
	Game.hitstop(Combat.HITSTOP_POSTURE_BREAK)
	Game.slowmo(0.45, 0.45)
	Game.shake(0.5, 0.35)
	Game.rumble(0.6, 1.0, 0.3)
	posture_broken.emit()


func is_deathblow_ready() -> bool:
	return state == S.STAGGER and anim.time < DEATHBLOW_WINDOW_END


func begin_deathblow(p: Player) -> void:
	state = S.DEATHBLOWN
	state_time = 0.0
	deathblow_marker.visible = false
	face_now(p.global_position)
	anim.play("b_deathblow_react", 0.12)


func on_deathblow_stab(blade_pts: PackedVector3Array) -> void:
	var tip := blade_pts[blade_pts.size() - 1] if blade_pts.size() > 0 else rig.joint_world("chest")
	var chest := rig.joint_world("chest") + Vector3(0, 0.12, 0)
	Fx.blood(get_parent(), chest.lerp(tip, 0.5), Combat.flat(tip - chest) + Vector3.UP * 0.2, 60, true)
	Sfx.play_ui("deathblow", 2.0)
	Game.hitstop(Combat.HITSTOP_DEATHBLOW)
	Game.slowmo(0.7, 0.3)
	Game.shake(0.45, 0.3)
	Game.rumble(0.8, 1.0, 0.35)


func on_deathblow_pull(blade_pts: PackedVector3Array) -> void:
	var chest := rig.joint_world("chest") + Vector3(0, 0.12, 0)
	var dir := -forward()
	if blade_pts.size() > 0:
		dir = Combat.flat(blade_pts[blade_pts.size() - 1] - chest)
	Fx.blood(get_parent(), chest + forward() * 0.25, dir + Vector3.UP * 0.4, 70, true)
	Sfx.play("deathblow_pull", chest, 2.0)


func _after_deathblow() -> void:
	lives_left -= 1
	life_lost.emit(lives_left)
	if lives_left > 0:
		state = S.REVIVE
		state_time = 0.0
		anim.play("b_revive", 0.2)
	else:
		state = S.DEAD
		state_time = 0.0
		anim.play("b_death", 0.2)
		aura.emitting = false
		_glow_target = 0.0
		if eye_light:
			var tw := eye_light.create_tween()
			tw.tween_property(eye_light, "light_energy", 0.0, 2.0)
		var tree := get_tree()
		if tree:
			tree.create_timer(2.2, false).timeout.connect(func(): defeated.emit())


func _enter_phase_two() -> void:
	phase = 2
	hp = max_hp
	posture = 0.0
	attack_speed = 1.08
	aggression = 1.5
	_base_glow = 0.9
	_glow_target = _base_glow
	aura.amount = 48
	if eye_light:
		eye_light.light_energy = 1.3
	vitals_changed.emit()
	Sfx.play_ui("roar", 0.0)
	Game.shake(0.35, 0.8)
	Fx.light_pulse(get_parent(), global_position + Vector3(0, 1.6, 0), Color(1.0, 0.35, 0.1), 6.0, 7.0, 0.8)


# ---------------------------------------------------------------------------- events + visuals
func _on_anim_event(_clip: String, ev: Dictionary) -> void:
	match str(ev.get("type", "")):
		"perilous":
			_begin_perilous(str(ev.get("kind", "")))
		"sfx":
			Sfx.play(str(ev.get("name", "")), rig.joint_world("chest"), 0.0, 1.0, 0.05)
		"ground_impact":
			var pts := rig.blade_world(str(ev.get("blade", "upper")))
			if pts.size() > 0:
				var tip := pts[pts.size() - 1]
				var ground := Vector3(tip.x, global_position.y, tip.z)
				Fx.dust(get_parent(), ground, 22, 0.8)
				Fx.sparks(get_parent(), ground + Vector3(0, 0.05, 0), Vector3.UP, Fx.SPARK_GROUND)
				Sfx.play("ground_impact", ground, 2.0)
				Game.shake(0.22, 0.2)
		"boss_parry":
			pass
		"throw":
			_throw_shuriken(int(ev.get("index", 0)))
		"glint":
			Fx.flash(get_parent(), rig.joint_world("hand_l"), 0.28, Color(1.0, 0.85, 0.6), true)
		"roar":
			_enter_phase_two()


## Shuriken from the left hand at where the player will be (a little lead on their movement).
## Resolved by the player like any strike; deflecting them costs him no posture (as in Sekiro).
func _throw_shuriken(index: int) -> void:
	if not (opponent is Player):
		return
	var from := rig.joint_world("hand_l")
	var aim := opponent.global_position + Vector3(0, 1.05, 0)
	var flight := from.distance_to(aim) / Shuriken.SPEED
	aim += Combat.flat(opponent.velocity) * flight * 0.6
	var info := {"kind": "projectile", "dir": "mid", "dmg": 8, "posture_block": 12, "posture_deflect": 3,
		"boss_posture": 0, "clip": anim.clip.name if anim.clip != null else "", "index": index}
	Shuriken.throw(get_parent(), from, aim, self, opponent as Player, info)
	Sfx.play("throw", from, 0.0, 1.0, 0.06)


func _begin_perilous(kind: String) -> void:
	_perilous_clip = anim.clip.name if anim.clip else ""
	_glow_target = 3.2
	for t in trails:
		(t as WeaponTrail).force_color = Color(1.0, 0.12, 0.05, 0.75)
	if _danger_tex:
		Fx.kanji(self, Vector3(0, 2.55, 0), _danger_tex, Color(2.4, 0.12, 0.06, 1.0), 0.55)
	Fx.light_pulse(get_parent(), global_position + Vector3(0, 2.2, 0), Color(1.0, 0.1, 0.05), 5.0, 6.0, 0.5)
	Sfx.play_ui("perilous", 1.0)
	perilous_warning.emit(kind)


func _end_perilous() -> void:
	if _perilous_clip == "":
		return
	_perilous_clip = ""
	_glow_target = _base_glow
	for t in trails:
		(t as WeaponTrail).force_color = Color(0, 0, 0, 0)


func _update_glow(delta: float) -> void:
	if _perilous_clip != "" and (anim.clip == null or anim.clip.name != _perilous_clip):
		_end_perilous()
	_glow = move_toward(_glow, _glow_target, delta * (12.0 if _glow_target > _glow else 3.0))
	if blade_mat:
		blade_mat.emission_energy_multiplier = _glow
	if eye_mat:
		eye_mat.emission_energy_multiplier = 7.0 + _glow * 2.0


func _footsteps() -> void:
	if state != S.NEUTRAL or not anim.loco_active or anim.loco_cycle_rate <= 0.01:
		return
	var ph := fposmod(anim.loco_phase, 1.0)
	var crossed := (_last_step_phase < 0.5 and ph >= 0.5) or (ph < _last_step_phase)
	_last_step_phase = ph
	if crossed:
		Sfx.play("step", global_position, -9.0, 0.78, 0.08)
