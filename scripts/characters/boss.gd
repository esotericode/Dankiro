class_name Boss
extends Combatant
## The Twin Fang. Staff-and-blades duelist with Sekiro-style behaviour:
##  * Attack strings with mix-up enders (thrust / sweep / delayed overhead).
##  * Guards most attacks from neutral; blocked hits build HIS posture; mashing gets parried
##    and punished with a counter.
##  * Posture regenerates unless pressured; regen slows as his vitality drops.
##  * Posture break (or 0 vitality) -> kneels, deathblow window. Three lives: after each
##    deathblow he rises into the next phase (2 is faster and more aggressive; 3 is 2 with
##    the Tempest of Fangs and a harder Inferno).
##  * Phase 2 on: his staff smoulders, and he has the Inferno (scripts/combat/inferno.gd):
##    he opens phases 2 and 3 with it (phase 3's sends waves of fire too), then uses it every
##    so often (INFERNO_COOLDOWN).
##  * Phase 3: the Tempest of Fangs (b_tempest), his signature string: six blows in a rhythm
##    you learn, tracking you and closing in between them, so you deflect the set.

signal posture_broken
signal life_lost(lives_left: int)
signal defeated
signal perilous_warning(kind: String)
signal struck(result: int, point: Vector3)   ## the player's sword reached him: Combat.RESULT_* (hit, block, parry)
signal executed(final: bool)                 ## a deathblow's blade went in (final: his last life)

enum S { INTRO, NEUTRAL, ATTACK, GUARD, REACT, STAGGER, DEATHBLOWN, REVIVE, DEAD, INFERNO }

const LOCO := {"idle": "b_idle", "fwd": "b_walk_fwd", "back": "b_walk_back", "left": "b_walk_left",
	"right": "b_walk_right", "run": "b_run"}
const WALK := 1.8
const STRAFE := 1.25
const RUN := 4.8
const CHARGE := 6.4                  ## running at you: faster than your run, a touch under your sprint
const MOVE_ACCEL := 9.0              ## m/s^2: how fast his run builds, turns and pulls up
const WALK_ACCEL := 5.0              ## ...and his walking and strafing (no instant starts or reversals)
const CHARGE_ACCEL := 12.0
const ARENA_RADIUS := 13.5
const LEAP_STRIKE := 2.0              ## how far from you a leap lands (its slam reaches ~1.2 to 2.4 m)
const DEATHBLOW_WINDOW_END := 2.75   ## b_posture_break time when he starts rising
const INFERNO_COOLDOWN := 40.0       ## seconds from the end of one Inferno until he may use it again

## steps: [options ("a|b"), chance]; range: [min_d, max_d] meters; weight; min_phase (optional)
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
	"leap": {"steps": [["b_leap", 1.0], ["b_combo_2", 0.35]], "range": [4.6, 9.4], "weight": 2.6},
	"retreat": {"steps": [["b_backstep", 1.0], ["b_thrust|b_leap", 0.9]], "range": [0.0, 2.0], "weight": 0.9},
	"shuriken_4": {"steps": [["b_shuriken_4", 1.0], ["b_leap|b_thrust", 0.4]], "range": [0.0, 4.5], "weight": 1.1},
	"shuriken_5": {"steps": [["b_shuriken_5", 1.0], ["b_leap", 0.35]], "range": [0.0, 4.5], "weight": 0.8},
	"dash_cut": {"steps": [["b_dash_cut", 1.0], ["b_combo_2|b_sweep|b_thrust", 0.5]], "range": [3.0, 4.2], "weight": 1.0},
	"tempest": {"steps": [["b_tempest", 1.0]], "range": [0.0, 4.4], "weight": 2.4, "min_phase": 3},
	# His ways out of a pummeling (Boss._escape picks these; he never opens with them).
	"evade": {"steps": [["b_evade", 1.0], ["b_thrust|b_leap|b_shuriken_4", 0.45]], "range": [0.0, 99.0], "weight": 0.0,
		"escape": true},
	"sidestep_l": {"steps": [["b_sidestep_l", 1.0], ["b_backhand|b_combo_1|b_thrust", 0.5]], "range": [0.0, 99.0],
		"weight": 0.0, "escape": true},
	"sidestep_r": {"steps": [["b_sidestep_r", 1.0], ["b_backhand|b_combo_1|b_thrust", 0.5]], "range": [0.0, 99.0],
		"weight": 0.0, "escape": true},
}

## How he gets out of a pummeling, once he's taken his share of hits (Boss._escape): the weight
## of each, and the room it needs behind him (to the side for the sidestep). Never the same one
## twice running, and the one before that less often.
const ESCAPES := {
	"evade": {"weight": 1.2, "room": 5.4},       # a big leap back, then maybe a thrust, leap or volley
	"shuriken": {"weight": 1.0, "room": 4.8},    # a shuriken volley (it starts with a leap back)
	"retreat": {"weight": 0.8, "room": 3.0},     # a backstep hop into a thrust or leap
	"sidestep": {"weight": 1.0, "room": 2.8},    # a hop aside, then maybe a cut from there
	"sweep": {"weight": 0.55, "room": 0.0},      # the perilous sweep through your combo: jump it
	"parry": {"weight": 0.6, "room": 0.0},       # deflects your swing and counters (facing you)
}
const ESCAPE_SEQS := ["evade", "sidestep_l", "sidestep_r", "retreat"]

