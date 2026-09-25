class_name Player
extends Combatant
## The shinobi. Deflect-centric controller:
##  * Guard presses are stamped with sub-tick precise game time (Game.precise_now) and the
##    deflect window is evaluated against the exact blade contact time.
##  * Mashing shrinks the window (Combat.DEFLECT_SPAM_WINDOWS); a successful deflect resets it.
##  * Stepping toward a perilous thrust = mikiri counter. Sweeps must be jumped.

signal died
signal deflect_timed(ms_before_contact: float, window_ms: float, result: String)
signal heal_charges_changed(charges: int)

enum S { MOVE, GUARD, DEFLECT, BLOCK, ATTACK, DODGE, AIR, AIR_ATTACK, JUMP_KICK, LAND, MIKIRI,
	HIT, KNOCKDOWN, GUARD_BREAK, REPELLED, HEAL, DEATHBLOW, DEAD }

const WALK_SPEED := 2.8
const RUN_SPEED := 5.2
const SPRINT_SPEED := 7.0
const GUARD_SPEED := 1.5
const JUMP_VELOCITY := 7.6
const AIR_ACCEL := 6.0
const BUFFER_TIME := 0.22
const LOCO := {"idle": "p_idle", "fwd": "p_walk_fwd", "back": "p_walk_back", "left": "p_walk_left",
	"right": "p_walk_right", "run": "p_run"}

var state: int = S.MOVE
var state_time := 0.0
var locked := true
var lock_target: Combatant
var camera_yaw := 0.0

var move_input := Vector2.ZERO
var guard_held := false
var guard_start := -99.0
var guard_window := Combat.DEFLECT_WINDOW
var _last_guard_press := -99.0
var _spam_level := 0
var _last_press_deflected := false
var _pending_guard := false
var _buffer: Dictionary = {}          ## action -> game time of press
var _dodge_held_since := -1.0

var combo_next := "p_attack_1"
var heal_charges := Combat.HEAL_CHARGES
var dodge_dir := Vector3.FORWARD
var dodge_toward_boss := false
var _dodge_rot := 0.0
var _mikiri_until := 0.0
var _invuln_until := -1.0
var _iframes := Vector2(-1, -1)
var _kick_used := false
var _air_attack_used := false
var _kick_connected := false
var _air_velocity := Vector3.ZERO
var _deathblow_shift := Vector3.ZERO
var _last_step_phase := 0.0
var _gourd: Node3D
var trail: WeaponTrail
var controls_enabled := true


func _ready() -> void:
	max_hp = Combat.PLAYER_HP
	hp = max_hp
	max_posture = Combat.PLAYER_POSTURE
	posture_regen = Combat.PLAYER_POSTURE_REGEN
	posture_delay = Combat.PLAYER_POSTURE_DELAY
	min_opponent_distance = 1.05
	process_physics_priority = -10
	_setup_rig("player")
	var built := ModelBuilder.build(rig, "player")
	var nodes: Dictionary = built["nodes"]
	_gourd = nodes.get("gourd")
	if _gourd:
		_gourd.visible = false
	trail = WeaponTrail.new()
	trail.setup(rig, "blade", Color(0.78, 0.86, 1.0, 0.6))
	rig.add_child(trail)
	anim.play_locomotion(LOCO, 0.0)
	anim.update(0.0)


# ====================================================================== input
func _unhandled_input(event: InputEvent) -> void:
	if not controls_enabled or state == S.DEAD:
		return
	if event.is_action_pressed("guard"):
		_on_guard_pressed()
	elif event.is_action_released("guard"):
		guard_held = false
	elif event.is_action_pressed("attack"):
		_buffer["attack"] = Game.precise_now()
	elif event.is_action_pressed("dodge"):
		_buffer["dodge"] = Game.precise_now()
		_dodge_held_since = Game.clock
	elif event.is_action_released("dodge"):
		_dodge_held_since = -1.0
	elif event.is_action_pressed("jump"):
		_buffer["jump"] = Game.precise_now()
	elif event.is_action_pressed("heal"):
		_buffer["heal"] = Game.precise_now()
	elif event.is_action_pressed("lock_on"):
		locked = not locked and lock_target != null
		Sfx.play_ui("lockon", -8.0)


