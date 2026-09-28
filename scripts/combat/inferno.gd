class_name Inferno
extends Node3D
## The Twin Fang's fire move (phase 2 on; he opens phase 2 with it). The boss hands control over
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
##     Phase 3: the ring round him also throws off waves of fire that roll out to the wall, so
##     the fire comes at you head on as well: one on each half-beat between the first three
##     passes (arm, wave, arm, wave, arm, then the fast fourth). A wave is steered like the turn,
##     reaching you on its half-beat wherever you stand, and the turn is a little slower
##     (GAP_WAVES) so there's always time to land and jump again. Burned, the waves still coming
##     at you die down, and no new one comes until you're up.
##  5. The finisher (b_fire_plunge, 危): the arms die away, he stands tall with the staff upright
##     over his head, holds it, and drives it down into the stones. Cracks of fire race out
##     across the floor and the whole arena erupts, rolling out from his staff: one jump, timed
##     to the eruption, clears it. In the air you're safe; on the ground while the flames are up
##     where you stand (ERUPT_DANGER) you burn, so jump too early and you land in it, too late
##     and you're still on the ground. After a burn from the last arm it waits until you're up,
##     like the arms do.
##  6. The fire dies down and he's spent: hit him (Boss.inferno_spent -> b_fire_spent).

enum St { IDLE, LEAP, IGNITE, SPIN, WIND_DOWN, PLUNGE }

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
const GAP_WAVES := 1.8             ## ...in phase 3, with a wave between them (a jump and landing take ~0.77 s)
const RAMP_FAST := 0.3             ## the flare: speeding up to the fourth pass's pace
const WIND_DOWN := 0.55            ## after the last pass: the turn stops and the arms die away
const FAIR := 2.0                  ## after the fire knocks you down, the next thing to jump waits this long
const ERUPT_WAVE := 90.0           ## m/s: the eruption rolls out from his staff (the flames too)
const ERUPT_GRACE := 0.06          ## where you stand, the flames take this long to leap up...
const ERUPT_DANGER := 0.24         ## ...then burn anyone on the ground this long: be in the air
const ERUPT_CLEAR := 0.05          ## in a jump with your feet this far up counts as in the air
const ARENA_R := 15.6              ## the eruption fills the arena out to its wall
const PASSES := 4
const DMG_ARM := 25.0
const DMG_BLAST := 18.0
const DMG_RING := 6.0
const DMG_ERUPT := 22.0
const DMG_WAVE := 22.0
const WAVE_BEATS := [0.5, 1.5]     ## phase 3: a wave reaches you this many gaps after the first pass
const WAVE_SPEED := 6.0            ## m/s: a wave's pace, steered within WAVE_STEER to keep its half-beat
const WAVE_STEER := Vector2(0.6, 1.8)
const WAVE_TOP := 0.55             ## the waves burn this high (like the arms): your feet have to be above it
const WAVE_HALF_WIDTH := 0.25
const WALL_H := 1.0                ## height of the arms' flame quads (the fire itself is lower)
const ARM_OFFSET := 0.3            ## the staff is this far in front of him: the arms run along it