## Non-attack behaviours that compete with the sequences: [min, max] distance and weight.
##  charge     - run at you and flow into a running cut
##  reposition - run to another spot around you, then open with a special from there
##  hold       - stand and watch for a moment (breaks his rhythm)
##  flourish   - plant the staff with a stamp while you keep your distance (you can punish it)
const MOVES := {
	"charge": {"range": [5.0, 40.0], "weight": 2.4},
	"reposition": {"range": [1.5, 6.5], "weight": 0.7},
	"hold": {"range": [2.2, 9.0], "weight": 0.55},
	"flourish": {"range": [5.5, 12.0], "weight": 0.3},
}
## What he opens with once he's run round you to a new spot, and how likely each is (where its
## range fits): "" walks back in and picks as usual.
const AFTER_REPOSITION := [["leap", 1.0], ["thrust", 1.0], ["shuriken_4", 0.5], ["shuriken_5", 0.4], ["charge", 0.35],
	["", 0.8]]
## Phase 2 on, his shuriken volleys come in two sets: the second from the ground straight after
## the first (0.4 to 0.55 s), with a glint of steel as its tell.
const DOUBLE_VOLLEY := {"b_shuriken_4": "b_shuriken_4x2", "b_shuriken_5": "b_shuriken_5x2"}

## What changes when he rises into a phase (phase 1 is his base setup). Everything that
## checks `phase >= 2` applies to phase 3 as well. Phase 3 adds the Tempest of Fangs (SEQUENCES
## "tempest", min_phase 3) and waves of fire in the Inferno.
const PHASE_TWO := {"attack_speed": 1.08, "aggression": 1.5, "glow": 0.9, "aura": 48, "eye_light": 0.4}
const PHASES := {2: PHASE_TWO, 3: PHASE_TWO}

var state: int = S.INTRO
var state_time := 0.0
var lives_left := Combat.BOSS_LIVES
var phase := 1
var display_name := "The Twin Fang"
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
var _pummel := 0                   ## hits he's taken reeling since he last got out of it
var _endure := 3                   ## ...how many he takes before he escapes instead of reeling again
var _since_hit := 99.0
var _escapes: Array = []           ## the escapes he's used, most recent first
var escape_count := 0              ## ...and how many (the lab counts them)
var _punished_seq := ""             ## the sequence you last punished him for: he avoids reopening with it
var _last_step_phase := 0.0
var _mode := ""                     ## "" (stalk), "charge", "reposition", "hold"
var _mode_time := 0.0
var _mode_target := Vector3.ZERO
var _move_vel := Vector3.ZERO        ## his own ground velocity in neutral, eased (no instant starts, stops or turns)
var _rp_sign := 1.0                  ## repositioning: which way round you he runs
var _rp_radius := 6.0                ## ...how far out from you
var _rp_left := 0.0                  ## ...how much of the way round he still has to go (radians)
var _rp_prev_ang := 0.0
var _rp_settle := -1.0               ## ...seconds left standing, facing you, before he acts (-1: still running)
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
var inferno: Inferno
var staff_fire: StaffFire
var inferno_uses := 0
var _inferno_at := INF              ## Game.clock from when he may use the Inferno again
var _opener := false                ## open with the Inferno as soon as the fight starts
var _break_on_landing := false      ## a deflected shuriken filled his posture while he was in the air
var _flare_off_at := -1.0           ## Game.clock when a Tempest flare of his blades dies back down
var _flare_fade := 1.6              ## ...and how fast (level per second)


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
		tr.setup(rig, bname, WeaponTrail.EMBER)
		tr.brightness = 1.2
		tr.min_speed = 7.0
		tr.life = 0.13
		tr.inner = 0.55
		rig.add_child(tr)
		trails.append(tr)
	_build_aura()
	staff_fire = StaffFire.new()
	staff_fire.name = "StaffFire"
	rig.add_child(staff_fire)
	staff_fire.setup(rig)
	inferno = Inferno.new()
	inferno.name = "Inferno"
	add_child(inferno)
	inferno.setup(self)
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


## Weapon trails mark strikes: they show during an attack up to just after its last hit window,
## not while he brings the staff back to his stance (a fast return would look like another swing).
func _striking() -> bool:
	if state != S.ATTACK or anim.clip == null or anim.loco_active or anim.clip.hits.is_empty():
		return false
	var last := 0.0
	for h in anim.clip.hits:
		last = maxf(last, float(h["to"]))
	return anim.time <= last + 0.06


## False while he's hopping out of your reach (the clip's "iframes" window, e.g. his backstep).
func can_be_hit() -> bool:
	if state == S.ATTACK and anim.clip != null and not anim.loco_active and anim.clip.raw.has("iframes"):
		var w: Array = anim.clip.raw["iframes"]
		if anim.time >= float(w[0]) and anim.time <= float(w[1]):
			return false
	return true


func is_dead() -> bool:
	return state == S.DEAD