func _on_guard_pressed() -> void:
	var now := Game.precise_now()
	if now - _last_guard_press < Combat.SPAM_INTERVAL and not _last_press_deflected:
		_spam_level = mini(_spam_level + 1, Combat.DEFLECT_SPAM_WINDOWS.size() - 1)
	else:
		_spam_level = 0
	_last_guard_press = now
	_last_press_deflected = false
	guard_held = true
	if _can_guard_now():
		_begin_guard(now)
	else:
		_pending_guard = true


func _buffered(action: String) -> bool:
	return _buffer.has(action) and Game.clock - float(_buffer[action]) <= BUFFER_TIME


func _consume(action: String) -> void:
	_buffer.erase(action)


# ====================================================================== main loop
func _physics_process(delta: float) -> void:
	if not controls_enabled:
		move_input = Vector2.ZERO
	else:
		move_input = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		if not Input.is_action_pressed("guard"):
			guard_held = false
	if Game.camera != null and Game.camera.has_method("get_yaw"):
		camera_yaw = float(Game.camera.call("get_yaw"))
	if lock_target == null or (lock_target is Boss and (lock_target as Boss).is_dead()):
		locked = false
	state_time += delta
	var planar := _update_state(delta)
	anim.update(delta)
	process_weapon_hits()
	_process_kick()
	planar += root_motion_velocity(delta)
	apply_motion(delta, planar)
	_after_move()
	_update_posture(delta)
	_footsteps()


func _update_state(delta: float) -> Vector3:
	match state:
		S.MOVE, S.GUARD:
			return _state_move(delta)
		S.DEFLECT, S.BLOCK:
			if state_time > 0.12 and _try_actions([ "attack", "dodge", "jump"]):
				return Vector3.ZERO
			if anim.finished:
				_to_neutral()
			return Vector3.ZERO
		S.ATTACK:
			return _state_attack(delta)
		S.DODGE:
			return _state_dodge(delta)
		S.AIR, S.AIR_ATTACK, S.JUMP_KICK:
			return _state_air(delta)
		S.LAND:
			if state_time > 0.08 and _try_actions(["attack", "dodge", "jump"]):
				return Vector3.ZERO
			if anim.finished:
				_to_neutral()
			return _wish_dir() * WALK_SPEED * 0.3
		S.MIKIRI:
			if state_time > 0.5 and _try_actions(["attack", "dodge", "jump"]):
				return Vector3.ZERO
			if anim.finished:
				_to_neutral()
			return Vector3.ZERO
		S.HIT, S.REPELLED:
			var cancel := 0.3 if state == S.HIT else anim.clip.get_float("cancel", 0.26)
			if state_time > cancel and _try_actions(["dodge", "jump"]):
				return Vector3.ZERO
			if anim.finished:
				_to_neutral()
			return Vector3.ZERO
		S.KNOCKDOWN:
			if state_time > 1.3 and _try_actions(["dodge", "jump"]):
				return Vector3.ZERO
			if anim.finished:
				_to_neutral()
			return Vector3.ZERO
		S.GUARD_BREAK:
			if anim.finished:
				posture = max_posture * 0.3
				vitals_changed.emit()
				_to_neutral()
			return Vector3.ZERO
		S.HEAL:
			if _gourd:
				_gourd.visible = state_time > 0.12 and state_time < 0.95
			if anim.finished:
				_to_neutral()
			return Vector3.ZERO
		S.DEATHBLOW:
			var v := Vector3.ZERO
			if state_time < 0.18:
				v = _deathblow_shift / 0.18
			if lock_target:
				turn_toward(lock_target.global_position, 720.0, delta)
			if anim.finished:
				_to_neutral()
			return v
		S.DEAD:
			return Vector3.ZERO
	return Vector3.ZERO


func _start_state(s: int) -> void:
	state = s
	state_time = 0.0
	if s != S.GUARD and s != S.MOVE:
		anim.clear_overlay()
	if _gourd and s != S.HEAL:
		_gourd.visible = false