## Under a wave: a bright line on the stones where its flames are, the stones it has crossed
## still glowing behind it (a floor quad over the whole arena, additive).
const WAVE_GLOW_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;
uniform float radius = 3.0;
uniform float half_size = 16.6;
uniform float strength = 1.0;
uniform vec3 tint : source_color = vec3(1.0, 0.4, 0.09);
void fragment() {
	float d = length((UV - 0.5) * 2.0 * half_size);
	float edge = exp(-pow((d - radius) / 0.35, 2.0));
	float trail = smoothstep(radius - 2.2, radius, d) * step(d, radius) * 0.22;
	ALBEDO = tint * (edge * 1.6 + trail) * strength;
}
"""

var boss: Boss
var player: Player
var stage: int = St.IDLE
var center := Vector3.ZERO         ## where he stands: the middle of the arena
var passes := 0                    ## arms that have gone past you this turn
var hits := 0                      ## ...and how many of them burned you
var pass_times: Array = []         ## Game.clock of each pass
var fire_top := FIRE_TOP
var blast_hit := false
var erupt_time := -1.0             ## Game.clock when the arena erupted (-1: not yet)
var erupt_hit := false
var gap := GAP                     ## this Inferno's beat (GAP, or GAP_WAVES in phase 3)
var waves_on := false              ## phase 3: waves of fire between the passes
var waves_passed := 0              ## waves that have gone past you (or died down before reaching you)
var wave_hits := 0
var wave_times: Array = []         ## Game.clock of each wave reaching you (its middle where you stand)

var _tau := 0.0                    ## time along the planned turn (slowed after you're knocked down)
var _omega := 0.0                  ## deg/s he's turning (clockwise from above)
var _omega_full := 180.0 / GAP     ## deg/s at full speed (two arms: one reaches you every half turn)
var _first := GAP                  ## start of the turn -> first pass (spinning up from standstill)
var _omega_fast := 0.0
var _waves: Array = []             ## live waves: {k, r, v, target, hit, passed, whoosh, fizzle, vis}
var _wave_next := 0                ## the next wave to send
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
var _plunge_at := -1.0             ## the plunge can't start before this (after a burn, you get up first)
var _erupt_t := -1.0               ## seconds since the eruption (while it can burn you)

# visuals
var _arms: Array = []              ## per arm: {pivot, wall, strip, flames, embers, smoke, lights}
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
var _cracks: MeshInstance3D
var _cracks_mat: ShaderMaterial
var _fuse_vis := -1.0              ## seconds since the plunge hit (drives the cracks)
var _erupt_vis := -1.0             ## seconds since the eruption (drives its fire)
var _erupt_bands: Array = []       ## [MeshInstance3D, ShaderMaterial, radius]
var _erupt_light: OmniLight3D
var _wave_vis: Array = []          ## per slot: {band, mat, glow, light}


func setup(b: Boss) -> void:
	boss = b
	top_level = true
	_set_beat(GAP)
	_build_visuals()


## The turn's timing for a beat of `g` seconds between the first three passes.
func _set_beat(g: float) -> void:
	gap = g
	_omega_full = 180.0 / g
	_first = g
	_omega_fast = (180.0 - _omega_full * RAMP_FAST * 0.5) / (GAP_FAST - RAMP_FAST * 0.5)


func is_active() -> bool:
	return stage != St.IDLE


func stage_name() -> String:
	return ["idle", "leap", "ignite", "spin", "wind down", "plunge"][stage]


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
	_plunge_at = -1.0
	_erupt_t = -1.0
	erupt_time = -1.0
	erupt_hit = false
	waves_on = boss.phase >= 3
	_set_beat(GAP_WAVES if waves_on else GAP)
	waves_passed = 0
	wave_hits = 0
	wave_times.clear()
	_waves.clear()
	_wave_next = 0
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
			_send_waves()
			_move_waves(delta)
			_ring_check(delta)
		St.WIND_DOWN:
			_wind_down(delta)
			_move_waves(delta)
			_ring_check(delta)
		St.PLUNGE:
			_track(delta)
			if erupt_time < 0.0:
				_ring_check(delta)
			# (the flames still burning at the wall outlast the clip by a moment)
			if boss.anim.finished and _erupt_t < 0.0:
				_finish()
	_tick_blast(delta)
	_tick_eruption(delta)
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
		"fire_plunge":
			var pts2 := boss.rig.blade_world("lower")
			var tip2 := pts2[pts2.size() - 1] if pts2.size() > 0 else boss.global_position
			var ground2 := Vector3(tip2.x, center.y, tip2.z)
			Fx.dust(boss.get_parent(), ground2, 36, 1.4)
			Fx.sparks(boss.get_parent(), ground2 + Vector3(0, 0.05, 0), Vector3.UP, Fx.SPARK_GROUND)
			FireFx.burst(boss.get_parent(), ground2 + Vector3(0, 0.2, 0), 1.4)
			Sfx.play("ground_impact", ground2, 5.0)
			Sfx.play("fire_fuse", center + Vector3(0, 0.5, 0), 4.0, 1.0, 0.0)
			Game.shake(0.45, 0.3)
			Game.rumble(0.5, 0.8, 0.25)
			_fuse_vis = 0.0
		"fire_erupt":
			_erupt()


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
	burst.color = Color(1, 0.7, 1, 0.85)
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
## reaches you `_first` seconds in, then `_omega_full` (a pass every `gap`), then after the third
## pass it speeds up so the fourth arrives GAP_FAST later.
func _omega_at(tau: float) -> float:
	var t3 := _first + 2.0 * gap
	if tau < _first:
		return _omega_full * tau / _first
	if tau < t3:
		return _omega_full
	var u := tau - t3
	if u < RAMP_FAST:
		return lerpf(_omega_full, _omega_fast, u / RAMP_FAST)
	return _omega_fast


## Degrees turned by `tau` (the integral of _omega_at): an arm reaches you at 90, 270, 450, 630.
func _sigma_at(tau: float) -> float:
	var t3 := _first + 2.0 * gap
	if tau < _first:
		return _omega_full * tau * tau / (2.0 * _first)
	if tau < t3:
		return 90.0 + _omega_full * (tau - _first)
	var u := tau - t3
	var s := 90.0 + _omega_full * 2.0 * gap
	if u < RAMP_FAST:
		return s + _omega_full * u + (_omega_fast - _omega_full) * u * u / (2.0 * RAMP_FAST)
	return s + (_omega_full + _omega_fast) * RAMP_FAST * 0.5 + _omega_fast * (u - RAMP_FAST)


func _tau_pass(k: int) -> float:
	match k:
		1:
			return _first
		2:
			return _first + gap
		3:
			return _first + 2.0 * gap
	return _first + 2.0 * gap + GAP_FAST


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
				_douse_waves()
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
	_lead_prev = lead


## The third arm has gone by: the fire flares and the last one comes round faster.
func _flare() -> void:
	fire_top = FIRE_TOP_FAST
	_heat_target = 1.6
	Sfx.play("fire_flare", center + Vector3(0, 1.2, 0), 4.0)
	Fx.light_pulse(boss.get_parent(), center + Vector3(0, 1.5, 0), Color(1.0, 0.45, 0.1), 5.0, 12.0, 0.5)


# ------------------------------------------------------------------------------ waves (phase 3)
## Plan time (`_tau`) when wave `k` reaches you.
func _wave_target(k: int) -> float:
	return _first + float(WAVE_BEATS[k]) * gap


func _player_r() -> float:
	if player == null:
		return REACH
	return Combat.flat(player.global_position - center).length()


## Sends the next wave from the ring when, at WAVE_SPEED, it would reach you on its half-beat.
## Not while you're down; a wave whose moment passed while you were down is skipped, and so is
## one that would have to rush at you to make its beat.
func _send_waves() -> void:
	if not waves_on:
		return
	while _wave_next < WAVE_BEATS.size():
		var left := _wave_target(_wave_next) - _tau
		var dist := maxf(_player_r() - RING_R, 0.0)
		var down := Game.clock < _fair_until
		if left <= 0.0 or (not down and dist > left * WAVE_SPEED * WAVE_STEER.y):
			_wave_next += 1
			waves_passed += 1          # (it never comes: count it as gone, like one that's passed)
			continue
		if down or dist < left * WAVE_SPEED:
			return
		_waves.append({"k": _wave_next, "r": RING_R, "v": WAVE_SPEED, "target": _wave_target(_wave_next),
			"hit": false, "passed": false, "at_you": false, "whoosh": false, "fizzle": -1.0, "vis": 0.0})
		_wave_next += 1
		Sfx.play("fire_ignite", center + Vector3(0, 0.8, 0), 3.0, 1.15, 0.0)
		Fx.light_pulse(boss.get_parent(), center + Vector3(0, 1.0, 0), Color(1.0, 0.5, 0.15), 3.5, 9.0, 0.35)


## Rolls the waves out, steering each to reach you on its half-beat (within WAVE_STEER of
## WAVE_SPEED), and burns you if one reaches you with your feet below WAVE_TOP.
func _move_waves(delta: float) -> void:
	if _waves.is_empty():
		return
	var rp := _player_r()
	var hr := player.hurt_radius if player != null else 0.3
	for w in _waves:
		if float(w["fizzle"]) >= 0.0:
			w["fizzle"] = float(w["fizzle"]) + delta
			w["r"] = float(w["r"]) + float(w["v"]) * delta
			continue
		var left := float(w["target"]) - _tau
		if not bool(w["passed"]) and left > 0.02:
			w["v"] = clampf((rp - float(w["r"])) / left, WAVE_SPEED * WAVE_STEER.x, WAVE_SPEED * WAVE_STEER.y)
		w["r"] = float(w["r"]) + float(w["v"]) * delta
		var r := float(w["r"])
		# the whoosh peaks as it reaches you
		if player != null and not bool(w["whoosh"]) and not bool(w["passed"]) and rp > r and (rp - r) / float(w["v"]) < 0.28:
			w["whoosh"] = true
			Sfx.play("fire_whoosh", player.global_position + Vector3(0, 0.4, 0), 3.0, 0.9, 0.05)
		if player != null and not bool(w["hit"]) and absf(rp - r) < WAVE_HALF_WIDTH + hr and player.can_be_hit() \
				and Game.clock - _burned_at > 1.0:
			var feet := player.global_position.y - center.y
			if feet < WAVE_TOP + 0.01:
				w["hit"] = true
				var info := {"kind": "sweep", "element": "fire", "part": "wave", "dmg": DMG_WAVE, "posture_block": 0,
					"posture_deflect": 0, "boss_posture": 0, "dir": "low", "final": true, "clip": "inferno",
					"index": int(w["k"]), "point": player.global_position + Vector3(0, 0.35, 0), "time": Game.clock}
				if player.receive_attack(info, boss) == Combat.RESULT_HIT:
					wave_hits += 1
					hits += 1
					_burned_at = Game.clock
					_fair_until = Game.clock + FAIR
					_douse_waves()
		if not bool(w["at_you"]) and r >= rp:
			w["at_you"] = true
			wave_times.append(Game.clock)
		if not bool(w["passed"]) and r - WAVE_HALF_WIDTH > rp + hr:
			w["passed"] = true
			waves_passed += 1
	_waves = _waves.filter(func(w): return float(w["r"]) < ARENA_R + 0.6 and float(w["fizzle"]) < 0.5)


## You've been burned: the waves still coming at you die down (count as gone).
func _douse_waves() -> void:
	var rp := _player_r()
	for w in _waves:
		if not bool(w["passed"]) and float(w["fizzle"]) < 0.0 and float(w["r"]) < rp:
			w["fizzle"] = 0.0
			w["passed"] = true
			waves_passed += 1


func _wind_down(delta: float) -> void:
	_wind_t += delta
	var u := clampf(_wind_t / WIND_DOWN, 0.0, 1.0)
	_turn(_wind_from * (1.0 - smoothstep(0.0, 1.0, u)), delta)
	# burned by the last arm: the eruption waits until you've had time to get up
	_plunge_at = maxf(_plunge_at, _burned_at + FAIR - _erupt_offset())
	if u >= 1.0 and Game.clock >= _plunge_at:
		_begin_plunge()


## Clip time of the eruption in b_fire_plunge (from its "fire_erupt" event).
func _erupt_offset() -> float:
	var c := AnimLibrary.get_clip("b_fire_plunge")
	if c != null:
		for ev in c.events:
			if str(ev.get("type", "")) == "fire_erupt":
				return float(ev["t"])
	return 1.12


func _begin_plunge() -> void:
	stage = St.PLUNGE
	boss.anim.speed = 1.0
	boss.anim.play("b_fire_plunge", 0.16)


## The whole arena erupts, rolling out from his staff: see _tick_eruption.
func _erupt() -> void:
	_erupt_t = 0.0
	erupt_time = Game.clock
	erupt_hit = false
	_erupt_vis = 0.0
	_ring_target = 0.0
	boss.staff_fire.set_level(0.6, 2.0)
	Sfx.play("fire_eruption", center + Vector3(0, 1.0, 0), 6.0, 1.0, 0.0)
	if player != null:
		Sfx.play("fire_whoosh", player.global_position + Vector3(0, 0.4, 0), 4.0, 0.8, 0.0)
	Game.shake(0.8, 0.6)
	Game.rumble(0.8, 1.0, 0.4)
	var burst := FireFx.flames(520, 0.8, 1.6)
	burst.color = Color(1, 0.55, 1, 0.8)
	burst.one_shot = true
	burst.explosiveness = 0.8
	burst.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	burst.emission_ring_axis = Vector3.UP
	burst.emission_ring_radius = ARENA_R - 0.3
	burst.emission_ring_inner_radius = 0.0
	burst.emission_ring_height = 0.05
	burst.spread = 12.0
	burst.initial_velocity_min = 2.0
	burst.initial_velocity_max = 4.5
	burst.gravity = Vector3(0, 1.5, 0)
	Fx._emit_at(boss.get_parent(), burst, center + Vector3(0, 0.1, 0))
	Fx._free_later(burst, 1.4)


## The eruption reaches you a moment after it bursts from his staff (ERUPT_WAVE), leaps up
## (ERUPT_GRACE) and burns for ERUPT_DANGER: on the ground then, you're burned. Anywhere in a
## jump you're clear, rising or falling: jump as it erupts and you go over it, jump too early and
## you land in it.
func _tick_eruption(delta: float) -> void:
	if _erupt_t < 0.0:
		return
	_erupt_t += delta
	if _erupt_t > eruption_length():
		_erupt_t = -1.0
		return
	if erupt_hit or player == null or not player.can_be_hit():
		return
	var here := _erupt_t - eruption_delay(player.global_position)
	if here < 0.0 or here > ERUPT_DANGER:
		return
	if player.is_airborne() and player.global_position.y - center.y > ERUPT_CLEAR:
		return
	var info := {"kind": "sweep", "element": "fire", "part": "eruption", "dmg": DMG_ERUPT, "posture_block": 0,
		"posture_deflect": 0, "boss_posture": 0, "dir": "low", "final": true, "clip": "inferno", "index": PASSES,
		"point": player.global_position + Vector3(0, 0.35, 0), "time": Game.clock}
	if player.receive_attack(info, boss) == Combat.RESULT_HIT:
		erupt_hit = true
		_burned_at = Game.clock


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
	_erupt_t = -1.0
	Sfx.play("fire_gutter", center + Vector3(0, 1.0, 0), 2.0)
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
	_erupt_t = -1.0
	_fuse_vis = -1.0
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
	return (stage == St.SPIN or stage == St.WIND_DOWN or (stage == St.PLUNGE and erupt_time < 0.0)) and _ring_level >= 0.3


## True while the eruption can burn you (somewhere in the arena).
func erupting() -> bool:
	return _erupt_t >= 0.0


## Seconds from the eruption bursting from his staff to its flames dying at the wall.
static func eruption_length() -> float:
	return ARENA_R / ERUPT_WAVE + ERUPT_GRACE + ERUPT_DANGER


## Seconds from the eruption bursting at his staff to its flames leaping up at `pos`.
func eruption_delay(pos: Vector3) -> float:
	return ERUPT_GRACE + Combat.flat(pos - center).length() / ERUPT_WAVE


## True between the plunge hitting the stones and the eruption (the cracks racing out).
func fusing() -> bool:
	return stage == St.PLUNGE and _fuse_vis >= 0.0 and erupt_time < 0.0


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


## Seconds until the next thing you have to jump: the next arm at the current turn rate, or
## the eruption's flames reaching you once he's started the plunge (INF when neither is coming).
func next_jump_in() -> float:
	if stage == St.SPIN and _omega >= 1.0:
		return minf(_lead_deg() / _omega, next_wave_in())
	if stage == St.PLUNGE and player != null and boss.anim.is_playing("b_fire_plunge"):
		var reach := eruption_delay(player.global_position)
		if erupt_time < 0.0:
			return maxf(0.0, (_erupt_offset() - boss.anim.time) / maxf(boss.anim.speed, 0.01)) + reach
		if Game.clock <= erupt_time + reach:
			return erupt_time + reach - Game.clock
	return INF


## Seconds until the next wave reaches you (one on its way, or the next to be sent; INF if none).
func next_wave_in() -> float:
	if not waves_on or player == null:
		return INF
	var rp := _player_r()
	var best := INF
	for w in _waves:
		if not bool(w["passed"]) and float(w["fizzle"]) < 0.0 and float(w["r"]) < rp:
			best = minf(best, (rp - float(w["r"]) - WAVE_HALF_WIDTH - player.hurt_radius) / maxf(float(w["v"]), 0.1))
	if best == INF and _wave_next < WAVE_BEATS.size() and stage == St.SPIN:
		best = _wave_target(_wave_next) - _tau
	return maxf(best, 0.0)


## Radii of the waves rolling out (for the diagnostics overlay).
func wave_radii() -> Array:
	var out: Array = []
	for w in _waves:
		if float(w["fizzle"]) < 0.0:
			out.append(float(w["r"]))
	return out


# ============================================================================== visuals
func _build_visuals() -> void:
	for i in 2:
		var pivot := Node3D.new()
		add_child(pivot)
		var wall := MeshInstance3D.new()
		wall.mesh = FireFx.wall_mesh(ARM_FROM - 0.35, REACH, WALL_H)
		wall.material_override = FireFx.wall_material(REACH - ARM_FROM, false, WALL_H)
		wall.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		wall.extra_cull_margin = 4.0
		pivot.add_child(wall)
		var strip := MeshInstance3D.new()
		strip.mesh = FireFx.strip_mesh(ARM_FROM - 0.35, REACH, 0.9)
		strip.material_override = FireFx.strip_material(REACH - ARM_FROM)
		strip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		pivot.add_child(strip)
		# (they ride on the arm: left behind, a sweeping arm would strew the floor with flames)
		var fl := FireFx.flames(110, 0.34, 0.9)
		fl.local_coords = true
		fl.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
		fl.emitting = false
		fl.gravity = Vector3(0, 2.0, 0)
		fl.initial_velocity_min = 0.3
		fl.initial_velocity_max = 1.0
		pivot.add_child(fl)
		var em := FireFx.embers(44, 1.1)
		em.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
		em.emitting = false
		em.initial_velocity_max = 2.4
		pivot.add_child(em)
		var sm := FireFx.smoke_emitter(16, 1.7, 1.1)
		sm.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
		sm.emitting = false
		pivot.add_child(sm)
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
		_arms.append({"pivot": pivot, "wall": wall, "strip": strip, "flames": fl, "embers": em, "smoke": sm, "lights": lights})

	_ring = Node3D.new()
	add_child(_ring)
	var band := MeshInstance3D.new()
	band.mesh = FireFx.band_mesh(1.1, 72)
	band.scale = Vector3(RING_R, 1.0, RING_R)
	_ring_mat = FireFx.wall_material(TAU * RING_R, true, 1.1)
	band.material_override = _ring_mat
	band.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.add_child(band)
	_ring_flames = FireFx.flames(100, 0.45, 0.8)
	_ring_flames.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	_ring_flames.emission_ring_axis = Vector3.UP
	_ring_flames.emission_ring_radius = RING_R
	_ring_flames.emission_ring_inner_radius = RING_R - 0.12
	_ring_flames.emission_ring_height = 0.05
	_ring_flames.emitting = false
	_ring_flames.color = Color(1, 0.6, 1, 0.8)
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
	_blast_mat = FireFx.wall_material(TAU * BLAST_R, true, 1.0)
	_blast_band.material_override = _blast_mat
	_blast_band.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_blast_band.visible = false
	add_child(_blast_band)

	_cracks = FireFx.floor_quad(ARENA_R * 2.0, 0.035)
	_cracks_mat = FireFx.cracks_material()
	_cracks.material_override = _cracks_mat
	_cracks.visible = false
	add_child(_cracks)
	# only the ring round him: in the finisher it's the floor that burns, and rings of flame
	# further out would read as walls when all it takes is a jump
	for r in [3.6]:
		var band2 := MeshInstance3D.new()
		band2.mesh = FireFx.band_mesh(1.0, 96)
		var m2 := FireFx.wall_material(TAU * r, true, 1.0)
		band2.material_override = m2
		band2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		band2.visible = false
		add_child(band2)
		_erupt_bands.append([band2, m2, r])
	# phase 3's waves: a band of flame rolling out, a glowing line on the stones under it, and a
	# light where it's coming at you
	for i in 2:
		var band3 := MeshInstance3D.new()
		band3.mesh = FireFx.band_mesh(1.0, 160)
		var m3 := FireFx.wall_material(TAU * RING_R, true, 1.0)
		band3.material_override = m3
		band3.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		band3.visible = false
		add_child(band3)
		var glow3 := FireFx.floor_quad((ARENA_R + 1.0) * 2.0, 0.04)
		var gm := FireFx._material("wave_glow", WAVE_GLOW_SHADER, {"half_size": ARENA_R + 1.0}, 1)
		glow3.material_override = gm
		glow3.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		glow3.visible = false
		add_child(glow3)
		var l3 := OmniLight3D.new()
		l3.light_color = Color(1.0, 0.5, 0.16)
		l3.omni_range = 6.0
		l3.omni_attenuation = 1.2
		l3.light_energy = 0.0
		l3.shadow_enabled = false
		add_child(l3)
		_wave_vis.append({"band": band3, "mat": m3, "glow": glow3, "gmat": gm, "light": l3})
	_erupt_light = OmniLight3D.new()
	_erupt_light.light_color = Color(1.0, 0.45, 0.12)
	_erupt_light.omni_range = 34.0
	_erupt_light.omni_attenuation = 0.9
	_erupt_light.light_energy = 0.0
	_erupt_light.shadow_enabled = false
	add_child(_erupt_light)

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
	_update_eruption(delta)
	_update_ring(delta)
	_update_waves(delta)
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


## The plunge: cracks of fire race out across the floor from his staff (the fuse), then the
## floor erupts: bands of flame burst up across the arena and a flash lights everything.
func _update_eruption(delta: float) -> void:
	var on := _fuse_vis >= 0.0
	_cracks.visible = on
	if on:
		_fuse_vis += delta
		_cracks.global_position = center + Vector3(0, 0.035, 0)
		var fuse := _erupt_offset() - 0.82          # plunge hit -> eruption (b_fire_plunge)
		var reveal := clampf(_fuse_vis / maxf(fuse * 0.8, 0.05), 0.0, 1.0)
		var glow := 0.55 + 0.45 * clampf(_fuse_vis / maxf(fuse, 0.05), 0.0, 1.0)
		if _erupt_vis >= 0.0:
			glow = 0.7 * (1.0 - clampf((_erupt_vis - 0.15) / 1.1, 0.0, 1.0))
			if glow <= 0.0:
				_fuse_vis = -1.0
		_cracks_mat.set_shader_parameter("reveal", reveal * 1.02)
		_cracks_mat.set_shader_parameter("glow", glow)
	var e_on := _erupt_vis >= 0.0
	_erupt_light.light_energy = 0.0
	for b in _erupt_bands:
		(b[0] as MeshInstance3D).visible = false
	if not e_on:
		return
	_erupt_vis += delta
	_erupt_light.global_position = center + Vector3(0, 3.0, 0)
	_erupt_light.light_energy = 4.5 * maxf(0.0, 1.0 - _erupt_vis / 0.9)
	for b in _erupt_bands:
		var mi: MeshInstance3D = b[0]
		var mat: ShaderMaterial = b[1]
		var r := float(b[2])
		var here := _erupt_vis - r / ERUPT_WAVE                  # a hair later further out
		var u := clampf(here / 0.8, 0.0, 1.0)
		if u <= 0.0 or u >= 1.0:
			continue
		mi.visible = true
		mi.global_position = center
		# up while it burns (ERUPT_GRACE .. + ERUPT_DANGER), then falling fast
		var rise := smoothstep(0.0, ERUPT_GRACE * 2.0, here) * (1.0 - smoothstep(ERUPT_GRACE + ERUPT_DANGER - 0.04,
			ERUPT_GRACE + ERUPT_DANGER + 0.12, here))
		mi.scale = Vector3(r, 0.3 + 1.3 * rise, r)
		mat.set_shader_parameter("heat", 0.85)
		mat.set_shader_parameter("alpha_mult", (1.0 - u) * 0.9)
	if _erupt_vis > 1.3:
		_erupt_vis = -1.0


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
	_ring_mat.set_shader_parameter("heat", 0.5 + 0.2 * _heat)
	(_ring_glow.material_override as StandardMaterial3D).albedo_color = Color(1.1, 0.95, 0.85, _ring_level)
	(_ring.get_node("RingLight") as OmniLight3D).light_energy = 2.0 * _ring_level


func _update_waves(delta: float) -> void:
	for i in _wave_vis.size():
		var slot: Dictionary = _wave_vis[i]
		var band: MeshInstance3D = slot["band"]
		var glow: MeshInstance3D = slot["glow"]
		var light: OmniLight3D = slot["light"]
		var on := i < _waves.size()
		band.visible = on
		glow.visible = on
		light.light_energy = 0.0
		if not on:
			continue
		var w: Dictionary = _waves[i]
		w["vis"] = float(w["vis"]) + delta
		var r := float(w["r"])
		var dying := clampf(float(w["fizzle"]) / 0.45, 0.0, 1.0) if float(w["fizzle"]) >= 0.0 else 0.0
		var fade := clampf(float(w["vis"]) / 0.12, 0.0, 1.0) * (1.0 - dying)
		fade *= 1.0 - smoothstep(ARENA_R - 1.0, ARENA_R + 0.5, r)
		band.global_position = center
		band.scale = Vector3(r, 0.95 * (1.0 - 0.7 * dying), r)
		var m: ShaderMaterial = slot["mat"]
		m.set_shader_parameter("scale_x", TAU * r)
		m.set_shader_parameter("heat", 0.95)
		m.set_shader_parameter("height", 0.85)
		m.set_shader_parameter("alpha_mult", fade)
		glow.global_position = center + Vector3(0, 0.04, 0)
		var gm: ShaderMaterial = slot["gmat"]
		gm.set_shader_parameter("radius", r)
		gm.set_shader_parameter("strength", fade)
		if player != null:
			var to := Combat.flat(player.global_position - center)
			var d := to.normalized() if to.length() > 0.05 else boss.forward()
			light.global_position = center + d * r + Vector3(0, 0.6, 0)
			light.light_energy = 1.8 * fade


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
		(a["embers"] as CPUParticles3D).emitting = _arm_len > 0.3
		(a["smoke"] as CPUParticles3D).emitting = _arm_len > 0.3
		if not on:
			continue
		pivot.global_position = center + fwd * ARM_OFFSET
		pivot.rotation = Vector3(0, float(yaws[i]) + PI * 0.5, 0)
		var heat := clampf(_heat, 0.0, 2.0)
		var wall: ShaderMaterial = (a["wall"] as MeshInstance3D).material_override
		wall.set_shader_parameter("reveal", _arm_len)
		wall.set_shader_parameter("heat", 0.3 + 0.55 * heat)
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
		fl.color = Color(1, 0.72, 1, clampf(heat, 0.0, 1.0))
		for key in ["embers", "smoke"]:
			var extra: CPUParticles3D = a[key]
			extra.position = Vector3(ARM_FROM + run * 0.5, 0.35 if key == "embers" else 0.7, 0)
			extra.emission_box_extents = Vector3(maxf(0.1, run * 0.5), 0.1, 0.18)
			extra.color = Color(1, 1, 1, clampf(heat, 0.0, 1.0))
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
