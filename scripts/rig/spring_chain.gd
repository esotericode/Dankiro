class_name SpringChain
extends MeshInstance3D
## Cloth and hair for secondary motion: scarves, sashes, hair, tassels. A chain of points hanging
## from an anchor on a joint, simulated and drawn in world space (top_level).
##
## Position-based dynamics in physical units, so it sways like cloth rather than buzzing:
## - gravity;
## - drag against the air, strong across a ribbon's face (or across a strand of hair) and light
##   edge-on, which is what keeps real cloth from whipping about: it trails, slides and ripples;
## - a soft spring toward its rest shape, each point toward its place on it (as spring bones follow
##   a pose), with a natural frequency and a damping ratio;
## - a breeze whose direction wanders slowly (the same air for every chain), with a flutter that
##   runs down the ribbon as a wave, stronger the faster the air flows over it;
## - sphere colliders, and a cap on how fast any point may move relative to the anchor.
## `delta` carries the game's time scale, so hit-stop freezes it and slow motion slows it.

const MAX_STEP := 1.0 / 120.0         ## longest simulation step (longer ticks are split)
const ITERATIONS := 2                 ## constraint passes per step
const SMOOTH := 2                     ## drawn points per segment (a Catmull-Rom curve through them)
const WAVE := 5.0                     ## flutter phase lag from root to tip (radians): the wave runs down

var anchor: Node3D
var anchor_offset := Vector3.ZERO     ## in anchor space
var rest_dir := Vector3.DOWN          ## in anchor space: direction the ribbon hangs at rest
var side_axis := Vector3.RIGHT        ## in anchor space: ribbon width direction
var segments := 8
var seg_len := 0.07
var width_start := 0.08
var width_end := 0.04
var gravity := 6.0                    ## m/s²
var sway_hz := 1.2                    ## natural frequency of the pull toward the rest shape
var sway_damping := 0.4               ## its damping ratio: 0 rings on, 1 settles without overshoot
var air_drag := 8.0                   ## 1/s: drag across the face (a strand: across it), damping flaps
var edge_drag := 1.2                  ## 1/s: drag edge-on and along it: how it trails as the body moves
var strand := false                   ## hair: drag across the strand every way round, not just face-on
var breeze := 0.6                     ## m/s: the wind at rest
var flutter := 1.0                    ## flutter strength (m/s² per m/s of air across it, easing off in a gale)
var flutter_hz := 2.0                 ## flutter frequency in a light breeze (keep it well above sway_hz,
                                      ## or the two resonate); it quickens a little in a strong flow
var max_speed := 5.0                  ## m/s: no point moves faster than this relative to the anchor
var colliders: Array = []             ## Array of [Node3D, radius, offset(Vector3)] spheres
var color := Color.WHITE

var _pts := PackedVector3Array()
var _prev := PackedVector3Array()
var _vel := PackedVector3Array()
var _root_prev := Vector3.ZERO
var _rest_prev := Vector3.DOWN
var _phase := 0.0
var _flow := 0.0                      ## smoothed airflow across the tip (m/s): sets the flutter's pace
var _im: ImmediateMesh
var _initialized := false


func setup(p_anchor: Node3D, material: Material) -> void:
	anchor = p_anchor
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_im = ImmediateMesh.new()
	mesh = _im
	material_override = material
	_phase = randf() * TAU


func _ready() -> void:
	global_transform = Transform3D.IDENTITY


func reset_chain() -> void:
	_initialized = false


func _init_points(axf: Transform3D) -> void:
	_pts.resize(segments + 1)
	_prev.resize(segments + 1)
	_vel.resize(segments + 1)
	var root := axf * anchor_offset
	var dir := (axf.basis * rest_dir).normalized()
	for i in segments + 1:
		_pts[i] = root + dir * seg_len * float(i)
		_prev[i] = _pts[i]
		_vel[i] = Vector3.ZERO
	_root_prev = root
	_rest_prev = dir
	_initialized = true


