class_name Inferno
extends Node3D
## Sojin's fire move (phase 2 on; he opens phase 2 with it). The boss hands control over
## (Boss.S.INFERNO) and gets it back when the fire is spent (b_fire_spent, his punish window).
##
##  1. The tell: he leaps to the middle of the arena and drives the staff into the stones
##     (b_fire_leap). Nothing else he does takes him there.
##  2. He channels, both hands on the planted staff; fire climbs it and the floor glows out to
##     the blast radius, brightest at its edge. He wrenches the staff free: the fire blast.
##     It can't be guarded, dodged through or jumped - being outside the glow is the only way
##     to avoid it; inside, it knocks you down and throws you out (b_fire_ignite).
##  3. He lifts the staff overhead, both ends ablaze (危), drops into a low wide stance with it
##     level across his hips, and fire runs from both blades out past the walls.
##  4. He turns (b_fire_spin, driven from here). Each arm of fire sweeps the whole arena at
##     ankle-to-knee height: a sweep, so guarding and dodge i-frames don't help - jump it.
##     Three passes on an even beat (GAP), then the fire flares and the fourth comes round
##     faster (GAP_FAST), to catch anyone jumping on the beat instead of watching the fire.
##     The beat is kept wherever you stand (the turn is steered by where you are); after the
##     fire knocks you down, the next pass waits until you're up with time to jump it. A ring
##     of fire round him keeps you out, and his burning body turns your sword.
##  5. The fire dies down and he's spent: hit him (Boss._inferno_spent -> b_fire_spent).

enum St { IDLE, LEAP, IGNITE, SPIN, WIND_DOWN }

const REACH := 16.6                ## the arms reach this far from him (the wall is 15.4 m from the middle)
const ARM_FROM := 1.9              ## ...starting this far out (inside the ring anyway)
const FIRE_TOP := 0.55             ## the arms burn this high: your feet have to be above it
const FIRE_TOP_FAST := 0.68        ## ...the flared fourth pass burns a little higher
const ARM_HALF_WIDTH := 0.22
const RING_R := 3.1                ## ring of fire round him while he turns
const BLAST_R := 6.2
const BLAST_TIME := 0.32
const CHARGE_TIME := 1.58          ## fire_charge -> fire_blast in b_fire_ignite
const GAP := 1.5                   ## seconds between the first three passes...
const GAP_FAST := 1.0              ## ...and before the fourth: 0.5 s early catches anyone jumping on the beat
const OMEGA := 180.0 / GAP         ## deg/s at full speed (two arms: one reaches you every half turn)
const FIRST := GAP                 ## start of the turn -> first pass (spinning up from standstill)
const RAMP_FAST := 0.3             ## the flare: speeding up to the fourth pass's pace
const WIND_DOWN := 0.9
const FAIR := 2.0                  ## after the fire knocks you down, the next pass waits this long
const PASSES := 4
const DMG_ARM := 25.0
const DMG_BLAST := 18.0
const DMG_RING := 6.0
const WALL_H := 1.0                ## height of the arms' flame quads (the fire itself is lower)
const ARM_OFFSET := 0.3            ## the staff is this far in front of him: the arms run along it

var boss: Boss
var player: Player
var stage: int = St.IDLE
var center := Vector3.ZERO         ## where he stands: the middle of the arena
var passes := 0                    ## arms that have gone past you this turn
var hits := 0                      ## ...and how many of them burned you
var pass_times: Array = []         ## Game.clock of each pass
var fire_top := FIRE_TOP
var blast_hit := false

var _tau := 0.0                    ## time along the planned turn (slowed after you're knocked down)
var _omega := 0.0                  ## deg/s he's turning (clockwise from above)
var _omega_fast := 0.0
var _lead_prev := 90.0
var _contact := false
var _contact_hit := false
var _fair_until := -1.0
var _burned_at := -99.0
var _ring_burn_at := -1.0
var _wind_t := 0.0
var _wind_from := 0.0
var _blast_t := -1.0
var _whoosh_armed := true