## Stops attacking (used after the player dies).
func set_passive(v: bool) -> void:
	passive = v
	if v and state == S.INFERNO:
		inferno.abort()
		_to_neutral(0.5)


func start_fight() -> void:
	state = S.NEUTRAL
	state_time = 0.0
	cooldown = 1.4
	anim.play_locomotion(LOCO, 0.25)
	if phase >= 2:
		_opener = true              # starting in phase 2 or 3 (Options): he opens with the Inferno
		cooldown = 0.5


func play_intro() -> void:
	state = S.INTRO
	state_time = 0.0
	anim.play("b_intro", 0.2)


# ====================================================================== main loop
func _physics_process(delta: float) -> void:
	state_time += delta
	_since_blocked += delta
	_since_hit += delta
	if _since_hit > 2.2:
		_pummel = 0                  # you let him off: the count starts again
	if _since_blocked > 1.6:
		_guard_count = 0
	var planar := Vector3.ZERO
	if _break_on_landing and not _airborne():
		_break_on_landing = false
		if state == S.NEUTRAL or state == S.ATTACK or state == S.GUARD or state == S.REACT:
			_posture_break()
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
				_recover()
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
				if phase >= 2 and not passive and opponent != null:
					begin_inferno()      # he opens phases 2 and 3 with the Inferno
				else:
					_to_neutral(0.8)
		S.INFERNO:
			planar = inferno.update(delta)
		S.DEAD:
			pass
	anim.update(delta)
	process_weapon_hits()
	if state == S.ATTACK:
		_check_mikiri()
	var striking := _striking()
	for t in trails:
		(t as WeaponTrail).active = striking
	planar += root_motion_velocity(delta)
	apply_motion(delta, planar)
	_update_glow(delta)
	if state == S.INFERNO:
		# His posture holds through the Inferno: your sword can't touch him for its ~12 s, so
		# letting it drain would take back what you'd built for surviving it. It starts
		# recovering again the usual delay after he hands back (into his spent punish window).
		_since_posture_hit = 0.0
	elif state != S.STAGGER and state != S.DEATHBLOWN and state != S.DEAD:
		tick_posture(delta, 0.3 + 0.7 * (hp / max_hp))
	_footsteps()


func _to_neutral(cd: float) -> void:
	state = S.NEUTRAL
	state_time = 0.0
	_mode = ""
	_move_vel = Vector3.ZERO
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
	if _opener and cooldown <= 0.0:
		_opener = false
		begin_inferno()
		return Vector3.ZERO
	match _mode:
		"charge":
			return _mode_charge(delta, d, dirp)
		"reposition":
			return _mode_reposition(delta, d)
		"hold":
			turn_toward(opponent.global_position, 200.0, delta)
			_move_vel = _move_vel.move_toward(Vector3.ZERO, WALK_ACCEL * delta)
			_loco_anim()
			if _mode_time > _mode_target.x:
				_mode = ""
				cooldown = minf(cooldown, 0.1)
			return _move_vel
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
	_move_vel = _move_vel.move_toward(_keep_off_wall(vel), (MOVE_ACCEL if running else WALK_ACCEL) * delta)
	if running and _move_vel.length() > 2.0:
		turn_toward(global_position + _move_vel, 360.0, delta)
	else:
		turn_toward(opponent.global_position, 300.0, delta)
	_loco_anim()
	if cooldown <= 0.0:
		var pick := _pick_action(d)
		if pick != "" and _begin_action(pick, d):
			return Vector3.ZERO
	return _move_vel


## Plays his walk / strafe / run blend for the velocity he's actually moving at: the run only
## when he's going fast in the direction he faces (otherwise the walk clips, forward, back or
## sideways, so his feet never slide).
func _loco_anim() -> void:
	var spd := _move_vel.length()
	var running := spd > 2.6 and forward().angle_to(_move_vel) < deg_to_rad(50.0)
	anim.play_locomotion(LOCO)
	anim.set_locomotion_velocity(Basis(Vector3.UP, -facing) * _move_vel, WALK, running)


## Takes out the part of a velocity that would carry him into the wall round the plaza as he
## nears it (he runs along it instead).
func _keep_off_wall(v: Vector3) -> Vector3:
	var here := Combat.flat(global_position)
	var rr := here.length()
	var soft := ARENA_RADIUS - 2.2
	if rr < soft:
		return v
	var n := here / rr
	var outward := v.dot(n)
	if outward > 0.0:
		v -= n * outward * clampf((rr - soft) / 1.4, 0.0, 1.0)
	return v


## Runs straight at the player; in range, flows into the running cut.
func _mode_charge(delta: float, d: float, dirp: Vector3) -> Vector3:
	turn_toward(opponent.global_position, 540.0, delta)
	# (he builds up to his sprint over half a second, turning into it)
	_move_vel = _move_vel.move_toward(dirp * CHARGE, CHARGE_ACCEL * delta)
	_loco_anim()
	if d < 3.6:
		_mode = ""
		_start_sequence("dash_cut")
		return Vector3.ZERO
	if _mode_time > 3.5:
		_mode = ""
		cooldown = 0.2
	return _move_vel


