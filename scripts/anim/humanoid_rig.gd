class_name HumanoidRig
extends Node3D
## Joint hierarchy driven by pose dictionaries (see ClipData.sample).
## Legs and arms are solved with two-bone IK in model space (this node's space);
## the weapon is animated directly and the hands grip it.
## Mirrors tools/rigmath.py `solve`.

var rig_name: String = ""
var rig: Dictionary = {}
var weapon_def: Dictionary = {}
var joints: Dictionary = {}          ## name -> Node3D
var offsets: Dictionary = {}         ## name -> Vector3
var parents: Dictionary = {}         ## name -> parent joint name
var model_xf: Dictionary = {}        ## name -> Transform3D in model space (after last apply)
var weapon_node: Node3D
var weapon_model_xf := Transform3D.IDENTITY
var grip_axis := Vector3.UP
var blades: Dictionary = {}          ## blade name -> PackedVector3Array (weapon space)
## Hit windows test every polyline of the weapon, not only the named blade (staffs).
var hit_whole_weapon := false

var l_upper := 0.28
var l_fore := 0.25
var l_thigh := 0.42
var l_shin := 0.41
var wrist_offset := 0.035
## Extra weapon offset in model space, used for recoil kicks.
var weapon_kick_pos := Vector3.ZERO
var weapon_kick_rot := Quaternion.IDENTITY
var chest_kick := Quaternion.IDENTITY
## Skinned models (SkinnedModel) that follow the joints; synced after every apply_pose.
var skins: Array = []


func setup(p_rig_name: String) -> void:
	AnimLibrary.ensure_loaded()
	rig_name = p_rig_name
	rig = AnimLibrary.get_rig(rig_name)
	weapon_def = AnimLibrary.get_weapon(str(rig.get("weapon", "")))
	for j in rig.get("joints", []):
		var jd: Dictionary = j
		var jname := str(jd["name"])
		var o: Array = jd["offset"]
		offsets[jname] = Vector3(float(o[0]), float(o[1]), float(o[2]))
		parents[jname] = str(jd["parent"])
		var node := Node3D.new()
		node.name = jname
		joints[jname] = node
		var parent_name := str(jd["parent"])
		if parent_name == "":
			add_child(node)
		else:
			(joints[parent_name] as Node3D).add_child(node)
		node.position = offsets[jname]
	weapon_node = Node3D.new()
	weapon_node.name = "weapon"
	add_child(weapon_node)
	var ga: Array = weapon_def.get("grip_axis", [0.0, 1.0, 0.0])
	grip_axis = Vector3(float(ga[0]), float(ga[1]), float(ga[2])).normalized()
	hit_whole_weapon = bool(weapon_def.get("hit_whole_weapon", false))
	var bd: Dictionary = weapon_def.get("blades", {})
	for bname in bd:
		var pts := PackedVector3Array()
		for p in bd[bname]:
			var pa: Array = p
			pts.append(Vector3(float(pa[0]), float(pa[1]), float(pa[2])))
		blades[bname] = pts
	l_upper = absf((offsets["forearm_l"] as Vector3).y)
	l_fore = absf((offsets["hand_l"] as Vector3).y)
	l_thigh = absf((offsets["shin_l"] as Vector3).y)
	l_shin = absf((offsets["foot_l"] as Vector3).y)
	wrist_offset = 0.04 if rig_name == "boss" else 0.035


func joint(jname: String) -> Node3D:
	return joints.get(jname) as Node3D


## Joint name -> rest position in model space (identity rotations, hips at hips_height).
static func rest_joint_positions(rig_def: Dictionary) -> Dictionary:
	var out := {}
	for j in rig_def.get("joints", []):
		var jd: Dictionary = j
		var o: Array = jd["offset"]
		var off := Vector3(float(o[0]), float(o[1]), float(o[2]))
		var parent := str(jd["parent"])
		if parent == "":
			out[str(jd["name"])] = Vector3(0.0, float(rig_def.get("hips_height", 1.0)), 0.0) + off
		else:
			out[str(jd["name"])] = (out[parent] as Vector3) + off
	return out