func _to_neutral() -> void:
	if guard_held or _pending_guard:
		_start_state(S.GUARD)
		if _pending_guard:
			_begin_guard(Game.clock)
		anim.set_overlay("p_guard", 1.0, 25.0)
	else:
		_start_state(S.MOVE)
		anim.set_overlay("", 0.0)
	anim.play_locomotion(LOCO, 0.16)


func _can_guard_now() -> bool:
	match state:
		S.MOVE, S.GUARD, S.DEFLECT, S.BLOCK:
			return true
		S.ATTACK:
			var last_hit_end := 0.0
			for h in anim.clip.hits:
				last_hit_end = maxf(last_hit_end, float(h["to"]))
			return anim.time > last_hit_end + 0.02
		S.DODGE:
			return state_time > 0.26
		S.LAND:
			return state_time > 0.05
		S.MIKIRI:
			return state_time > 0.5
		S.REPELLED:
			return state_time > anim.clip.get_float("cancel", 0.26)
		S.HIT:
			return state_time > 0.32
		S.KNOCKDOWN:
			return state_time > 1.35
	return false


func _begin_guard(t: float) -> void:
	_pending_guard = false
	guard_start = t
	guard_window = float(Combat.DEFLECT_SPAM_WINDOWS[_spam_level])
	if state == S.DEFLECT or state == S.BLOCK:
		return  # keep the reaction animation; the new window is live
	if state != S.GUARD:
		_start_state(S.GUARD)
		anim.play_locomotion(LOCO, 0.08)
	anim.set_overlay("p_guard", 1.0, 30.0)


# ---------------------------------------------------------------------------- movement
func _wish_dir() -> Vector3:
	var v := Vector3(move_input.x, 0.0, move_input.y)
	if v.length() > 1.0:
		v = v.normalized()
	return Basis(Vector3.UP, camera_yaw) * v


func _state_move(delta: float) -> Vector3:
	if _pending_guard and _can_guard_now():
		_begin_guard(Game.clock)
	if state == S.GUARD and not guard_held and Game.clock - guard_start >= Combat.GUARD_MIN_TIME:
		_start_state(S.MOVE)
		anim.set_overlay("", 0.0, 10.0)
	if _try_actions(["attack", "dodge", "jump", "heal"]):
		return Vector3.ZERO
	var wish := _wish_dir()
	var sprinting := _dodge_held_since >= 0.0 and Game.clock - _dodge_held_since > 0.3 and state == S.MOVE
	var speed := WALK_SPEED
	var use_run := false
	if state == S.GUARD:
		speed = GUARD_SPEED
	elif sprinting:
		speed = SPRINT_SPEED
		use_run = true
	elif not locked:
		speed = RUN_SPEED
		use_run = true
	var vel := wish * speed
	if locked and lock_target != null and not use_run:
		turn_toward(lock_target.global_position, 900.0, delta)
	elif wish.length() > 0.1:
		turn_toward(global_position + wish, 720.0, delta)
	elif locked and lock_target != null:
		turn_toward(lock_target.global_position, 900.0, delta)
	var local := Basis(Vector3.UP, -facing) * vel
	anim.play_locomotion(LOCO)
	anim.set_locomotion_velocity(local, WALK_SPEED, use_run)
	return vel


func _try_actions(actions: Array) -> bool:
	for a in actions:
		if not _buffered(a):
			continue
		match a:
			"attack":
				if _try_deathblow():
					_consume("attack")
					return true
				_consume("attack")
				_start_attack("p_attack_1" if state != S.ATTACK else combo_next)
				return true
			"dodge":
				_consume("dodge")
				_start_dodge()
				return true
			"jump":
				_consume("jump")
				_start_jump()
				return true
			"heal":
				_consume("heal")
				if heal_charges > 0 and hp < max_hp:
					_start_heal()
					return true
	return false