## Runs round you to another spot, then opens from there. Like a fighter, not a chess piece:
## if he's close he backs off facing you first, then runs an arc round you (you see his side,
## not his back) at a pace that builds and eases off, keeps off the wall, pulls up, turns to
## face you and settles for a moment before he acts.
func _mode_reposition(delta: float, d: float) -> Vector3:
	var rel := Combat.flat(global_position - opponent.global_position)
	var r := maxf(rel.length(), 0.01)
	var out := rel / r
	var ang := atan2(rel.x, rel.z)
	_rp_left -= wrapf(ang - _rp_prev_ang, -PI, PI) * _rp_sign
	_rp_prev_ang = ang
	if _rp_settle >= 0.0:
		# pulled up: square up to you, a beat standing still, then go
		_move_vel = _move_vel.move_toward(Vector3.ZERO, MOVE_ACCEL * delta)
		if _move_vel.length() < 0.4:
			_rp_settle -= delta
		turn_toward(opponent.global_position, 330.0, delta)
		_loco_anim()
		var squared := Combat.angle_to(global_position, forward(), opponent.global_position) < 20.0
		if _rp_settle <= 0.0 and (squared or _mode_time > 5.0):
			_mode = ""
			_after_reposition(d)
			return Vector3.ZERO
		return _move_vel
	var remaining := maxf(_rp_left, 0.0) * r                 # metres of arc still to run
	var tangent := Vector3(out.z, 0.0, -out.x) * _rp_sign
	var v_r := clampf((_rp_radius - r) * 1.8, -2.0, 2.6)      # out to (or in to) his running line
	var v_t := RUN * clampf((r - 2.2) / 1.3, 0.15, 1.0)       # close to you he backs off before he runs round
	v_t = minf(v_t, sqrt(2.0 * 6.0 * remaining))              # easing off as he nears the spot
	var want := _keep_off_wall(out * v_r + tangent * v_t)
	# up close he backpedals, facing you, before he turns and runs
	var close := r < 3.4
	var cap := 2.6 if close else RUN
	if want.length() > cap:
		want = want.normalized() * cap
	_move_vel = _move_vel.move_toward(want, MOVE_ACCEL * delta)
	# he runs where he's going; once he's pulled up he turns to you
	if not close and _move_vel.length() > 1.8 and remaining > 0.3:
		turn_toward(global_position + _move_vel, 420.0, delta)
	else:
		turn_toward(opponent.global_position, 330.0, delta)
	_loco_anim()
	if (remaining < 0.4 and absf(r - _rp_radius) < 1.0) or _mode_time > 3.6:
		_rp_settle = randf_range(0.2, 0.45)
	return _move_vel


## Sets up a run round you: which way (the side that keeps him off the wall; either if both
## are clear), how far out and how far round.
func _plan_reposition() -> void:
	var rel := Combat.flat(global_position - opponent.global_position)
	if rel.length() < 0.1:
		rel = -forward()
	var a0 := atan2(rel.x, rel.z)
	var sweep := deg_to_rad(randf_range(60.0, 110.0))
	var radius := randf_range(5.0, 6.8)
	var op := Combat.flat(opponent.global_position)
	var room := {}
	for sg in [1.0, -1.0]:
		var a1: float = a0 + sweep * float(sg)
		room[sg] = ARENA_RADIUS - (op + Vector3(sin(a1), 0.0, cos(a1)) * radius).length()
	var way := 1.0 if randf() < 0.5 else -1.0
	if float(room[way]) < 1.5 and float(room[-way]) > float(room[way]):
		way = -way
	# still too close to the wall that way: run a tighter circle
	var a_end := a0 + sweep * way
	var dir_end := Vector3(sin(a_end), 0.0, cos(a_end))
	while radius > 3.8 and (op + dir_end * radius).length() > ARENA_RADIUS - 1.5:
		radius -= 0.3
	_rp_sign = way
	_rp_radius = radius
	_rp_left = sweep
	_rp_prev_ang = a0
	_rp_settle = -1.0
	_mode_target = opponent.global_position + dir_end * radius


## What he opens with from the spot he ran to.
func _after_reposition(d: float) -> void:
	var options: Array = []
	var total := 0.0
	for o in AFTER_REPOSITION:
		var sname: String = o[0]
		if sname != "":
			var r: Array = MOVES[sname]["range"] if MOVES.has(sname) else SEQUENCES[sname]["range"]
			var hi := float(r[1]) + (3.0 if sname.begins_with("shuriken") else 0.5)
			if d < float(r[0]) - 0.3 or d > hi:
				continue
		options.append(o)
		total += float(o[1])
	var roll := randf() * total
	var pick := ""
	for o in options:
		roll -= float(o[1])
		if roll <= 0.0:
			pick = str(o[0])
			break
	if pick == "charge":
		_begin_action("charge", d)
	elif pick != "":
		_start_sequence(pick)
	else:
		cooldown = randf_range(0.3, 0.8)


