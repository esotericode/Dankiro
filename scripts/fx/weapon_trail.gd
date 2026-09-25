class_name WeaponTrail
extends MeshInstance3D
## Swing trail drawn in world space: a solid arc of light over the outer part of the blade
## plus a bright, crisp line along the tip path, so a slash reads as one clean stroke rather
## than a faint smear. Samples are only pushed while the tip moves fast (strikes, not idle
## motion). `force_color` tints perilous attacks red.

var source: HumanoidRig
var blade_name := "blade"
var max_samples := 18
var min_speed := 4.5          ## m/s of the blade tip before the trail shows
var life := 0.15              ## seconds a sample lives
var inner := 0.3              ## where the arc starts along the blade (0 = base, 1 = tip)
var base_color := Color(0.85, 0.9, 1.0, 0.75)
var force_color := Color(0, 0, 0, 0)
var brightness := 1.25        ## HDR multiplier (the glow pass blooms it)

var _bases := PackedVector3Array()
var _tips := PackedVector3Array()
var _ages := PackedFloat32Array()
var _last_tip := Vector3.ZERO
var _has_last := false
var _im: ImmediateMesh
var _mat: StandardMaterial3D


func _enter_tree() -> void:
	if _mat != null:
		_mat.albedo_color = Color(brightness, brightness, brightness, 1.0)


func setup(p_source: HumanoidRig, p_blade: String, color: Color) -> void:
	source = p_source
	blade_name = p_blade
	base_color = color
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_im = ImmediateMesh.new()
	mesh = _im
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.vertex_color_use_as_albedo = true
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat.albedo_color = Color(brightness, brightness, brightness, 1.0)
	material_override = _mat


func _ready() -> void:
	global_transform = Transform3D.IDENTITY


func clear_trail() -> void:
	_bases.clear()
	_tips.clear()
	_ages.clear()
	_has_last = false


func _physics_process(delta: float) -> void:
	if source == null or not is_instance_valid(source):
		return
	global_transform = Transform3D.IDENTITY
	for i in _ages.size():
		_ages[i] += delta
	while _ages.size() > 0 and _ages[0] > life:
		_ages.remove_at(0)
		_bases.remove_at(0)
		_tips.remove_at(0)
	var pts := source.blade_world(blade_name)
	if pts.size() < 2:
		return
	var base := pts[0]
	var tip := pts[pts.size() - 1]
	var spd := 0.0
	if _has_last and delta > 0.0:
		spd = (tip - _last_tip).length() / delta
	_last_tip = tip
	_has_last = true
	if spd > min_speed:
		_bases.append(base.lerp(tip, inner))
		_tips.append(tip)
		_ages.append(0.0)
		if _ages.size() > max_samples:
			_ages.remove_at(0)
			_bases.remove_at(0)
			_tips.remove_at(0)
	_draw()


func _draw() -> void:
	_im.clear_surfaces()
	var n := _ages.size()
	if n < 2:
		return
	var col := base_color if force_color.a <= 0.0 else force_color
	# Body: solid toward the tip and the newest sample, fading toward the blade root and tail.
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in n:
		var k := _fade(i, n)
		_im.surface_set_color(Color(col.r, col.g, col.b, 0.0))
		_im.surface_add_vertex(_bases[i])
		_im.surface_set_color(Color(col.r, col.g, col.b, col.a * k * 0.55))
		_im.surface_add_vertex(_tips[i])
	_im.surface_end()
	# Edge glint: a thin, near-white band along the tip path.
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var hot := col.lerp(Color(1, 1, 1, col.a), 0.6)
	for i in n:
		var k := _fade(i, n)
		var inner_pt := _tips[i].lerp(_bases[i], 0.1)
		_im.surface_set_color(Color(hot.r, hot.g, hot.b, 0.0))
		_im.surface_add_vertex(inner_pt)
		_im.surface_set_color(Color(hot.r, hot.g, hot.b, minf(1.0, hot.a * k * 1.1)))
		_im.surface_add_vertex(_tips[i])
	_im.surface_end()


func _fade(i: int, n: int) -> float:
	var age := 1.0 - clampf(_ages[i] / life, 0.0, 1.0)
	var along := float(i) / float(n - 1)
	return age * age * along * along
