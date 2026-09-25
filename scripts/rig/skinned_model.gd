class_name SkinnedModel
extends RefCounted
## A skinned model (.glb made by tools/build_boss_model.py) driven by a HumanoidRig.
## The glb's skeleton has one bone per rig joint, bound in the rig's rest pose. After each
## HumanoidRig.apply_pose, every bone is moved so that its skin follows the rig joint exactly:
##   bone global pose = S^-1 * M_joint * B_joint^-1 * S * R_bone
## with M the joint's solved transform, B its rest transform (both in rig space), R the bone's
## global rest in the skeleton and S the skeleton's transform in rig space. So the bone
## orientations Blender exported don't matter.

var root: Node3D
var skeleton: Skeleton3D
var _map: Array = []          ## [bone index, joint or helper name, parent bone index (-1 = none)] in bone order
var _rest_fix: Dictionary = {} ## bone index -> B_joint^-1 * S * R_bone (constant)
var _s_inv := Transform3D.IDENTITY
var _globals: Array = []
## Helper bones (armour hanging between two joints, see tools/model3d/boss_spec.py):
## name -> [joint a, joint b, t, pivot rest position, rest position of a]
var _helpers: Dictionary = {}


## Instances `scene` under `rig` and binds its skeleton to the rig's joints.
## Returns null if the scene has no Skeleton3D.
static func attach(rig: HumanoidRig, scene: PackedScene, helpers: Dictionary = {}) -> SkinnedModel:
	var inst := scene.instantiate() as Node3D
	var sk: Skeleton3D = null
	for n in inst.find_children("*", "Skeleton3D", true, false):
		sk = n
		break
	if sk == null:
		inst.queue_free()
		return null
	var m := SkinnedModel.new()
	m.root = inst
	m.skeleton = sk
	rig.add_child(inst)
	m._bind(rig, helpers)
	rig.skins.append(m)
	return m


func _bind(rig: HumanoidRig, helpers: Dictionary) -> void:
	# Skeleton transform relative to the rig (the glb is exported in game space, so this is
	# normally identity, but don't rely on it).
	var s := Transform3D.IDENTITY
	var n: Node = skeleton
	while n != null and n != rig:
		if n is Node3D:
			s = (n as Node3D).transform * s
		n = n.get_parent()
	_s_inv = s.affine_inverse()
	var rest_pos := HumanoidRig.rest_joint_positions(rig.rig)
	for hname in helpers:
		var hd: Dictionary = helpers[hname]
		var pv: Array = hd["pivot"]
		var pivot := Vector3(float(pv[0]), float(pv[1]), float(pv[2]))
		_helpers[hname] = [str(hd["a"]), str(hd["b"]), float(hd["t"]), pivot, rest_pos[str(hd["a"])]]
		rest_pos[hname] = pivot
	_globals.resize(skeleton.get_bone_count())
	for b in skeleton.get_bone_count():
		var jname := skeleton.get_bone_name(b)
		if not rig.joints.has(jname) and not _helpers.has(jname):
			continue
		var b_inv := Transform3D(Basis(), -(rest_pos[jname] as Vector3))
		_rest_fix[b] = b_inv * s * skeleton.get_bone_global_rest(b)
		_map.append([b, jname, skeleton.get_bone_parent(b)])


## Copies the rig's current joint transforms onto the skeleton.
func sync(rig: HumanoidRig) -> void:
	for e in _map:
		var b: int = e[0]
		var mj: Transform3D
		if _helpers.has(e[1]):
			var h: Array = _helpers[e[1]]
			var ma: Transform3D = rig.model_xf.get(h[0], Transform3D.IDENTITY)
			var mb: Transform3D = rig.model_xf.get(h[1], Transform3D.IDENTITY)
			var q := ma.basis.get_rotation_quaternion().slerp(mb.basis.get_rotation_quaternion(), float(h[2]))
			mj = Transform3D(Basis(q), ma * ((h[3] as Vector3) - (h[4] as Vector3)))
		else:
			mj = rig.model_xf.get(e[1], Transform3D.IDENTITY)
		var g: Transform3D = _s_inv * mj * (_rest_fix[b] as Transform3D)
		_globals[b] = g
		var parent: int = e[2]
		var local := g
		if parent >= 0 and _globals[parent] != null:
			local = (_globals[parent] as Transform3D).affine_inverse() * g
		skeleton.set_bone_pose_position(b, local.origin)
		skeleton.set_bone_pose_rotation(b, local.basis.get_rotation_quaternion())


## Every MeshInstance3D in the model.
func meshes() -> Array:
	return root.find_children("*", "MeshInstance3D", true, false)