## Starts an attack sequence or a movement mode. Returns false if nothing started.
func _begin_action(pick: String, d: float) -> bool:
	_mode_time = 0.0
	match pick:
		"charge":
			_mode = "charge"
			return true
		"reposition":
			_plan_reposition()
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
		"inferno":
			begin_inferno()
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
		if int(sd.get("min_phase", 1)) > phase or bool(sd.get("escape", false)):
			continue
		var r: Array = sd["range"]
		if d < float(r[0]) or d > float(r[1]):
			continue
		var w := float(sd["weight"])
		if sname == _last_seq:
			w *= 0.35 if _repeat >= 1 else 0.7
		if sname == _punished_seq:
			w *= 0.2
		if healing and (sname == "thrust" or sname == "leap" or sname == "fang_string" or sname == "charge"):
			w *= 3.0
		if phase >= 2 and (sname == "fang_string" or sname == "whirl" or sname == "leap" or sname == "charge"):
			w *= 1.4
		if phase >= 2 and sname == "hold":
			w *= 0.5
		options.append([sname, w])
		total += w
	# The Inferno (phase 2 on): more and more likely the longer it's been available.
	if inferno_ready():
		var wi := 1.2 + 0.12 * (Game.clock - _inferno_at)
		options.append(["inferno", wi])
		total += wi
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
	_pummel = 0
	var first: Array = _seq.pop_front()
	_play_attack(_choose(str(first[0])), 0.0)


func _choose(options: String) -> String:
	var parts := options.split("|")
	return parts[randi() % parts.size()]


func _play_attack(clip_name: String, start: float) -> void:
	if phase >= 2:
		clip_name = DOUBLE_VOLLEY.get(clip_name, clip_name)
	state = S.ATTACK
	state_time = 0.0
	_end_perilous()
	anim.play(clip_name, 0.14 if start <= 0.0 else 0.1, attack_speed, start)
	reset_hits()
	root_scale = 1.0
	if anim.clip.raw.has("root_scale_window") and opponent != null:
		root_scale = _leap_scale(anim.clip, start)


## How much of a leap's travel (its clip's root motion, unscaled) is still to come at time `t`.
func _leap_left(c: ClipData, t: float) -> float:
	var w: Array = c.raw["root_scale_window"]
	return (c.sample(t)["root"] as Vector3).z - (c.sample(float(w[1]))["root"] as Vector3).z


## The root-motion scale that ends a leap LEAP_STRIKE from you: from where you'll be when he comes
## down, going by how fast you're moving toward or away from him now.
func _leap_scale(c: ClipData, t: float) -> float:
	var w: Array = c.raw["root_scale_window"]
	var to := Combat.flat(opponent.global_position - global_position)
	var d := to.length()
	if d > 0.01:
		var lead := maxf(0.0, float(w[1]) - t) / maxf(anim.speed, 0.01)
		d += Combat.flat(opponent.velocity).dot(to / d) * lead
	return clampf((d - LEAP_STRIKE) / maxf(_leap_left(c, t), 0.25), 0.35, 1.7)


## A string that steps in with every blow ("hold_distance") keeps its striking distance instead
## of walking into you when you stand your ground.
func hold_distance() -> float:
	if state == S.ATTACK and anim.clip != null and not anim.loco_active:
		return maxf(min_opponent_distance, anim.clip.get_float("hold_distance", 0.0))
	return min_opponent_distance


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
	# Leaps ("root_scale_window": [from, to], the jump's travel): in the air he steers his landing
	# (see _leap_scale), so walking in, backing off or circling round him doesn't leave him
	# slamming the ground beside you. As in Sekiro: deflect it or dodge it, you can't walk out
	# from under it. The last bit of the jump is left as it is.
	if c.raw.has("root_scale_window"):
		var w: Array = c.raw["root_scale_window"]
		if t > float(w[1]):
			root_scale = 1.0
		elif t >= float(w[0]) and opponent != null and _leap_left(c, t) > 0.25:
			root_scale = move_toward(root_scale, _leap_scale(c, t), 3.0 * delta)   # (no jerks mid-air)
	# Adaptive lunge ("lunge_reach": [at, until, reach, lunge length]): when the lunge starts he
	# measures the gap and stretches the lunge so the blade still gets to you if you backed off
	# (as in Sekiro, you can't just step away from a thrust).
	if c.raw.has("lunge_reach"):
		var lr: Array = c.raw["lunge_reach"]
		var t_prev := t - delta * anim.speed
		if t_prev < float(lr[0]) and t >= float(lr[0]):
			var over := distance_to_opponent() + 0.9 - float(lr[2])
			root_scale = clampf(1.0 + over / float(lr[3]), 1.0, 2.0)
		elif t > float(lr[1]):
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
		var escaped := _seq_name in ESCAPE_SEQS
		_to_neutral(cd)
		# out of your reach after an escape: sometimes he runs round you to come in from elsewhere
		if escaped and not passive and opponent != null and randf() < 0.35:
			_begin_action("reposition", distance_to_opponent())
		return Vector3.ZERO
	return _close_distance(c, t)