# ---------------------------------------------------------------------------- attacks
func _start_attack(clip_name: String) -> void:
	_start_state(S.ATTACK)
	anim.play(clip_name, 0.06)
	reset_hits()
	combo_next = str(anim.clip.raw.get("next", "p_attack_1"))
	if locked and lock_target != null:
		face_now(lock_target.global_position)
	elif move_input.length() > 0.2:
		face_now(global_position + _wish_dir())
	Sfx.play("swing_light", rig.joint_world("hand_r"), -2.0, 1.0 + randf_range(-0.05, 0.05))


func _state_attack(delta: float) -> Vector3:
	var c := anim.clip
	var combo: Array = c.raw.get("combo", [0.2, 0.6])
	var cancel := c.get_float("cancel", 0.3)
	if anim.time >= float(combo[0]) and _buffered("attack"):
		if _try_deathblow():
			_consume("attack")
			return Vector3.ZERO
		_consume("attack")
		_start_attack(combo_next)
		return Vector3.ZERO
	if _pending_guard and _can_guard_now():
		_begin_guard(Game.clock)
		return Vector3.ZERO
	if anim.time >= cancel and _try_actions(["dodge", "jump"]):
		return Vector3.ZERO
	var extra := Vector3.ZERO
	var lunge: Array = c.raw.get("lunge", [0.0, 0.0])
	if anim.time <= float(lunge[1]) and locked and lock_target != null:
		turn_toward(lock_target.global_position, 900.0, delta)
		var d := distance_to_opponent()
		if d > 1.55 and d < 3.6:
			var t_left := maxf(0.06, float(lunge[1]) - anim.time)
			extra = forward() * clampf((d - 1.45) / (t_left + 0.1), 0.0, 5.5)
	if anim.finished:
		_to_neutral()
	return extra


func _on_weapon_contact(info: Dictionary) -> void:
	if not (lock_target is Boss):
		return
	var boss: Boss = lock_target
	var res := boss.receive_player_attack(info, self)
	if res == Combat.RESULT_DEFLECT:
		_on_parried()


func _on_parried() -> void:
	# The boss deflected our strike: we get knocked back, open for his counter.
	add_posture(18.0, true)
	_start_state(S.REPELLED)
	anim.play("p_repelled", 0.04)
	push(-forward() * 3.0)
	Game.rumble(0.4, 0.5, 0.15)


func _try_deathblow() -> bool:
	if not (lock_target is Boss):
		return false
	var boss: Boss = lock_target
	if not boss.is_deathblow_ready():
		return false
	var d := distance_to_opponent()
	if d > 3.0:
		return false
	if Combat.angle_to(boss.global_position, boss.forward(), global_position) > 100.0 and d > 1.8:
		return false
	_start_state(S.DEATHBLOW)
	var from_boss := Combat.flat(global_position - boss.global_position)
	if from_boss.length() < 0.1:
		from_boss = boss.forward()
	var dir := from_boss.normalized()
	var want := boss.global_position + dir * 1.3
	_deathblow_shift = Combat.flat(want - global_position)
	face_now(boss.global_position)
	boss.begin_deathblow(self)
	anim.play("p_deathblow", 0.08)
	reset_hits()
	return true


