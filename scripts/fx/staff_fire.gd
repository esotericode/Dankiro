class_name StaffFire
extends Node3D
## Flames on both blades of the Twin Fang's staff (phase 2 on). Each blade has a level: 0 out,
## SMOULDER (his look between fire moves), 1 ablaze (the Inferno).
##
## Smouldering is kept low so his strikes stay easy to read: small licks that cling to the
## blades (they move with them, so a swing never leaves fire hanging in the air), a few embers
## and a faint light. Ablaze, big world-space flames take over and stream behind the blades as
## they move. `climb` (0..1, -1 off) runs fire up the shaft from the lower blade: the planted
## staff catching while he channels.

const SMOULDER := 0.3

var rig: HumanoidRig
var _licks: Dictionary = {}       ## blade -> CPUParticles3D (clinging flames, local to the blade)
var _blaze: Dictionary = {}       ## blade -> CPUParticles3D (the Inferno's flames, world-space)
var _embers: Dictionary = {}      ## blade -> CPUParticles3D
var _lights: Dictionary = {}      ## blade -> OmniLight3D
var _level := {"upper": 0.0, "lower": 0.0}
var _target := {"upper": 0.0, "lower": 0.0}
var _rate := {"upper": 2.0, "lower": 2.0}
var climb := -1.0
var _shaft: CPUParticles3D
var _shaft_len := 1.8
var _t := 0.0


func setup(r: HumanoidRig) -> void:
	rig = r
	for bname in ["upper", "lower"]:
		var pts: PackedVector3Array = rig.blades[bname]
		var a := pts[0]
		var b := pts[pts.size() - 1]
		var mid := (a + b) * 0.5
		var half := (b - a).length() * 0.5
		var along := (b - a).normalized()
		# clinging licks along the outer part of the blade
		var licks := FireFx.flames(16, 0.3, 0.2)
		licks.local_coords = true
		licks.gravity = Vector3.ZERO
		licks.initial_velocity_min = 0.0
		licks.initial_velocity_max = 0.08
		licks.spread = 180.0
		_along_blade(licks, mid + along * half * 0.15, half * 0.85)
		var big := FireFx.flames(26, 0.45, 0.5)
		_along_blade(big, mid, half)
		var em := FireFx.embers(10, 1.0)
		_along_blade(em, mid, half)
		_licks[bname] = licks
		_blaze[bname] = big
		_embers[bname] = em
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.5, 0.17)
		l.light_energy = 0.0
		l.omni_range = 4.0
		l.omni_attenuation = 1.5
		l.shadow_enabled = false
		l.position = mid + along * half * 0.5
		rig.weapon_node.add_child(l)
		_lights[bname] = l
	var shaft_pts: PackedVector3Array = rig.blades.get("shaft", PackedVector3Array())
	if shaft_pts.size() >= 2:
		_shaft_len = (shaft_pts[shaft_pts.size() - 1] - shaft_pts[0]).length()
	_shaft = FireFx.flames(34, 0.4, 0.34)
	_along_blade(_shaft, Vector3.ZERO, 0.1)


func _along_blade(p: CPUParticles3D, center: Vector3, half: float) -> void:
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(0.03, half, 0.03)
	p.position = center
	p.emitting = false
	rig.weapon_node.add_child(p)


## Sets where the fire is heading (both blades, or one) and how fast it gets there (per second).
func set_level(target: float, rate := 2.0, blade := "") -> void:
	for bname in _target:
		if blade == "" or blade == bname:
			_target[bname] = target
			_rate[bname] = rate


## The warm-up (Warmup): both blades ablaze and the shaft alight (`on`), then out again with
## every flame cleared.
func warm_up(on: bool) -> void:
	for bname in _level:
		_level[bname] = 1.0 if on else 0.0
		_target[bname] = _level[bname]
	climb = 0.5 if on else -1.0
	if not on:
		for p in _licks.values() + _blaze.values() + _embers.values() + [_shaft]:
			(p as CPUParticles3D).restart()
			(p as CPUParticles3D).emitting = false


func level(blade := "upper") -> float:
	return float(_level.get(blade, 0.0))


func _process(delta: float) -> void:
	if rig == null:
		return
	_t += delta
	for bname in _level:
		var lv := move_toward(float(_level[bname]), float(_target[bname]), float(_rate[bname]) * delta)
		_level[bname] = lv
		var s := clampf(lv / SMOULDER, 0.0, 1.0)                              # the low burn
		var blaze := clampf((lv - SMOULDER) / (1.0 - SMOULDER), 0.0, 1.0)     # the Inferno's fire
		var licks: CPUParticles3D = _licks[bname]
		licks.emitting = lv > 0.03
		# (heat, brightness, -, opacity): a smoulder is orange rather than white-hot
		licks.color = Color(0.5 + 0.4 * blaze, 0.7, 1.0, 0.6 * s * (1.0 - 0.5 * blaze))
		var big: CPUParticles3D = _blaze[bname]
		big.emitting = blaze > 0.03
		big.color = Color(1.0, 0.62, 1.0, 0.2 + 0.4 * blaze)
		big.scale_amount_min = 0.45 + 0.3 * blaze
		big.scale_amount_max = 0.8 + 0.35 * blaze
		var em: CPUParticles3D = _embers[bname]
		em.emitting = lv > 0.03
		em.color = Color(1.0, 1.0, 1.0, 0.45 * s + 0.55 * blaze)
		var flicker := 0.85 + 0.1 * sin(_t * 13.0 + (0.0 if bname == "upper" else 2.1)) + 0.05 * sin(_t * 31.0)
		(_lights[bname] as OmniLight3D).light_energy = (0.25 * s + 1.2 * blaze) * flicker
	# fire running up the planted shaft from the lower blade
	_shaft.emitting = climb > 0.0 and climb < 1.2
	if _shaft.emitting:
		var c := clampf(climb, 0.0, 1.0)
		var run := _shaft_len * c
		_shaft.position = Vector3(0, -_shaft_len * 0.5 + run * 0.5, 0)
		_shaft.emission_box_extents = Vector3(0.03, maxf(0.05, run * 0.5), 0.03)