## Gap-closing during a wind-up (clip "close": [from, to, ideal distance, max speed], or a list
## of them for a string that closes in before each blow): he shuffles in so a strike started at
## the edge of his range still arrives, like Souls bosses.
func _close_distance(c: ClipData, t: float) -> Vector3:
	var windows: Array = c.raw.get("close", [])
	if windows.is_empty() or not (windows[0] is Array):
		windows = [windows]
	var close: Array = []
	for w in windows:
		var wa: Array = w
		if wa.size() >= 4 and t >= float(wa[0]) and t <= float(wa[1]):
			close = wa
			break
	if close.is_empty() or opponent == null:
		return Vector3.ZERO
	var to := Combat.flat(opponent.global_position - global_position)
	var d := to.length()
	var ideal := float(close[2])
	if d <= ideal or d < 0.01:
		return Vector3.ZERO
	var t_left := maxf(0.05, float(close[1]) - t)
	# Close the gap by the end of the window, and never slower than a firm chase that matches
	# how fast you're backing off (so stepping, walking or running away during the wind-up
	# doesn't outrun him), up to the clip's max speed.
	var away := maxf(0.0, Combat.flat(opponent.velocity).dot(to / d))
	var speed := maxf((d - ideal) / (t_left + 0.1), away + (d - ideal) * 3.5)
	return to / d * minf(speed, float(close[3]) * attack_speed)


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
	var res := _resolve_player_attack(info, p)
	if res != Combat.RESULT_IGNORED:
		struck.emit(res, info.get("point", global_position + Vector3.UP * 1.3))
	return res


func _resolve_player_attack(info: Dictionary, p: Player) -> int:
	match state:
		S.INTRO, S.STAGGER, S.DEATHBLOWN, S.REVIVE, S.DEAD:
			return Combat.RESULT_IGNORED
		S.INFERNO:
			return _mantle(info)
	var pos: Vector3 = info.get("point", global_position + Vector3.UP * 1.3)
	var facing_ok := Combat.angle_to(global_position, forward(), p.global_position) < 100.0
	if state == S.ATTACK:
		# (mid-attack he shrugs a hit off, except in the openings his attacks leave)
		return _hit_reeling(info, pos, facing_ok) if _in_vuln() else _take_hit(info, false)
	if state == S.REACT:
		return _hit_reeling(info, pos, facing_ok)
	if facing_ok:
		_guard_count += 1
		_since_blocked = 0.0
		if _guard_count >= _parry_threshold:
			return _parry(pos)
		_block(info, pos)
		return Combat.RESULT_BLOCK
	return _hit_reeling(info, pos, facing_ok)


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
	# The counter isn't the end of it: often he presses on (so deflecting it isn't a free opening).
	_seq = [["b_combo_2|b_jab|b_backhand|b_backstep", 0.6 if phase == 1 else 0.8]]
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


## A hit that would leave him reeling. He takes a few (your reward for the opening), then
## instead of flinching again he gets out of it (_escape): the pummeling doesn't go on.
func _hit_reeling(info: Dictionary, pos: Vector3, facing_ok: bool) -> int:
	_since_hit = 0.0
	_pummel += 1
	if _pummel >= _endure and not passive:
		return _escape(info, pos, facing_ok)
	return _take_hit(info, true)


## He's taken his share: this hit still lands, but he doesn't reel from it. He escapes, a
## different way from last time: a big leap back, a shuriken volley from the air, a backstep
## into a thrust or leap, a hop aside, a sweep through your combo, or a parry and counter.
func _escape(info: Dictionary, pos: Vector3, facing_ok: bool) -> int:
	_pummel = 0
	_endure = _roll_endure()
	_punished_seq = _seq_name
	var kind := _pick_escape(facing_ok)
	if kind == "parry":
		_note_escape(kind)
		return _parry(pos)
	var res := _take_hit(info, false)
	if state == S.STAGGER or state == S.DEAD:
		return res
	if Combat.angle_to(global_position, forward(), opponent.global_position) > 60.0:
		face_now(opponent.global_position)
	_start_escape(kind)
	return res


func _pick_escape(allow_parry: bool) -> String:
	if has_meta("force_escape"):                 # (a capture shot films one on purpose)
		return str(get_meta("force_escape"))
	var back := _room(-forward())
	var aside := maxf(_room(_right()), _room(-_right()))
	var options: Array = []
	var total := 0.0
	for kind in ESCAPES:
		if kind == "parry" and not allow_parry:
			continue
		if not _escapes.is_empty() and kind == str(_escapes[0]):
			continue
		var need := float(ESCAPES[kind]["room"])
		if need > 0.0 and (aside if kind == "sidestep" else back) < need:
			continue
		var w := float(ESCAPES[kind]["weight"])
		if _escapes.size() > 1 and kind == str(_escapes[1]):
			w *= 0.5
		options.append([kind, w])
		total += w
	if options.is_empty():
		return "sweep"
	var roll := randf() * total
	for o in options:
		roll -= float(o[1])
		if roll <= 0.0:
			return str(o[0])
	return str(options[options.size() - 1][0])


func _start_escape(kind: String) -> void:
	_note_escape(kind)
	match kind:
		"shuriken":
			_start_sequence("shuriken_4" if randf() < 0.55 else "shuriken_5")
		"sidestep":
			var r_room := _room(_right())
			var l_room := _room(-_right())
			var need := float(ESCAPES["sidestep"]["room"])
			var go_right := r_room >= l_room if (r_room < need or l_room < need) else randf() < 0.5
			_start_sequence("sidestep_r" if go_right else "sidestep_l")
		_:
			_start_sequence(kind)