# visuals
var _arms: Array = []              ## per arm: {pivot, wall, strip, flames, lights}
var _arm_len := 0.0
var _arm_target := 0.0
var _heat := 1.0
var _heat_target := 1.0
var _ring: Node3D
var _ring_mat: ShaderMaterial
var _ring_flames: CPUParticles3D
var _ring_glow: MeshInstance3D
var _ring_level := 0.0
var _ring_target := 0.0
var _charge_t := -1.0
var _charge_glow: MeshInstance3D
var _vortex: CPUParticles3D
var _heat_light: OmniLight3D
var _blast_band: MeshInstance3D
var _blast_mat: ShaderMaterial
var _blast_vis := -1.0
var _roar: AudioStreamPlayer3D
var _roar_level := 0.0


func setup(b: Boss) -> void:
	boss = b
	top_level = true
	_omega_fast = (180.0 - OMEGA * RAMP_FAST * 0.5) / (GAP_FAST - RAMP_FAST * 0.5)
	_build_visuals()


func is_active() -> bool:
	return stage != St.IDLE


func stage_name() -> String:
	return ["idle", "leap", "ignite", "spin", "wind down"][stage]


# ============================================================================== flow
## Starts the move (the boss has switched to S.INFERNO).
func begin() -> void:
	player = boss.opponent as Player
	stage = St.LEAP
	passes = 0
	hits = 0
	pass_times.clear()
	blast_hit = false
	center = Vector3(0.0, boss.global_position.y, 0.0)
	fire_top = FIRE_TOP
	_heat_target = 1.0
	_tau = 0.0
	_omega = 0.0
	_fair_until = -1.0
	_burned_at = -99.0
	_blast_t = -1.0
	_charge_t = -1.0
	_arm_target = 0.0
	_ring_target = 0.0
	_contact = false
	# He leaps over or onto you: the two of you mustn't collide until the fire is out.
	if player != null:
		boss.add_collision_exception_with(player)
		player.add_collision_exception_with(boss)
	boss.anim.play("b_fire_leap", 0.14)
	boss.reset_hits()
	boss.staff_fire.set_level(maxf(boss.staff_fire.level("upper"), 0.12), 1.0)


## Called every physics tick while the boss is in S.INFERNO. Returns his planar velocity.
func update(delta: float) -> Vector3:
	var planar := Vector3.ZERO
	match stage:
		St.LEAP:
			planar = _leap(delta)
		St.IGNITE:
			_track(delta)
			if boss.anim.finished:
				_begin_spin()
		St.SPIN:
			_spin(delta)
			_ring_check(delta)
		St.WIND_DOWN:
			_wind_down(delta)
			_ring_check(delta)
	_tick_blast(delta)
	return planar


## Animation events from the fire clips (Boss._on_anim_event).
func on_event(type: String, _ev: Dictionary) -> void:
	match type:
		"fire_plant":
			var pts := boss.rig.blade_world("lower")
			var tip := pts[pts.size() - 1] if pts.size() > 0 else boss.global_position
			var ground := Vector3(tip.x, center.y, tip.z)
			Fx.dust(boss.get_parent(), ground, 26, 1.0)
			Fx.sparks(boss.get_parent(), ground + Vector3(0, 0.05, 0), Vector3.UP, Fx.SPARK_GROUND)
			FireFx.burst(boss.get_parent(), ground + Vector3(0, 0.15, 0), 0.8)
			Sfx.play("ground_impact", ground, 3.0)
			Game.shake(0.3, 0.25)
			boss.staff_fire.set_level(0.55, 3.0, "lower")
		"fire_charge":
			_charge_t = 0.0
			Sfx.play("fire_charge", center + Vector3(0, 1.0, 0), 2.0, 1.0, 0.0)
		"fire_blast":
			_blast()
		"fire_whips":
			_arm_target = 1.0
			_ring_target = 1.0
			Sfx.play("fire_ignite", center + Vector3(0, 1.0, 0), 3.0)
			_roar_start()


func _leap(delta: float) -> Vector3:
	_track(delta)
	var planar := Vector3.ZERO
	var c := boss.anim.clip
	var t := boss.anim.time
	var w: Array = c.raw.get("travel", [0.3, 0.98]) if c != null else [0.3, 0.98]
	if t >= float(w[0]) and t < float(w[1]):
		var to := Combat.flat(center - boss.global_position)
		planar = to / maxf(float(w[1]) - t, delta)
	if boss.anim.finished:
		stage = St.IGNITE
		boss.anim.play("b_fire_ignite", 0.06)
	return planar