# ---------------------------------------------------------------------------- dodge
func _start_dodge() -> void:
	var wish := _wish_dir()
	var to_boss := Vector3.ZERO
	if lock_target != null:
		to_boss = Combat.flat(lock_target.global_position - global_position)
	if wish.length() < 0.2:
		# Neutral step: backstep away from the target (or backwards).
		wish = -to_boss.normalized() if locked and to_boss.length() > 0.1 else -forward()
	dodge_dir = Combat.flat(wish).normalized()
	dodge_toward_boss = to_boss.length() > 0.1 and rad_to_deg(dodge_dir.angle_to(to_boss.normalized())) < 55.0
	var clip_name := "p_dodge_fwd"
	if locked and lock_target != null:
		face_now(lock_target.global_position)
		var local := Basis(Vector3.UP, -facing) * dodge_dir
		var ang := rad_to_deg(atan2(local.x, -local.z))   # 0 = forward, 90 = right
		if absf(ang) <= 45.0:
			clip_name = "p_dodge_fwd"
			_dodge_rot = deg_to_rad(-ang)
		elif absf(ang) >= 135.0:
			clip_name = "p_dodge_back"
			_dodge_rot = deg_to_rad(-(ang - signf(ang) * 180.0))
		elif ang > 0.0:
			clip_name = "p_dodge_right"
			_dodge_rot = deg_to_rad(-(ang - 90.0))
		else:
			clip_name = "p_dodge_left"
			_dodge_rot = deg_to_rad(-(ang + 90.0))
	else:
		face_now(global_position + dodge_dir)
		_dodge_rot = 0.0
	_start_state(S.DODGE)
	anim.play(clip_name, 0.05)
	var ifr: Array = anim.clip.raw.get("iframes", [0.02, 0.26])
	_iframes = Vector2(float(ifr[0]), float(ifr[1]))
	var mk: Variant = anim.clip.raw.get("mikiri", null)
	_mikiri_until = float((mk as Array)[1]) if mk != null else 0.36
	Sfx.play("dodge", global_position + Vector3.UP, -4.0)


func _state_dodge(_delta: float) -> Vector3:
	if state_time > 0.3 and _try_actions(["attack", "jump"]):
		return Vector3.ZERO
	if _pending_guard and _can_guard_now():
		_begin_guard(Game.clock)
		return Vector3.ZERO
	if anim.finished:
		_to_neutral()
	return Vector3.ZERO


## Rotates dodge root motion toward the exact input direction.
func root_motion_velocity(delta: float) -> Vector3:
	var v := super.root_motion_velocity(delta)
	if state == S.DODGE and absf(_dodge_rot) > 0.001:
		v = Basis(Vector3.UP, _dodge_rot) * v
	return v


func is_dodge_invulnerable() -> bool:
	return state == S.DODGE and state_time >= _iframes.x and state_time <= _iframes.y


# ---------------------------------------------------------------------------- jumping
func _start_jump() -> void:
	var wish := _wish_dir()
	var spd := WALK_SPEED if locked else RUN_SPEED
	_air_velocity = Combat.flat(velocity) * 0.6 + wish * spd * 0.55
	velocity.y = JUMP_VELOCITY
	_kick_used = false
	_air_attack_used = false
	_start_state(S.AIR)
	anim.play("p_jump", 0.05)
	Sfx.play("jump", global_position, -6.0)
	if locked and lock_target != null:
		face_now(lock_target.global_position)


func _state_air(delta: float) -> Vector3:
	var wish := _wish_dir()
	_air_velocity = _air_velocity.move_toward(wish * (WALK_SPEED if locked else RUN_SPEED), AIR_ACCEL * delta)
	if locked and lock_target != null and state != S.JUMP_KICK:
		turn_toward(lock_target.global_position, 500.0, delta)
	if state == S.AIR:
		if anim.is_playing("p_jump") and anim.finished:
			anim.play("p_air", 0.15)
		if _buffered("jump") and not _kick_used and _can_kick():
			_consume("jump")
			_start_kick()
		elif _buffered("attack") and not _air_attack_used:
			_consume("attack")
			_air_attack_used = true
			_start_state(S.AIR_ATTACK)
			anim.play("p_air_attack", 0.05)
			reset_hits()
			Sfx.play("swing_light", rig.joint_world("hand_r"), -2.0, 0.92)
	elif state == S.AIR_ATTACK:
		if anim.finished:
			_start_state(S.AIR)
			anim.play("p_air", 0.15)
	elif state == S.JUMP_KICK:
		if anim.finished:
			_start_state(S.AIR)
			anim.play("p_air", 0.15)
	return _air_velocity


func _can_kick() -> bool:
	if lock_target == null:
		return false
	var d := distance_to_opponent()
	var height := global_position.y - lock_target.global_position.y
	return d < 2.5 and height > 0.25


