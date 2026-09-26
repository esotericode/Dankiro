class_name Shuriken
extends Node3D
## A thrown shuriken. It flies straight at where the target will be, spinning, and is resolved
## against the player exactly like a blade (deflect / block / hit, with the contact time found
## by a swept test so the deflect window is measured precisely). Deflected ones glance off,
## blocked ones drop, and ones that miss stick into the flagstones. Big, glinting and glowing,
## so you can track each one in the dark and time it as it lands.

const SPEED := 16.0
const GRAVITY := 16.0

var velocity := Vector3.ZERO
var thrower: Combatant
var target: Player
var info: Dictionary = {}

var _life := 0.0
var _flying := true
var _stuck := false
var _star: MeshInstance3D
var _glow: Sprite3D
var _spin := 0.0

static var _star_mesh: ArrayMesh
static var _metal: StandardMaterial3D


## Throws a shuriken from `from` toward `aim` (world space).
static func throw(parent: Node, from: Vector3, aim: Vector3, p_thrower: Combatant, p_target: Player,
		p_info: Dictionary) -> Shuriken:
	var s := Shuriken.new()
	s.thrower = p_thrower
	s.target = p_target
	s.info = p_info
	parent.add_child(s)
	s.global_position = from
	var dir := aim - from
	s.velocity = dir.normalized() * SPEED if dir.length() > 0.01 else Vector3.FORWARD * SPEED
	s._orient()
	return s


func _ready() -> void:
	if _star_mesh == null:
		_build_shared()
	_star = MeshInstance3D.new()
	_star.mesh = _star_mesh
	_star.material_override = _metal
	_star.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_star.layers = ModelBuilder.CHARACTER_LAYERS
	add_child(_star)
	_glow = Fx.glow_sprite(Fx.radial_texture("shuriken_glow", Color(1.0, 0.95, 0.85, 1.0), Color(1.0, 0.6, 0.25, 0.0)),
		Color(1.0, 0.86, 0.62, 0.8), 0.42)
	_glow.no_depth_test = false
	add_child(_glow)


static func _build_shared() -> void:
	# Four-pointed star, flat in the XZ plane, slightly thicker at the hub.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r_tip := 0.105
	var r_in := 0.03
	var th := 0.008
	var pts: Array[Vector3] = []
	for i in 8:
		var a := TAU * float(i) / 8.0
		var r := r_tip if i % 2 == 0 else r_in
		pts.append(Vector3(cos(a) * r, 0.0, sin(a) * r))
	var top := Vector3(0, th, 0)
	var bottom := Vector3(0, -th, 0)
	for i in 8:
		var a := pts[i]
		var b := pts[(i + 1) % 8]
		st.add_vertex(top)
		st.add_vertex(b)
		st.add_vertex(a)
		st.add_vertex(bottom)
		st.add_vertex(a)
		st.add_vertex(b)
	st.generate_normals()
	_star_mesh = st.commit()
	_metal = StandardMaterial3D.new()
	_metal.albedo_color = Color(0.72, 0.72, 0.76)
	_metal.metallic = 1.0
	_metal.roughness = 0.25
	_metal.emission_enabled = true
	_metal.emission = Color(1.0, 0.7, 0.4)       # a steel glint so they read at night
	_metal.emission_energy_multiplier = 2.2
	_metal.cull_mode = BaseMaterial3D.CULL_DISABLED


func _orient() -> void:
	if velocity.length() > 0.01:
		var up := Vector3.UP if absf(velocity.normalized().y) < 0.95 else Vector3.RIGHT
		global_basis = Basis.looking_at(velocity.normalized(), up)


func _physics_process(delta: float) -> void:
	_life += delta
	if _life > 3.0:
		queue_free()
		return
	if _stuck:
		if _life > 1.6:
			var k := clampf((2.2 - _life) / 0.6, 0.0, 1.0)
			scale = Vector3.ONE * maxf(0.01, k)
		return
	var prev := global_position
	if not _flying:
		velocity.y -= GRAVITY * delta
	global_position += velocity * delta
	_spin += delta * (38.0 if _flying else 20.0)
	_orient()
	if _star:
		_star.rotation = Vector3(0.0, _spin, 0.0)
	if _flying and target != null and is_instance_valid(target) and target.can_be_hit():
		_sweep_against_target(prev, global_position)
	if global_position.y <= 0.03:
		global_position.y = 0.03
		_stick()


## Swept point-vs-capsule test between last tick and now; on contact the player resolves it.
func _sweep_against_target(prev: Vector3, now: Vector3) -> void:
	var cap := target.hurt_capsule()
	for s in range(1, 9):
		var f := float(s) / 8.0
		var p := prev.lerp(now, f)
		if not Combat.point_vs_capsule(p, cap[0], cap[1], float(cap[2]) + 0.05):
			continue
		var hit := info.duplicate()
		hit["point"] = p
		hit["time"] = Game.clock - Game.tick_delta * (1.0 - f)
		var res := target.receive_attack(hit, thrower)
		match res:
			Combat.RESULT_DEFLECT:
				_glance(p, 8.0)
			Combat.RESULT_BLOCK:
				_glance(p, 3.0)
			Combat.RESULT_HIT:
				queue_free()
			_:
				_flying = false     # dodged through it: let it sail past and fall
				velocity *= 0.8
		return


func _glance(p: Vector3, speed: float) -> void:
	_flying = false
	global_position = p
	var away := -velocity.normalized()
	var side := away.cross(Vector3.UP).normalized() * randf_range(-0.8, 0.8)
	velocity = (away + side + Vector3.UP * 0.9).normalized() * speed
	if _glow:
		_glow.visible = false


func _stick() -> void:
	_stuck = true
	_flying = false
	velocity = Vector3.ZERO
	if _glow:
		_glow.visible = false
	_life = maxf(_life, 1.0)
