class_name WeaponTrail
extends MeshInstance3D
## Swing trail: a fading ribbon between a blade's base and tip, drawn in world space.
## Samples are pushed only while the tip moves fast, so trails appear on strikes and
## vanish on idle motion. `force_color` tints perilous attacks red.

var source: HumanoidRig
var blade_name := "blade"
var max_samples := 14
var min_speed := 4.5          ## m/s of the blade tip before the trail shows
var life := 0.16              ## seconds a sample lives
var base_color := Color(0.85, 0.9, 1.0, 0.55)
var force_color := Color(0, 0, 0, 0)

var _bases := PackedVector3Array()
var _tips := PackedVector3Array()
var _ages := PackedFloat32Array()
var _last_tip := Vector3.ZERO
var _has_last := false
var _im: ImmediateMesh


func setup(p_source: HumanoidRig, p_blade: String, color: Color) -> void:
	source = p_source
	blade_name = p_blade
	base_color = color
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_im = ImmediateMesh.new()
	mesh = _im
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = false
	material_override = m


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
		_bases.append(base.lerp(tip, 0.18))
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
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in n:
		var k := 1.0 - clampf(_ages[i] / life, 0.0, 1.0)
		var f := float(i) / float(n - 1)
		var a := col.a * k * k * f
		_im.surface_set_color(Color(col.r, col.g, col.b, a * 0.35))
		_im.surface_add_vertex(_bases[i])
		_im.surface_set_color(Color(col.r, col.g, col.b, a))
		_im.surface_add_vertex(_tips[i])
	_im.surface_end()