## The clip's "track" windows: he keeps turning to face you.
func _track(delta: float) -> void:
	var c := boss.anim.clip
	if c == null or player == null:
		return
	var t := boss.anim.time
	for tr in c.raw.get("track", []):
		var ta: Array = tr
		if t >= float(ta[0]) and t <= float(ta[1]):
			boss.turn_toward(player.global_position, float(ta[2]), delta)


func _blast() -> void:
	_charge_t = -1.0
	_blast_t = 0.0
	_blast_vis = 0.0
	blast_hit = false
	boss.staff_fire.climb = -1.0
	boss.staff_fire.set_level(1.0, 8.0)
	var p := boss.get_parent()
	Sfx.play("fire_blast", center + Vector3(0, 1.0, 0), 5.0, 1.0, 0.0)
	Game.shake(0.6, 0.5)
	Game.rumble(0.6, 0.9, 0.35)
	Fx.light_pulse(p, center + Vector3(0, 1.4, 0), Color(1.0, 0.5, 0.15), 6.0, 16.0, 0.7)
	Fx.dust(p, center, 40, 2.5)
	var burst := FireFx.flames(110, 0.55, 0.9)
	burst.one_shot = true
	burst.explosiveness = 0.95
	burst.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	burst.emission_ring_axis = Vector3.UP
	burst.emission_ring_radius = 0.8
	burst.emission_ring_inner_radius = 0.2
	burst.emission_ring_height = 0.3
	burst.direction = Vector3(1, 0, 0)
	burst.spread = 180.0
	burst.flatness = 0.85
	burst.initial_velocity_min = 11.0
	burst.initial_velocity_max = 19.0
	burst.damping_min = 12.0
	burst.damping_max = 20.0
	burst.gravity = Vector3(0, 3.0, 0)
	Fx._emit_at(p, burst, center + Vector3(0, 0.35, 0))
	Fx._free_later(burst, 1.2)


func _tick_blast(delta: float) -> void:
	if _blast_t < 0.0:
		return
	_blast_t += delta
	var r := blast_radius()
	if not blast_hit and player != null:
		var to := Combat.flat(player.global_position - center)
		if to.length() - player.hurt_radius <= r:
			blast_hit = true
			var away := to.normalized() if to.length() > 0.05 else -boss.forward()
			var need := maxf(0.0, BLAST_R + 1.2 - to.length())
			var info := {"kind": "blast", "element": "fire", "dmg": DMG_BLAST, "posture_block": 0, "posture_deflect": 0,
				"boss_posture": 0, "dir": "mid", "final": true, "clip": "inferno", "index": -1,
				"knockback": away * minf(sqrt(2.0 * 14.0 * need), 14.0),
				"point": player.global_position + Vector3(0, 0.9, 0) - away * 0.2, "time": Game.clock}
			player.receive_attack(info, boss)
	if _blast_t >= BLAST_TIME:
		_blast_t = -1.0


func _begin_spin() -> void:
	stage = St.SPIN
	_tau = 0.0
	_omega = 0.0
	_lead_prev = _lead_deg()
	_contact = false
	_whoosh_armed = true
	boss.anim.play("b_fire_spin", 0.12)


## The planned turn, in time along it (`_tau`): spinning up from standstill so the first arm
## reaches you FIRST seconds in, then OMEGA (a pass every GAP), then after the third pass it
## speeds up so the fourth arrives GAP_FAST later.
func _omega_at(tau: float) -> float:
	var t3 := FIRST + 2.0 * GAP
	if tau < FIRST:
		return OMEGA * tau / FIRST
	if tau < t3:
		return OMEGA
	var u := tau - t3
	if u < RAMP_FAST:
		return lerpf(OMEGA, _omega_fast, u / RAMP_FAST)
	return _omega_fast