func _start_kick() -> void:
	_kick_used = true
	_kick_connected = false
	_start_state(S.JUMP_KICK)
	anim.play("p_jump_kick", 0.04)
	if lock_target != null:
		face_now(lock_target.global_position)
		# Home in on his head like Sekiro's kick: close the gap during the 0.14 s wind-up.
		var to := Combat.flat(lock_target.global_position - global_position)
		var d := to.length()
		if d > 0.01:
			_air_velocity = to / d * clampf((d - 1.15) / 0.14, 0.0, 9.0)
		velocity.y = maxf(velocity.y, 1.5)


func _process_kick() -> void:
	if state != S.JUMP_KICK or _kick_connected or lock_target == null:
		return
	if anim.time < 0.1 or anim.time > 0.24:
		return
	var foot := rig.joint_world("foot_r")
	var cap := lock_target.hurt_capsule()
	if Combat.point_vs_capsule(foot, cap[0], cap[1], float(cap[2]) + 0.28):
		_kick_connected = true
		velocity.y = 6.8
		_air_velocity = -forward() * 3.2
		if lock_target is Boss:
			(lock_target as Boss).receive_kick(self, foot)


func _after_move() -> void:
	# Never stand on the boss's head after a kick: slide off his capsule.
	for i in get_slide_collision_count():
		var col := get_slide_collision(i)
		if col.get_collider() == lock_target and col.get_normal().y > 0.4 and lock_target != null:
			var away := Combat.flat(global_position - lock_target.global_position)
			if away.length() < 0.05:
				away = -forward()
			push(away.normalized() * 5.0)
			_air_velocity = away.normalized() * 3.0
	var on_floor := is_on_floor()
	if (state == S.AIR or state == S.AIR_ATTACK or state == S.JUMP_KICK) and on_floor and velocity.y <= 0.0 \
			and state_time > 0.1:
		_start_state(S.LAND)
		anim.play("p_land", 0.05)
		Sfx.play("land", global_position, -4.0)
	elif state != S.AIR and state != S.AIR_ATTACK and state != S.JUMP_KICK and not on_floor and velocity.y < -3.0:
		# walked off something: fall
		pass
	_was_on_floor = on_floor


func is_airborne() -> bool:
	return state == S.AIR or state == S.AIR_ATTACK or state == S.JUMP_KICK


# ---------------------------------------------------------------------------- healing
func _start_heal() -> void:
	heal_charges -= 1
	heal_charges_changed.emit(heal_charges)
	_start_state(S.HEAL)
	anim.play("p_heal", 0.12)


func _on_anim_event(_clip: String, ev: Dictionary) -> void:
	match str(ev.get("type", "")):
		"heal":
			hp = minf(max_hp, hp + max_hp * Combat.HEAL_AMOUNT)
			vitals_changed.emit()
			Fx.light_pulse(get_parent(), global_position + Vector3(0, 1.2, 0), Color(1.0, 0.6, 0.3), 2.0, 3.0, 0.5)
		"sfx":
			Sfx.play(str(ev.get("name", "")), rig.joint_world("chest"), -3.0)
		"deathblow_hit":
			if lock_target is Boss:
				(lock_target as Boss).on_deathblow_stab(rig.blade_world("blade"))
		"deathblow_pull":
			if lock_target is Boss:
				(lock_target as Boss).on_deathblow_pull(rig.blade_world("blade"))


# ====================================================================== being attacked
func can_be_hit() -> bool:
	return state != S.DEAD and state != S.DEATHBLOW


func _facing_ok(from_pos: Vector3) -> bool:
	return Combat.angle_to(global_position, forward(), from_pos) <= Combat.GUARD_HALF_ANGLE