## The air everywhere: a breeze whose direction and strength wander slowly (per metre per
## second of `breeze`), shared by every chain so they all blow the same way.
static func air_at(t: float) -> Vector3:
	var a := 0.7 + 0.5 * sin(t * 0.11) + 0.25 * sin(t * 0.37 + 1.3)
	var s := 0.75 + 0.2 * sin(t * 0.23 + 0.4) + 0.05 * sin(t * 1.7)
	return Vector3(cos(a), 0.0, sin(a)) * s


func _physics_process(delta: float) -> void:
	if anchor == null or not is_instance_valid(anchor) or not anchor.is_inside_tree():
		return
	var axf := anchor.global_transform
	var root := axf * anchor_offset
	if not _initialized or root.distance_to(_root_prev) > 1.5:     # first tick, or a teleport
		_init_points(axf)
	global_transform = Transform3D.IDENTITY
	if delta > 0.0:
		var rest := (axf.basis * rest_dir).normalized()
		var side := (axf.basis * side_axis).normalized()
		var anchor_vel := (root - _root_prev) / delta
		var steps := maxi(1, ceili(delta / MAX_STEP - 0.001))
		var h := delta / float(steps)
		for s in steps:
			var f0 := float(s) / float(steps)
			var f1 := float(s + 1) / float(steps)
			_step(h, _root_prev.lerp(root, f0), _rest_prev.slerp(rest, f0), _root_prev.lerp(root, f1),
				_rest_prev.slerp(rest, f1), side, anchor_vel)
		_root_prev = root
		_rest_prev = rest
	_draw_ribbon(axf)


## One step of `h` seconds, the root and rest direction going from (root0, rest0) to (root, rest).
func _step(h: float, root0: Vector3, rest0: Vector3, root: Vector3, rest: Vector3, side: Vector3,
		anchor_vel: Vector3) -> void:
	var air := SpringChain.air_at(Game.clock) * breeze
	var k := pow(TAU * sway_hz, 2.0)
	var bend := k * h * h / (1.0 + k * h * h)                 # XPBD: a spring of stiffness k
	var damp := 1.0 - exp(-2.0 * sway_damping * TAU * sway_hz * h)
	var drag := exp(-air_drag * h)
	var edge := exp(-edge_drag * h)
	# The flutter's pace follows the air over the tip (smoothed, so it never jumps), quickening a
	# little in a strong flow.
	_flow = lerpf(_flow, clampf(_flow_at(segments, air), 0.0, 8.0), 1.0 - exp(-3.0 * h))
	_phase = fmod(_phase + TAU * flutter_hz * minf(0.9 + 0.06 * _flow, 1.2) * h, TAU * 64.0)
	_pts[0] = root
	_prev[0] = root
	_vel[0] = anchor_vel
	for i in range(1, segments + 1):
		var v := _vel[i]
		v.y -= gravity * h
		var along := (_pts[i] - _pts[i - 1]).normalized()
		var nrm := side.cross(along)
		# Drag: the part of the motion through the air across the face (or across the strand)
		# fades fast, the rest slowly.
		var rel := v - air
		var across := rel - along * rel.dot(along)
		if not strand and nrm.length_squared() > 1e-6:
			var n := nrm.normalized()
			across = n * rel.dot(n)
		v = air + across * drag + (rel - across) * edge
		# Flutter: across the ribbon's face, a wave running from the root to the tip, growing
		# toward the tip and with the air flowing across it.
		if nrm.length_squared() > 1e-6:
			var u := float(i) / float(segments)
			var flow := _flow_at(i, air)
			var push := flutter * flow / (1.0 + 0.35 * flow) * u * sin(_phase - WAVE * u)
			v += nrm.normalized() * push * h
		_prev[i] = _pts[i]
		_pts[i] += v * h
	# The pull toward the rest shape: each point toward its place on it, measured from the root.
	# (Pulling each point toward its parent + rest instead pushes the chain without pushing back,
	# which feeds a towed ribbon energy until it snakes from side to side.)
	for i in range(1, segments + 1):
		_pts[i] += (root + rest * (seg_len * float(i)) - _pts[i]) * bend
	# Constraints: each segment keeps its length (the root doesn't move), and nothing goes inside
	# a collider. A root that starts inside one (a knot on the collar) shrinks that sphere for
	# this chain, or the two constraints would fight and shake the ribbon.
	for _iter in ITERATIONS:
		for i in range(1, segments + 1):
			var a := _pts[i - 1]
			var d := _pts[i] - a
			var l := d.length()
			if l > 1e-6:
				_pts[i] = a + d * (seg_len / l)
			for c in colliders:
				var cn: Node3D = c[0]
				if not is_instance_valid(cn):
					continue
				var cc := cn.global_transform * (c[2] as Vector3)
				var cr := minf(float(c[1]), root.distance_to(cc) - 0.002)
				var off := _pts[i] - cc
				var ol := off.length()
				if ol < cr and ol > 1e-5:
					_pts[i] = cc + off * (cr / ol)
	# Velocities from the moves; the sway's damping works on how each point moves relative to its
	# place on the rest shape, which moves with the anchor. Capped relative to the anchor.
	for i in range(1, segments + 1):
		var v := (_pts[i] - _prev[i]) / h
		var pose_vel := (root - root0 + (rest - rest0) * (seg_len * float(i))) / h
		v -= (v - pose_vel) * damp
		var rel := v - anchor_vel
		var rl := rel.length()
		if rl > max_speed:
			v = anchor_vel + rel * (max_speed / rl)
		_vel[i] = v