## Degrees turned by `tau` (the integral of _omega_at): an arm reaches you at 90, 270, 450, 630.
func _sigma_at(tau: float) -> float:
	var t3 := FIRST + 2.0 * GAP
	if tau < FIRST:
		return OMEGA * tau * tau / (2.0 * FIRST)
	if tau < t3:
		return 90.0 + OMEGA * (tau - FIRST)
	var u := tau - t3
	var s := 90.0 + OMEGA * 2.0 * GAP
	if u < RAMP_FAST:
		return s + OMEGA * u + (_omega_fast - OMEGA) * u * u / (2.0 * RAMP_FAST)
	return s + (OMEGA + _omega_fast) * RAMP_FAST * 0.5 + _omega_fast * (u - RAMP_FAST)


func _tau_pass(k: int) -> float:
	match k:
		1:
			return FIRST
		2:
			return FIRST + GAP
		3:
			return FIRST + 2.0 * GAP
	return FIRST + 2.0 * GAP + GAP_FAST


func _spin(delta: float) -> void:
	# Knocked down by the fire: the next pass waits until you're up (the turn slows). While
	# an arm is on you it hasn't passed yet, but the one to wait for is the one after it.
	var rho := 1.0
	var upcoming := passes + (2 if _contact else 1)
	if Game.clock < _fair_until and upcoming <= PASSES:
		var left_tau := _tau_pass(upcoming) - _tau
		var left_real := _fair_until - Game.clock
		if left_tau > 0.0 and left_tau < left_real:
			rho = left_tau / left_real
	_tau = minf(_tau + delta * rho, _tau_pass(PASSES))
	var w := _omega_at(_tau) * rho
	# Keep the beat wherever you are: steer the turn by how far the next arm is from you
	# compared with the plan (he can't turn backwards, so only slow down so far).
	var err := _lead_deg() - (90.0 + 180.0 * passes - _sigma_at(_tau))
	var corr := clampf(err * 2.5, -0.85 * w, 60.0)
	_turn(w + corr, delta)
	_arm_hits()


func _turn(deg_per_s: float, delta: float) -> void:
	_omega = maxf(deg_per_s, 0.0)
	boss.set_facing(boss.facing - deg_to_rad(_omega * delta))
	var authored := 100.0
	if boss.anim.clip != null:
		authored = boss.anim.clip.get_float("omega", 100.0)
	boss.anim.speed = _omega / authored


## How far (degrees, clockwise) the next arm has to turn to reach you.
func _lead_deg() -> float:
	if player == null:
		return 90.0
	var to := Combat.flat(player.global_position - center)
	if to.length() < 0.05:
		return 90.0
	var theta := boss.facing - PI * 0.5      # the arm from the upper blade, on his right
	return fposmod(rad_to_deg(theta - Combat.yaw_of(to)), 180.0)


func _arm_hits() -> void:
	if player == null:
		return
	var lead := _lead_deg()
	var wrapped := _lead_prev < 60.0 and lead > 120.0      # an arm went past you this tick
	var to := Combat.flat(player.global_position - center)
	var r := to.length()
	var half := rad_to_deg(atan2(player.hurt_radius + ARM_HALF_WIDTH, maxf(r, 0.5)))
	var near := minf(lead, 180.0 - lead) < half or wrapped
	if near and not _contact:
		_contact = true
		_contact_hit = false
	elif not near:
		_contact = false
	# (one burn per arm: none again until you've had time to get up)
	if _contact and not _contact_hit and r >= ARM_FROM - 0.3 and r <= REACH and player.can_be_hit() \
			and Game.clock - _burned_at > 1.0:
		var feet := player.global_position.y - center.y
		if feet < fire_top + 0.01:
			_contact_hit = true
			var info := {"kind": "sweep", "element": "fire", "dmg": DMG_ARM, "posture_block": 0, "posture_deflect": 0,
				"boss_posture": 0, "dir": "low", "final": true, "clip": "inferno", "index": passes,
				"point": player.global_position + Vector3(0, 0.35, 0), "time": Game.clock}
			if player.receive_attack(info, boss) == Combat.RESULT_HIT:
				hits += 1
				_burned_at = Game.clock
				_fair_until = Game.clock + FAIR
	# the whoosh peaks as the arm reaches you
	if _whoosh_armed and _omega > 1.0 and lead / _omega < 0.3 and lead < 90.0:
		_whoosh_armed = false
		Sfx.play("fire_whoosh", player.global_position + Vector3(0, 0.5, 0), 3.0, 1.0 + 0.1 * float(passes >= 3), 0.05)
	if wrapped:
		passes += 1
		pass_times.append(Game.clock)
		_whoosh_armed = true
		if passes == PASSES - 1:
			_flare()
		elif passes >= PASSES:
			stage = St.WIND_DOWN
			_wind_t = 0.0
			_wind_from = _omega
			_arm_target = 0.0
			_heat_target = 0.0
			Sfx.play("fire_gutter", center + Vector3(0, 1.0, 0), 2.0)
	_lead_prev = lead