## Resolves an incoming boss hit. Returns a Combat.RESULT_* value.
func receive_attack(info: Dictionary, attacker: Combatant) -> int:
	var kind := str(info.get("kind", "normal"))
	var t: float = float(info.get("time", Game.clock))
	var pos: Vector3 = info.get("point", global_position + Vector3.UP)
	if state == S.DEAD or state == S.DEATHBLOW:
		return Combat.RESULT_IGNORED
	if state == S.MIKIRI:
		return Combat.RESULT_IGNORED
	# Mikiri counter: step into the thrust.
	if kind == "thrust" and state == S.DODGE and dodge_toward_boss and state_time <= _mikiri_until:
		_do_mikiri(info, attacker)
		return Combat.RESULT_MIKIRI
	# Invulnerability (sweeps ignore dodge i-frames: jump them).
	if Game.clock < _invuln_until:
		return Combat.RESULT_IGNORED
	if kind != "sweep" and is_dodge_invulnerable():
		return Combat.RESULT_IGNORED
	if state == S.KNOCKDOWN and _in_clip_iframes():
		return Combat.RESULT_IGNORED
	var guarding := (state == S.GUARD or state == S.DEFLECT or state == S.BLOCK) and _facing_ok(attacker.global_position)
	if guarding and kind != "sweep":
		var dt := t - guard_start
		if dt >= -Combat.DEFLECT_GRACE and dt <= guard_window:
			_do_deflect(info, attacker, dt)
			return Combat.RESULT_DEFLECT
		deflect_timed.emit(dt * 1000.0, guard_window * 1000.0, "early" if dt > guard_window else "late")
		if guard_held and kind != "thrust":
			_do_block(info, attacker, pos)
			return Combat.RESULT_BLOCK
	elif kind != "sweep" and _last_guard_press > t - 0.6:
		deflect_timed.emit((t - _last_guard_press) * 1000.0, guard_window * 1000.0, "miss")
	_do_hit(info, attacker, pos)
	return Combat.RESULT_HIT


func _in_clip_iframes() -> bool:
	if anim.clip == null:
		return false
	var ifr: Variant = anim.clip.raw.get("iframes", null)
	if ifr == null:
		return false
	var a: Array = ifr
	return anim.time >= float(a[0]) and anim.time <= float(a[1])


func _do_deflect(info: Dictionary, attacker: Combatant, dt: float) -> void:
	_last_press_deflected = true
	_spam_level = 0
	add_posture(float(info.get("posture_deflect", 6.0)), false)
	var dir := str(info.get("dir", "mid"))
	if dir == "low":
		dir = "mid"
	_start_state(S.DEFLECT)
	# Start most of the way into the snap so the hit-stop freeze frame shows the clash pose.
	anim.play("p_deflect_" + dir, 0.02, 1.0, 0.035)
	face_now(attacker.global_position)
	var pos: Vector3 = info.get("point", global_position + Vector3(0, 1.3, 0))
	var cam_dir := Vector3.UP
	if Game.camera is Node3D:
		cam_dir = ((Game.camera as Node3D).global_position - pos).normalized()
	Fx.sparks(get_parent(), pos, (cam_dir + Vector3.UP * 0.5).normalized(), Fx.SPARK_DEFLECT)
	Sfx.play("deflect", pos, 4.0, 1.0, 0.06)
	Game.hitstop(Combat.HITSTOP_DEFLECT)
	Game.shake(0.22, 0.16)
	Game.rumble(0.25, 0.55, 0.1)
	push(-forward() * 1.4)
	deflect_timed.emit(dt * 1000.0, guard_window * 1000.0, "deflect")


func _do_block(info: Dictionary, attacker: Combatant, pos: Vector3) -> void:
	var broke := add_posture(float(info.get("posture_block", 20.0)))
	face_now(attacker.global_position)
	Fx.sparks(get_parent(), pos, Vector3.UP, Fx.SPARK_BLOCK)
	Sfx.play("block", pos, 1.0, 1.0, 0.07)
	if broke:
		_guard_break()
		return
	_start_state(S.BLOCK)
	anim.play("p_block", 0.03)
	Game.hitstop(Combat.HITSTOP_BLOCK)
	Game.shake(0.12, 0.12)
	push(-forward() * 2.0)


func _guard_break() -> void:
	_start_state(S.GUARD_BREAK)
	anim.play("p_guard_break", 0.04)
	Sfx.play("guard_break", global_position + Vector3.UP * 1.2, 2.0)
	Fx.sparks(get_parent(), global_position + Vector3.UP * 1.25 + forward() * 0.3, Vector3.UP, Fx.SPARK_BREAK)
	Game.hitstop(Combat.HITSTOP_POSTURE_BREAK)
	Game.shake(0.45, 0.3)
	Game.rumble(0.6, 1.0, 0.3)
	guard_held = false