## Applies a sampled/blended pose. Everything is solved in this node's local space.
func apply_pose(p: Dictionary) -> void:
	# Visual spin (e.g. the 360 degree sweep). Root motion is consumed by the character, not here.
	rotation = Vector3(0.0, deg_to_rad(float(p["yaw"])), 0.0)
	var hips_p: Vector3 = p["hips_pos"]
	var hips_b := Basis(p["hips"] as Quaternion)
	_set_model("hips", Transform3D(hips_b, hips_p))
	(joints["hips"] as Node3D).transform = Transform3D(hips_b, hips_p)
	for jname in ["spine", "chest", "neck", "head"]:
		var parent_xf: Transform3D = model_xf[parents[jname]]
		var q: Quaternion = p[jname]
		var local_b := Basis(q)
		if jname == "chest":
			local_b = local_b * Basis(chest_kick)
		var local := Transform3D(local_b, offsets[jname])
		(joints[jname] as Node3D).transform = local
		_set_model(jname, parent_xf * local)

	# Legs
	var hips_xf: Transform3D = model_xf["hips"]
	for s in ["l", "r"]:
		var th_name: String = "thigh_" + s
		var sh_name: String = "shin_" + s
		var ft_name: String = "foot_" + s
		var th_pos: Vector3 = hips_xf * (offsets[th_name] as Vector3)
		var ankle: Vector3 = p[ft_name]
		var foot_q: Quaternion = p[ft_name + "_rot"]
		var foot_b := Basis(foot_q)
		var knee_hint: Vector3 = p["knee_" + s]
		var foot_yaw := foot_b.get_euler().y
		var pole := Basis(Vector3.UP, foot_yaw) * knee_hint.normalized()
		var sol := PoseMath.two_bone(th_pos, ankle, l_thigh, l_shin, pole)
		var mid: Vector3 = sol[0]
		var end: Vector3 = sol[1]
		var hinge: Vector3 = sol[2]
		var th_b := PoseMath.bone_basis(mid - th_pos, hinge)
		var sh_b := PoseMath.bone_basis(end - mid, hinge)
		(joints[th_name] as Node3D).transform = Transform3D(hips_b.inverse() * th_b, offsets[th_name])
		(joints[sh_name] as Node3D).transform = Transform3D(th_b.inverse() * sh_b, offsets[sh_name])
		(joints[ft_name] as Node3D).transform = Transform3D(sh_b.inverse() * foot_b, offsets[ft_name])
		_set_model(th_name, Transform3D(th_b, th_pos))
		_set_model(sh_name, Transform3D(sh_b, mid))
		_set_model(ft_name, Transform3D(foot_b, end))

	# Weapon
	var wq: Quaternion = p["weapon_rot"]
	var wp: Vector3 = p["weapon_pos"]
	weapon_model_xf = Transform3D(Basis(weapon_kick_rot * wq), wp + weapon_kick_pos)
	weapon_node.transform = weapon_model_xf

	# Arms
	var chest_xf: Transform3D = model_xf["chest"]
	for s in ["l", "r"]:
		var ua: String = "upper_arm_" + s
		var fa: String = "forearm_" + s
		var hd: String = "hand_" + s
		var sh_pos: Vector3 = chest_xf * (offsets[ua] as Vector3)
		var w := clampf(float(p["ik_" + s]), 0.0, 1.0)
		var ua_q: Quaternion = p[ua]
		var fa_q: Quaternion = p[fa]
		var bu_fk := chest_xf.basis * Basis(ua_q)
		var bf_fk := bu_fk * Basis(fa_q)
		var bu := bu_fk
		var bf := bf_fk
		if w > 0.0:
			var grip: Vector3 = weapon_model_xf * (grip_axis * float(p["grip_" + s]))
			var wrist_t := grip - (grip - sh_pos).normalized() * wrist_offset
			var elbow_hint: Vector3 = p["elbow_" + s]
			var pole := chest_xf.basis * elbow_hint.normalized()
			var sol := PoseMath.two_bone(sh_pos, wrist_t, l_upper, l_fore, pole)
			var mid: Vector3 = sol[0]
			var end: Vector3 = sol[1]
			var hinge: Vector3 = sol[2]
			var bu_ik := PoseMath.bone_basis(mid - sh_pos, -hinge)
			var bf_ik := PoseMath.bone_basis(end - mid, -hinge)
			if w >= 1.0:
				bu = bu_ik
				bf = bf_ik
			else:
				bu = bu_fk.slerp(bu_ik, w)
				var lf := (bu_fk.inverse() * bf_fk).slerp(bu_ik.inverse() * bf_ik, w)
				bf = bu * lf
		(joints[ua] as Node3D).transform = Transform3D(chest_xf.basis.inverse() * bu, offsets[ua])
		(joints[fa] as Node3D).transform = Transform3D(bu.inverse() * bf, offsets[fa])
		var hand_q: Quaternion = p[hd]
		(joints[hd] as Node3D).transform = Transform3D(Basis(hand_q), offsets[hd])
		_set_model(ua, Transform3D(bu, sh_pos))
		var fa_pos: Vector3 = sh_pos + bu * (offsets[fa] as Vector3)
		_set_model(fa, Transform3D(bf, fa_pos))
		_set_model(hd, Transform3D(bf * Basis(hand_q), fa_pos + bf * (offsets[hd] as Vector3)))
	for s in skins:
		(s as SkinnedModel).sync(self)


func _set_model(jname: String, xf: Transform3D) -> void:
	model_xf[jname] = xf


## World-space points of a blade polyline (base -> tip) using the last applied pose.
func blade_world(blade_name: String) -> PackedVector3Array:
	var out := PackedVector3Array()
	if not blades.has(blade_name):
		return out
	var xf := global_transform * weapon_model_xf
	for pt in blades[blade_name]:
		out.append(xf * (pt as Vector3))
	return out


func joint_world(jname: String) -> Vector3:
	if not model_xf.has(jname):
		return global_position
	return global_transform * (model_xf[jname] as Transform3D).origin


func joint_world_xf(jname: String) -> Transform3D:
	if not model_xf.has(jname):
		return global_transform
	return global_transform * (model_xf[jname] as Transform3D)


func weapon_world_xf() -> Transform3D:
	return global_transform * weapon_model_xf