## The third arm has gone by: the fire flares and the last one comes round faster.
func _flare() -> void:
	fire_top = FIRE_TOP_FAST
	_heat_target = 1.6
	Sfx.play("fire_flare", center + Vector3(0, 1.2, 0), 4.0)
	Fx.light_pulse(boss.get_parent(), center + Vector3(0, 1.5, 0), Color(1.0, 0.45, 0.1), 5.0, 12.0, 0.5)


func _wind_down(delta: float) -> void:
	_wind_t += delta
	var u := clampf(_wind_t / WIND_DOWN, 0.0, 1.0)
	_turn(_wind_from * (1.0 - smoothstep(0.0, 1.0, u)), delta)
	if u >= 1.0:
		_finish()


## The ring round him: walking into it burns and throws you back out.
func _ring_check(delta: float) -> void:
	if player == null or _ring_level < 0.3:
		return
	var to := Combat.flat(player.global_position - center)
	var r := to.length()
	var pen := RING_R + player.hurt_radius - r
	if pen <= 0.0:
		return
	var away := to / r if r > 0.05 else -boss.forward()
	player.push(away * (55.0 + 40.0 * pen) * delta)
	if Game.clock >= _ring_burn_at:
		_ring_burn_at = Game.clock + 0.6
		player.burn(DMG_RING, player.global_position + Vector3(0, 0.6, 0) - away * 0.25)


func _finish() -> void:
	stage = St.IDLE
	_end_common()
	boss.staff_fire.set_level(StaffFire.SMOULDER, 0.5)
	boss.inferno_spent()


## Stops the move where it is (the player died): the fire goes out.
func abort() -> void:
	if stage == St.IDLE:
		return
	stage = St.IDLE
	_charge_t = -1.0
	_blast_t = -1.0
	boss.staff_fire.climb = -1.0
	_end_common()
	boss.staff_fire.set_level(StaffFire.SMOULDER, 1.0)


func _end_common() -> void:
	_arm_target = 0.0
	_ring_target = 0.0
	_heat_target = 0.0
	boss.anim.speed = 1.0
	if player != null:
		boss.remove_collision_exception_with(player)
		player.remove_collision_exception_with(boss)
		# never leave you standing inside him
		var to := Combat.flat(player.global_position - boss.global_position)
		if to.length() < 1.0:
			player.push((to.normalized() if to.length() > 0.05 else -boss.forward()) * 6.0)


# ============================================================================== queries
func arms_live() -> bool:
	return stage == St.SPIN


func ring_live() -> bool:
	return (stage == St.SPIN or stage == St.WIND_DOWN) and _ring_level >= 0.3


## World yaw of each arm (Combat.dir_of convention); the first is the upper blade's.
func arm_yaws() -> Array:
	return [boss.facing - PI * 0.5, boss.facing + PI * 0.5]


func blast_radius() -> float:
	if _blast_t < 0.0:
		return -1.0
	var u := clampf(_blast_t / BLAST_TIME, 0.0, 1.0)
	return BLAST_R * (1.0 - (1.0 - u) * (1.0 - u))


func charging() -> bool:
	return _charge_t >= 0.0


## Seconds until the next arm reaches you at the current turn rate (INF if he isn't turning).
func next_pass_in() -> float:
	if stage != St.SPIN or _omega < 1.0:
		return INF
	return _lead_deg() / _omega