func _note_escape(kind: String) -> void:
	escape_count += 1
	_escapes.push_front(kind)
	if _escapes.size() > 3:
		_escapes.resize(3)


## How far he can go in a direction before the wall round the plaza.
func _room(dir: Vector3) -> float:
	var here := Combat.flat(global_position)
	var rad := ARENA_RADIUS - 0.8
	var b := here.dot(dir)
	var disc := b * b - (here.length_squared() - rad * rad)
	if disc < 0.0:
		return 0.0
	return maxf(0.0, -b + sqrt(disc))


func _right() -> Vector3:
	return forward().cross(Vector3.UP)


## How many hits he takes reeling before he escapes: three in his first life, two or three in
## his second, two in his last.
func _roll_endure() -> int:
	match phase:
		1:
			return 3
		2:
			return randi_range(2, 3)
	return 2


## Back on his feet after a flinch, recoil or kick. If you got hits in, he doesn't just stand
## there for more: usually he escapes (see _escape) or goes straight back on the attack; if he
## stands his ground, the next hits still count toward his escape.
func _recover() -> void:
	var punished := _pummel > 0
	_to_neutral(0.25 / aggression)
	if not punished or passive or opponent == null:
		return
	_punished_seq = _seq_name
	var r := randf()
	if r < 0.55 or has_meta("force_escape"):
		_pummel = 0
		_endure = _roll_endure()
		_start_escape(_pick_escape(false))
	elif r < 0.85:
		cooldown = 0.0


# ---------------------------------------------------------------------------- our hits
func _on_weapon_contact(info: Dictionary) -> int:
	if not (opponent is Player):
		return Combat.RESULT_NONE
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
	return res


func receive_kick(p: Player, foot: Vector3) -> void:
	match state:
		S.INTRO, S.STAGGER, S.DEATHBLOWN, S.REVIVE, S.DEAD:
			return
		S.INFERNO:
			FireFx.burst(get_parent(), foot, 0.6)
			Sfx.play("fire_hiss", foot, 0.0)
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
## `by_projectile`: a deflected shuriken of his broke it. Then there's no hit-stop (projectiles
## never freeze the action, see Player._hitstop), just the break's slow motion.
func _posture_break(by_projectile := false) -> void:
	_break_on_landing = false
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
	if not by_projectile:
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
	Game.slowmo(0.9, 0.3)
	executed.emit(lives_left <= 1)
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
		staff_fire.set_level(0.0, 0.5)
		_glow_target = 0.0
		if eye_light:
			var tw := eye_light.create_tween()
			tw.tween_property(eye_light, "light_energy", 0.0, 2.0)
		var tree := get_tree()
		if tree:
			tree.create_timer(2.2, false).timeout.connect(func(): defeated.emit())


## Rises into phase `n` (2 or 3): full vitality, empty posture, that phase's tuning. With
## `fanfare` he roars (on rising after a deathblow); without it (starting the fight in a later
## phase from the options) it's silent.
func _enter_phase(n: int, fanfare := true) -> void:
	phase = clampi(n, 1, Combat.BOSS_LIVES)
	hp = max_hp
	posture = 0.0
	_pummel = 0
	_endure = _roll_endure()
	var cfg: Dictionary = PHASES.get(phase, {})
	if not cfg.is_empty():
		attack_speed = float(cfg["attack_speed"])
		aggression = float(cfg["aggression"])
		_base_glow = float(cfg["glow"])
		_glow_target = _base_glow
		aura.amount = int(cfg["aura"])
		if eye_light:
			eye_light.light_energy = float(cfg["eye_light"])
	# He opens phases 2 and 3 with the Inferno (REVIVE, start_fight); after that one it's his again
	# once it's off cooldown (inferno_spent). In phase 3 the staff's already alight.
	if phase >= 2:
		_inferno_at = INF
	if phase >= 3:
		staff_fire.set_level(StaffFire.SMOULDER, 1.0)
	vitals_changed.emit()
	if fanfare:
		Sfx.play_ui("roar", 0.0)
		Game.shake(0.35, 0.8)
		Fx.light_pulse(get_parent(), global_position + Vector3(0, 1.6, 0), Color(1.0, 0.35, 0.1), 6.0, 7.0, 0.8)


## Starts the fight in phase `n` (a testing option): the earlier lives count as taken.
func set_start_phase(n: int) -> void:
	n = clampi(n, 1, Combat.BOSS_LIVES)
	lives_left = Combat.BOSS_LIVES - (n - 1)
	if n > 1:
		_enter_phase(n, false)


# ---------------------------------------------------------------------------- the Inferno
func inferno_ready() -> bool:
	return phase >= 2 and not passive and Game.clock >= _inferno_at and opponent is Player \
		and (opponent as Player).state != Player.S.DEAD


