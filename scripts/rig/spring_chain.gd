class_name SpringChain
extends MeshInstance3D
## Verlet ribbon for secondary motion: scarves, sashes, hair, tassels.
## Simulated and drawn in world space (top_level) from an anchor on a joint.

var anchor: Node3D
var anchor_offset := Vector3.ZERO     ## in anchor space
var rest_dir := Vector3.DOWN          ## in anchor space: direction the ribbon hangs at rest
var side_axis := Vector3.RIGHT        ## in anchor space: ribbon width direction
var segments := 8
var seg_len := 0.07
var width_start := 0.08
var width_end := 0.04
var stiffness := 0.08                 ## pull toward the rest shape (0..1 per tick)
var damping := 0.94
var gravity := 5.0
var wind_strength := 0.6
var drag := 0.0                       ## extra pull opposite to anchor velocity
var colliders: Array = []             ## Array of [Node3D, radius, offset(Vector3)] spheres
var color := Color.WHITE

var _pts := PackedVector3Array()
var _prev := PackedVector3Array()
var _im: ImmediateMesh
var _t := 0.0
var _seed := 0.0
var _initialized := false


func setup(p_anchor: Node3D, material: Material) -> void:
	anchor = p_anchor
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_im = ImmediateMesh.new()
	mesh = _im
	material_override = material
	_seed = randf() * 100.0


func _ready() -> void:
	global_transform = Transform3D.IDENTITY


func reset_chain() -> void:
	_initialized = false


func _init_points() -> void:
	_pts.resize(segments + 1)
	_prev.resize(segments + 1)
	var axf := anchor.global_transform
	var root := axf * anchor_offset
	var dir := (axf.basis * rest_dir).normalized()
	for i in segments + 1:
		_pts[i] = root + dir * seg_len * float(i)
		_prev[i] = _pts[i]
	_initialized = true


func _physics_process(delta: float) -> void:
	if anchor == null or not is_instance_valid(anchor) or not anchor.is_inside_tree():
		return
	if not _initialized:
		_init_points()
	global_transform = Transform3D.IDENTITY
	_t += delta
	var axf := anchor.global_transform
	var root := axf * anchor_offset
	var rest := (axf.basis * rest_dir).normalized()
	var wind := Vector3(sin(_t * 1.3 + _seed) + 0.4 * sin(_t * 3.1 + _seed * 2.0), 0.0,
		cos(_t * 0.9 + _seed) * 0.6) * wind_strength
	var dt2 := delta * delta
	_pts[0] = root
	_prev[0] = root
	for i in range(1, segments + 1):
		var p := _pts[i]
		var v := (p - _prev[i]) * damping
		_prev[i] = p
		var acc := Vector3(0, -gravity, 0) + wind * (float(i) / float(segments))
		_pts[i] = p + v + acc * dt2
	# Constraints: segment length + gentle pull toward the rest shape.
	for _iter in 3:
		for i in range(1, segments + 1):
			var a := _pts[i - 1]
			var target_rest := a + rest * seg_len
			_pts[i] = _pts[i].lerp(target_rest, stiffness)
			var d := _pts[i] - a
			var l := d.length()
			if l > 1e-5:
				_pts[i] = a + d * (seg_len / l)
			for c in colliders:
				var cn: Node3D = c[0]
				if not is_instance_valid(cn):
					continue
				var cr: float = c[1]
				var co: Vector3 = c[2]
				var cc := cn.global_transform * co
				var off := _pts[i] - cc
				var ol := off.length()
				if ol < cr and ol > 1e-5:
					_pts[i] = cc + off * (cr / ol)
	_draw_ribbon(axf)


func _draw_ribbon(axf: Transform3D) -> void:
	_im.clear_surfaces()
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var side_ref := (axf.basis * side_axis).normalized()
	for i in segments + 1:
		var dir: Vector3
		if i < segments:
			dir = (_pts[i + 1] - _pts[i]).normalized()
		else:
			dir = (_pts[i] - _pts[i - 1]).normalized()
		var side := side_ref - dir * side_ref.dot(dir)
		if side.length() < 1e-4:
			side = dir.cross(Vector3.UP)
		side = side.normalized()
		var w := lerpf(width_start, width_end, float(i) / float(segments)) * 0.5
		var nrm := side.cross(dir).normalized()
		var v := float(i) / float(segments)
		_im.surface_set_normal(nrm)
		_im.surface_set_color(color)
		_im.surface_set_uv(Vector2(0.0, v))
		_im.surface_add_vertex(_pts[i] + side * w)
		_im.surface_set_normal(nrm)
		_im.surface_set_color(color)
		_im.surface_set_uv(Vector2(1.0, v))
		_im.surface_add_vertex(_pts[i] - side * w)
	_im.surface_end()