# ============================================================================== visuals
func _build_visuals() -> void:
	for i in 2:
		var pivot := Node3D.new()
		add_child(pivot)
		var wall := MeshInstance3D.new()
		wall.mesh = FireFx.wall_mesh(ARM_FROM - 0.35, REACH, WALL_H)
		wall.material_override = FireFx.wall_material(REACH - ARM_FROM)
		wall.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		wall.extra_cull_margin = 4.0
		pivot.add_child(wall)
		var strip := MeshInstance3D.new()
		strip.mesh = FireFx.strip_mesh(ARM_FROM - 0.35, REACH, 0.9)
		strip.material_override = FireFx.strip_material(REACH - ARM_FROM)
		strip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		pivot.add_child(strip)
		var fl := FireFx.flames(120, 0.3, 0.7)
		fl.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
		fl.emitting = false
		fl.gravity = Vector3(0, 3.0, 0)
		fl.initial_velocity_min = 0.8
		fl.initial_velocity_max = 2.0
		pivot.add_child(fl)
		var lights: Array = []
		for x in [5.0, 11.0]:
			var l := OmniLight3D.new()
			l.light_color = Color(1.0, 0.5, 0.16)
			l.light_energy = 0.0
			l.omni_range = 6.5
			l.omni_attenuation = 1.2
			l.shadow_enabled = false
			l.position = Vector3(x, 0.7, 0)
			pivot.add_child(l)
			lights.append(l)
		pivot.visible = false
		_arms.append({"pivot": pivot, "wall": wall, "strip": strip, "flames": fl, "lights": lights})

	_ring = Node3D.new()
	add_child(_ring)
	var band := MeshInstance3D.new()
	band.mesh = FireFx.band_mesh(1.1, 72)
	band.scale = Vector3(RING_R, 1.0, RING_R)
	_ring_mat = FireFx.wall_material(TAU * RING_R, true)
	band.material_override = _ring_mat
	band.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.add_child(band)
	_ring_flames = FireFx.flames(110, 0.45, 0.7)
	_ring_flames.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	_ring_flames.emission_ring_axis = Vector3.UP
	_ring_flames.emission_ring_radius = RING_R
	_ring_flames.emission_ring_inner_radius = RING_R - 0.12
	_ring_flames.emission_ring_height = 0.05
	_ring_flames.emitting = false
	_ring.add_child(_ring_flames)
	_ring_glow = FireFx.floor_quad((RING_R + 1.2) * 2.0)
	_ring_glow.material_override = FireFx.glow_material("fire_ring",
		[Color(1.0, 0.3, 0.05, 0.0), Color(1.0, 0.3, 0.05, 0.05), Color(1.0, 0.45, 0.1, 0.35), Color(1.0, 0.3, 0.05, 0.0)],
		[0.0, 0.55, RING_R / (RING_R + 1.2), 1.0])
	_ring.add_child(_ring_glow)
	var ring_light := OmniLight3D.new()
	ring_light.light_color = Color(1.0, 0.5, 0.16)
	ring_light.omni_range = 7.0
	ring_light.light_energy = 0.0
	ring_light.shadow_enabled = false
	ring_light.position = Vector3(0, 1.0, 0)
	ring_light.name = "RingLight"
	_ring.add_child(ring_light)
	_ring.visible = false

	# the charge: the floor glows out to the blast radius (brightest at its edge), embers
	# swirl in, and heat builds at the staff
	_charge_glow = FireFx.floor_quad(BLAST_R * 2.0 / 0.94)
	_charge_glow.material_override = FireFx.glow_material("fire_charge",
		[Color(1.0, 0.4, 0.08, 0.35), Color(1.0, 0.3, 0.05, 0.12), Color(1.0, 0.32, 0.05, 0.14),
			Color(1.0, 0.6, 0.2, 0.95), Color(1.0, 0.3, 0.05, 0.0)],
		[0.0, 0.3, 0.84, 0.94, 1.0])
	_charge_glow.visible = false
	add_child(_charge_glow)
	_vortex = FireFx.embers(170, 1.1)
	_vortex.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	_vortex.emission_ring_axis = Vector3.UP
	_vortex.emission_ring_radius = BLAST_R
	_vortex.emission_ring_inner_radius = BLAST_R * 0.6
	_vortex.emission_ring_height = 0.1
	_vortex.gravity = Vector3(0, 0.9, 0)
	_vortex.initial_velocity_min = 0.2
	_vortex.initial_velocity_max = 0.6
	_vortex.radial_accel_min = -9.0
	_vortex.radial_accel_max = -6.0
	_vortex.tangential_accel_min = 5.0
	_vortex.tangential_accel_max = 8.0
	_vortex.local_coords = true
	_vortex.emitting = false
	add_child(_vortex)
	_heat_light = OmniLight3D.new()
	_heat_light.light_color = Color(1.0, 0.45, 0.12)
	_heat_light.omni_range = 9.0
	_heat_light.light_energy = 0.0
	_heat_light.shadow_enabled = false
	add_child(_heat_light)

	_blast_band = MeshInstance3D.new()
	_blast_band.mesh = FireFx.band_mesh(1.0, 72)
	_blast_mat = FireFx.wall_material(TAU * BLAST_R, true)
	_blast_band.material_override = _blast_mat
	_blast_band.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_blast_band.visible = false
	add_child(_blast_band)

	_roar = AudioStreamPlayer3D.new()
	_roar.bus = "SFX"
	_roar.unit_size = 7.0
	_roar.max_db = 4.0
	add_child(_roar)
	var path := "res://audio/fire_roar.wav"
	if ResourceLoader.exists(path):
		var st := (load(path) as AudioStreamWAV).duplicate() as AudioStreamWAV
		if st != null:
			st.loop_mode = AudioStreamWAV.LOOP_FORWARD
			st.loop_begin = 0
			st.loop_end = int(st.get_length() * st.mix_rate)
			_roar.stream = st