## How fast the air flows across the ribbon at point `i` (m/s): the air relative to the point,
## less the part along the ribbon.
func _flow_at(i: int, air: Vector3) -> float:
	var flow := air - _vel[i]
	var along := _pts[i] - _pts[maxi(0, i - 1)]
	if along.length_squared() > 1e-8:
		along = along.normalized()
		flow -= along * flow.dot(along)
	return flow.length()


func _draw_ribbon(axf: Transform3D) -> void:
	_im.clear_surfaces()
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var side_ref := (axf.basis * side_axis).normalized()
	var n := segments * SMOOTH
	var pts := PackedVector3Array()
	pts.resize(n + 1)
	for j in n + 1:
		var s := float(j) / float(SMOOTH)
		var i := mini(int(s), segments - 1)
		var f := s - float(i)
		var p0 := _pts[maxi(i - 1, 0)]
		var p1 := _pts[i]
		var p2 := _pts[i + 1]
		var p3 := _pts[mini(i + 2, segments)]
		pts[j] = 0.5 * (2.0 * p1 + (p2 - p0) * f + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * f * f
			+ (3.0 * p1 - p0 - 3.0 * p2 + p3) * f * f * f)
	for j in n + 1:
		var dir: Vector3
		if j < n:
			dir = (pts[j + 1] - pts[j]).normalized()
		else:
			dir = (pts[j] - pts[j - 1]).normalized()
		var side := side_ref - dir * side_ref.dot(dir)
		if side.length() < 1e-4:
			side = dir.cross(Vector3.UP)
		side = side.normalized()
		var u := float(j) / float(n)
		var w := lerpf(width_start, width_end, u) * 0.5
		var nrm := side.cross(dir).normalized()
		_im.surface_set_normal(nrm)
		_im.surface_set_color(color)
		_im.surface_set_uv(Vector2(0.0, u))
		_im.surface_add_vertex(pts[j] + side * w)
		_im.surface_set_normal(nrm)
		_im.surface_set_color(color)
		_im.surface_set_uv(Vector2(1.0, u))
		_im.surface_add_vertex(pts[j] - side * w)
	_im.surface_end()
