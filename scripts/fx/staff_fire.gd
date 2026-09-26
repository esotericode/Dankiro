class_name StaffFire
extends Node3D
## Flames on both blades of Sojin's staff (phase 2 on). Each blade has a level: 0 out,
## SMOULDER (small flames and embers, his look between fire moves), 1 ablaze (the Inferno).
## The flames are world-space particles, so they stream behind the blades as the staff moves.
## `climb` (0..1, -1 off) runs fire up the shaft from the lower blade: the planted staff
## catching while he channels.

const SMOULDER := 0.3

var rig: HumanoidRig
var _blaze: Dictionary = {}       ## blade -> CPUParticles3D (big flames)
var _small: Dictionary = {}       ## blade -> CPUParticles3D (smoulder flames)
var _embers: Dictionary = {}      ## blade -> CPUParticles3D
var _lights: Dictionary = {}      ## blade -> OmniLight3D
var _level := {"upper": 0.0, "lower": 0.0}
var _target := {"upper": 0.0, "lower": 0.0}
var _rate := {"upper": 2.0, "lower": 2.0}
var climb := -1.0
var _shaft: CPUParticles3D
var _shaft_len := 1.8


func setup(r: HumanoidRig) -> void:
	rig = r
	for bname in ["upper", "lower"]:
		var pts: PackedVector3Array = rig.blades[bname]
		var a := pts[0]
		var b := pts[pts.size() - 1]
		var mid := (a + b) * 0.5
		var half := (b - a).length() * 0.5
		var big := FireFx.flames(90, 0.42, 0.5)
		_along_blade(big, mid, half)
		var small := FireFx.flames(26, 0.36, 0.24)
		_along_blade(small, mid + (b - a).normalized() * half * 0.3, half * 0.6)
		var em := FireFx.embers(14, 1.1)
		_along_blade(em, mid, half)
		_blaze[bname] = big
		_small[bname] = small
		_embers[bname] = em
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.52, 0.18)
		l.light_energy = 0.0
		l.omni_range = 4.5
		l.omni_attenuation = 1.4
		l.shadow_enabled = false
		l.position = b
		rig.weapon_node.add_child(l)
		_lights[bname] = l
	var shaft_pts: PackedVector3Array = rig.blades.get("shaft", PackedVector3Array())
	if shaft_pts.size() >= 2:
		_shaft_len = (shaft_pts[shaft_pts.size() - 1] - shaft_pts[0]).length()
	_shaft = FireFx.flames(60, 0.4, 0.34)
	_along_blade(_shaft, Vector3.ZERO, 0.1)


func _along_blade(p: CPUParticles3D, center: Vector3, half: float) -> void:
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(0.035, half, 0.035)
	p.position = center
	p.emitting = false
	rig.weapon_node.add_child(p)


## Sets where the fire is heading (both blades, or one) and how fast it gets there (per second).
func set_level(target: float, rate := 2.0, blade := "") -> void:
	for bname in _target:
		if blade == "" or blade == bname:
			_target[bname] = target
			_rate[bname] = rate


func level(blade := "upper") -> float:
	return float(_level.get(blade, 0.0))


func _process(delta: float) -> void:
	if rig == null:
		return
	for bname in _level:
		var lv := move_toward(float(_level[bname]), float(_target[bname]), float(_rate[bname]) * delta)
		_level[bname] = lv
		var big: CPUParticles3D = _blaze[bname]
		var small: CPUParticles3D = _small[bname]
		var em: CPUParticles3D = _embers[bname]
		# smoulder: small flames + embers; above that the big flames take over
		var blaze := clampf((lv - SMOULDER) / (1.0 - SMOULDER), 0.0, 1.0)
		big.emitting = blaze > 0.03
		big.color = Color(1, 1, 1, 0.35 + 0.65 * blaze)
		big.scale_amount_min = 0.35 + 0.35 * blaze
		big.scale_amount_max = 0.7 + 0.5 * blaze
		small.emitting = lv > 0.04
		small.color = Color(1, 1, 1, clampf(lv / SMOULDER, 0.0, 1.0))
		em.emitting = lv > 0.04
		(_lights[bname] as OmniLight3D).light_energy = 0.9 * clampf(lv / SMOULDER, 0.0, 1.0) + 2.6 * blaze
	# fire running up the planted shaft from the lower blade
	_shaft.emitting = climb > 0.0 and climb < 1.2
	if _shaft.emitting:
		var c := clampf(climb, 0.0, 1.0)
		var run := _shaft_len * c
		_shaft.position = Vector3(0, -_shaft_len * 0.5 + run * 0.5, 0)
		_shaft.emission_box_extents = Vector3(0.03, maxf(0.05, run * 0.5), 0.03)