func _roar_start() -> void:
	if _roar.stream != null and not _roar.playing:
		_roar.volume_db = -30.0
		_roar.play()


func _process(delta: float) -> void:
	if boss == null:
		return
	var real_dt := minf(delta / maxf(Engine.time_scale, 0.001), 0.1)
	_update_charge(delta)
	_update_blast(real_dt)
	_update_ring(delta)
	_update_arms(delta)
	_update_roar(delta)


func _update_charge(delta: float) -> void:
	var on := _charge_t >= 0.0
	if on:
		_charge_t += delta
		boss.staff_fire.climb = clampf(_charge_t / (CHARGE_TIME * 0.8), 0.0, 1.0)
		if boss.staff_fire.climb >= 1.0 and boss.staff_fire.level("upper") < 0.5:
			boss.staff_fire.set_level(0.8, 4.0)
	_charge_glow.visible = on
	_vortex.emitting = on
	var u := clampf(_charge_t / CHARGE_TIME, 0.0, 1.0) if on else 0.0
	_heat_light.light_energy = move_toward(_heat_light.light_energy, 3.5 * u if on else 0.0, delta * 20.0)
	_heat_light.global_position = center + Vector3(0, 1.2, 0)
	if on:
		_charge_glow.global_position = center + Vector3(0, 0.03, 0)
		_vortex.global_position = center
		var pulse := 0.75 + 0.25 * sin(_charge_t * (8.0 + 10.0 * u))
		(_charge_glow.material_override as StandardMaterial3D).albedo_color = Color(1.6, 1.3, 1.1, clampf(u * 2.5, 0.0, 1.0) * pulse)


func _update_blast(real_dt: float) -> void:
	if _blast_vis < 0.0:
		_blast_band.visible = false
		return
	_blast_vis += real_dt
	var u := clampf(_blast_vis / (BLAST_TIME * 1.8), 0.0, 1.0)
	var grow := 1.0 - pow(1.0 - clampf(_blast_vis / BLAST_TIME, 0.0, 1.0), 2.0)
	var r := maxf(0.4, BLAST_R * grow)
	_blast_band.visible = true
	_blast_band.global_position = center
	_blast_band.scale = Vector3(r, 1.9 - 1.2 * grow, r)
	_blast_mat.set_shader_parameter("scale_x", TAU * r)
	_blast_mat.set_shader_parameter("heat", 1.3)
	_blast_mat.set_shader_parameter("alpha_mult", 1.0 - u * u)
	if u >= 1.0:
		_blast_vis = -1.0