func _do_hit(info: Dictionary, attacker: Combatant, pos: Vector3) -> void:
	var kind := str(info.get("kind", "normal"))
	damage(float(info.get("dmg", 20.0)))
	add_posture(6.0)
	var away := Combat.flat(global_position - attacker.global_position).normalized()
	Fx.blood(get_parent(), pos, away + Vector3.UP * 0.2, 36)
	Sfx.play("hit", pos, 2.0, 1.0, 0.08)
	Game.hitstop(Combat.HITSTOP_HIT)
	Game.shake(0.4, 0.25)
	Game.rumble(0.7, 0.8, 0.2)
	if Game.hud != null and Game.hud.has_method("flash_damage"):
		Game.hud.call("flash_damage")
	face_now(attacker.global_position)
	guard_held = Input.is_action_pressed("guard")
	if hp <= 0.0:
		_die()
		return
	if kind == "thrust" or kind == "sweep" or bool(info.get("final", false)) and float(info.get("dmg", 0.0)) >= 34.0:
		_start_state(S.KNOCKDOWN)
		anim.play("p_knockdown", 0.05)
		_invuln_until = Game.clock + 0.2
	else:
		_start_state(S.HIT)
		anim.play("p_hit", 0.04)
	velocity.y = minf(velocity.y, 0.0)


func _do_mikiri(info: Dictionary, attacker: Combatant) -> void:
	_start_state(S.MIKIRI)
	anim.play("p_mikiri", 0.03)
	face_now(attacker.global_position)
	_invuln_until = Game.clock + 0.6
	var pos: Vector3 = info.get("point", global_position + Vector3(0, 0.6, 0))
	Fx.sparks(get_parent(), pos, Vector3.UP, Fx.SPARK_MIKIRI)
	Fx.dust(get_parent(), Vector3(pos.x, global_position.y, pos.z), 22, 0.9)
	Sfx.play("mikiri", pos, 5.0)
	Game.hitstop(Combat.HITSTOP_MIKIRI)
	Game.slowmo(0.4, 0.35)
	Game.shake(0.45, 0.3)
	Game.rumble(0.5, 0.9, 0.25)
	if Game.hud != null and Game.hud.has_method("show_callout"):
		Game.hud.call("show_callout", "MIKIRI COUNTER")


func _die() -> void:
	_start_state(S.DEAD)
	anim.play("p_death", 0.08)
	controls_enabled = false
	Sfx.play_ui("death", 0.0)
	Game.slowmo(1.2, 0.35)
	var tree := get_tree()
	if tree:
		tree.create_timer(1.6, false).timeout.connect(func(): died.emit())


# ====================================================================== misc
func _update_posture(delta: float) -> void:
	if state == S.GUARD_BREAK or state == S.DEAD:
		return
	var mult := Combat.PLAYER_POSTURE_REGEN_GUARD if state == S.GUARD else 1.0
	# Lower vitality -> slower posture recovery (as in Sekiro).
	mult *= 0.45 + 0.55 * (hp / max_hp)
	tick_posture(delta, mult)


func _footsteps() -> void:
	if state != S.MOVE and state != S.GUARD:
		return
	if not anim.loco_active or anim.loco_cycle_rate <= 0.01:
		return
	var ph := fposmod(anim.loco_phase, 1.0)
	var crossed := (_last_step_phase < 0.5 and ph >= 0.5) or (ph < _last_step_phase)
	_last_step_phase = ph
	if crossed:
		Sfx.play("step", global_position, -14.0, 1.0, 0.1)


func reset_for_fight() -> void:
	hp = max_hp
	posture = 0.0
	heal_charges = Combat.HEAL_CHARGES
	heal_charges_changed.emit(heal_charges)
	controls_enabled = true
	_start_state(S.MOVE)
	anim.play_locomotion(LOCO, 0.1)
	vitals_changed.emit()