## Hands over to the Inferno (scripts/combat/inferno.gd) until the fire is spent.
func begin_inferno() -> void:
	state = S.INFERNO
	state_time = 0.0
	_mode = ""
	_seq.clear()
	_opener = false
	_end_perilous()
	root_scale = 1.0
	_inferno_at = INF
	inferno_uses += 1
	inferno.begin()


## The fire is out: he's spent (b_fire_spent is his punish window), then back to normal.
func inferno_spent() -> void:
	_inferno_at = Game.clock + INFERNO_COOLDOWN
	_seq.clear()
	_seq_name = "inferno"
	_pummel = 0
	_play_attack("b_fire_spent", 0.0)


## His burning body during the Inferno: your sword glances off the flames (no damage, no
## posture either way), like hitting his guard.
func _mantle(info: Dictionary) -> int:
	var pos: Vector3 = info.get("point", global_position + Vector3.UP * 1.3)
	FireFx.burst(get_parent(), pos, 0.7)
	Sfx.play("fire_hiss", pos, 0.0, 1.0, 0.08)
	Game.hitstop(0.03)
	Game.shake(0.08, 0.1)
	return Combat.RESULT_BLOCK


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
		"tempest":
			# The Tempest's tell: both blades flare up, then die back to their smoulder.
			staff_fire.set_level(float(ev.get("level", 1.0)), 9.0)
			_flare_off_at = Game.clock + float(ev.get("hold", 0.55))
			_flare_fade = float(ev.get("fade", 1.6))
			Sfx.play("fire_flare", rig.joint_world("chest"), 1.0, 1.1, 0.03)
			# (the flash comes from the burning upper blade, so it lights him like the fire does
			# instead of glowing on his chest)
			var up_blade := rig.blade_world("upper")
			var flash_at := rig.weapon_world_xf().origin
			if up_blade.size() >= 2:
				flash_at = (up_blade[0] + up_blade[up_blade.size() - 1]) * 0.5
			Fx.light_pulse(get_parent(), flash_at, Color(1.0, 0.5, 0.15), 2.2, 6.0, 0.4)
		"roar":
			_enter_phase(phase + 1)
		"fire_plant", "fire_charge", "fire_blast", "fire_whips", "fire_plunge", "fire_erupt":
			inferno.on_event(str(ev.get("type", "")), ev)
		"fire_gutter":
			FireFx.smoke(get_parent(), rig.joint_world("chest") + Vector3(0, 0.3, 0), 12, 0.7)


## Shuriken from the left hand at where the player will be (a little lead on their movement).
## Resolved by the player like any strike. Deflecting one costs him a little posture
## (`boss_posture`, see projectile_deflected); in Sekiro it costs none.
func _throw_shuriken(index: int) -> void:
	if not (opponent is Player):
		return
	var from := rig.joint_world("hand_l")
	var aim := opponent.global_position + Vector3(0, 1.05, 0)
	var flight := from.distance_to(aim) / Shuriken.SPEED
	aim += Combat.flat(opponent.velocity) * flight * 0.6
	# Blocking one costs you 9 posture: a whole double volley (phase 2) blocked from a fresh
	# guard costs 90 of your 100, so holding guard still gets you through it, just.
	var info := {"kind": "projectile", "dir": "mid", "dmg": 8, "posture_block": 9, "posture_deflect": 3,
		"boss_posture": 4, "clip": anim.clip.name if anim.clip != null else "", "index": index}
	Shuriken.throw(get_parent(), from, aim, self, opponent as Player, info)
	Sfx.play("throw", from, 0.0, 1.0, 0.06)


## The player deflected one of his shuriken: a little posture, no recoil (he's out of reach) and
## no deflect-chain bonus. It can fill his posture like anything else; if he's in the air then,
## he breaks as he lands.
func projectile_deflected(info: Dictionary) -> void:
	if state != S.NEUTRAL and state != S.ATTACK and state != S.GUARD and state != S.REACT:
		return
	if add_posture(float(info.get("boss_posture", 0.0))):
		if _airborne():
			_break_on_landing = true
		else:
			_posture_break(true)


## Both feet off the ground (in a leap, or hanging in the air to throw shuriken).
func _airborne() -> bool:
	return minf(rig.joint_world("foot_l").y, rig.joint_world("foot_r").y) - global_position.y > 0.22


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
	if _flare_off_at > 0.0 and Game.clock >= _flare_off_at and state != S.INFERNO:
		_flare_off_at = -1.0
		staff_fire.set_level(StaffFire.SMOULDER, _flare_fade)
	_glow = move_toward(_glow, _glow_target, delta * (12.0 if _glow_target > _glow else 3.0))
	if blade_mat:
		blade_mat.emission_energy_multiplier = _glow
	if eye_mat:
		eye_mat.emission_energy_multiplier = 3.0 + _glow * 1.2


func _footsteps() -> void:
	if state != S.NEUTRAL or not anim.loco_active or anim.loco_cycle_rate <= 0.01:
		return
	var ph := fposmod(anim.loco_phase, 1.0)
	var crossed := (_last_step_phase < 0.5 and ph >= 0.5) or (ph < _last_step_phase)
	_last_step_phase = ph
	if crossed:
		Sfx.play("step", global_position, -9.0, 0.78, 0.08)