func _update_ring(delta: float) -> void:
	_ring_level = move_toward(_ring_level, _ring_target, delta * (2.5 if _ring_target > _ring_level else 1.2))
	var on := _ring_level > 0.01
	_ring.visible = on
	_ring_flames.emitting = _ring_level > 0.3
	if not on:
		return
	_ring.global_position = center
	_ring_mat.set_shader_parameter("alpha_mult", _ring_level)
	_ring_mat.set_shader_parameter("height", 0.55 + 0.45 * _ring_level)
	_ring_mat.set_shader_parameter("heat", 0.72 + 0.25 * _heat)
	(_ring_glow.material_override as StandardMaterial3D).albedo_color = Color(1.1, 0.95, 0.85, _ring_level)
	(_ring.get_node("RingLight") as OmniLight3D).light_energy = 2.0 * _ring_level


func _update_arms(delta: float) -> void:
	_arm_len = move_toward(_arm_len, _arm_target, delta * (3.0 if _arm_target > _arm_len else 2.2))
	_heat = move_toward(_heat, _heat_target, delta * (4.0 if _heat_target > _heat else 1.5))
	var yaws := arm_yaws()
	var fwd := boss.forward()
	for i in _arms.size():
		var a: Dictionary = _arms[i]
		var pivot: Node3D = a["pivot"]
		var on := _arm_len > 0.01
		pivot.visible = on
		(a["flames"] as CPUParticles3D).emitting = _arm_len > 0.15
		if not on:
			continue
		pivot.global_position = center + fwd * ARM_OFFSET
		pivot.rotation = Vector3(0, float(yaws[i]) + PI * 0.5, 0)
		var heat := clampf(_heat, 0.0, 2.0)
		var wall: ShaderMaterial = (a["wall"] as MeshInstance3D).material_override
		wall.set_shader_parameter("reveal", _arm_len)
		wall.set_shader_parameter("heat", 0.35 + 0.65 * heat)
		wall.set_shader_parameter("height", 0.6 + 0.1 * minf(heat, 1.0) + 0.25 * maxf(0.0, heat - 1.0))
		wall.set_shader_parameter("alpha_mult", clampf(heat * 1.4, 0.0, 1.0))
		var strip: ShaderMaterial = (a["strip"] as MeshInstance3D).material_override
		strip.set_shader_parameter("reveal", _arm_len)
		strip.set_shader_parameter("heat", 0.4 + 0.6 * heat)
		strip.set_shader_parameter("alpha_mult", clampf(heat * 1.4, 0.0, 1.0))
		var fl: CPUParticles3D = a["flames"]
		var run := (REACH - ARM_FROM) * _arm_len
		fl.position = Vector3(ARM_FROM + run * 0.5, 0.12, 0)
		fl.emission_box_extents = Vector3(maxf(0.1, run * 0.5), 0.05, 0.14)
		fl.color = Color(1, 1, 1, clampf(heat, 0.0, 1.0))
		for l in a["lights"]:
			var light: OmniLight3D = l
			light.light_energy = 1.4 * minf(heat, 1.3) * clampf((_arm_len * REACH - light.position.x) / 2.0, 0.0, 1.0)


func _update_roar(delta: float) -> void:
	var want := 0.0
	if stage == St.SPIN or stage == St.WIND_DOWN:
		want = clampf(_arm_len * _heat, 0.0, 1.3)
	_roar_level = move_toward(_roar_level, want, delta * 1.5)
	if not _roar.playing:
		return
	if _roar_level <= 0.01 and want <= 0.0:
		_roar.stop()
		return
	_roar.volume_db = linear_to_db(maxf(_roar_level, 0.001)) - 2.0
	# the roar comes from the arm heading for you, at your distance: it closes in as it comes
	if player != null:
		var to := Combat.flat(player.global_position - center)
		var r := maxf(to.length(), 1.0)
		var yaw := Combat.yaw_of(to) + deg_to_rad(_lead_deg())
		_roar.global_position = center + Combat.dir_of(yaw) * r + Vector3(0, 0.5, 0)
