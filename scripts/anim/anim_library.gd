class_name AnimLibrary
extends RefCounted
## Loads data/rigs.json and data/animations.json once and caches clips per rig.

const RIGS_PATH := "res://data/rigs.json"
const ANIMS_PATH := "res://data/animations.json"

static var _loaded := false
static var rigs: Dictionary = {}
static var weapons: Dictionary = {}
static var poses: Dictionary = {}
static var clips: Dictionary = {}


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var rig_json := _read_json(RIGS_PATH)
	rigs = rig_json.get("rigs", {})
	weapons = rig_json.get("weapons", {})
	var anim_json := _read_json(ANIMS_PATH)
	poses = anim_json.get("poses", {})
	var raw_clips: Dictionary = anim_json.get("clips", {})
	for cname in raw_clips:
		var cd: Dictionary = raw_clips[cname]
		var rig_name := str(cd.get("rig", ""))
		if not rigs.has(rig_name):
			push_error("Clip %s references unknown rig %s" % [cname, rig_name])
			continue
		var clip := ClipData.new()
		clip.build(str(cname), cd, rig_defaults(rig_name), poses)
		clips[cname] = clip


static func get_clip(clip_name: String) -> ClipData:
	ensure_loaded()
	if not clips.has(clip_name):
		push_error("Missing animation clip '%s'" % clip_name)
		return null
	return clips[clip_name]


static func has_clip(clip_name: String) -> bool:
	ensure_loaded()
	return clips.has(clip_name)


static func get_rig(rig_name: String) -> Dictionary:
	ensure_loaded()
	return rigs.get(rig_name, {})


static func get_weapon(weapon_name: String) -> Dictionary:
	ensure_loaded()
	return weapons.get(weapon_name, {})


static func joint_offset(rig: Dictionary, joint: String) -> Vector3:
	for j in rig.get("joints", []):
		var jd: Dictionary = j
		if str(jd["name"]) == joint:
			var o: Array = jd["offset"]
			return Vector3(float(o[0]), float(o[1]), float(o[2]))
	return Vector3.ZERO


## Default value for every channel (mirrors rigmath.Rig.defaults).
static func rig_defaults(rig_name: String) -> Dictionary:
	var rig: Dictionary = rigs[rig_name]
	var weapon: Dictionary = weapons.get(str(rig.get("weapon", "")), {})
	var hips_h := float(rig.get("hips_height", 1.0))
	var th := joint_offset(rig, "thigh_l")
	var l_thigh := absf(joint_offset(rig, "shin_l").y)
	var l_shin := absf(joint_offset(rig, "foot_l").y)
	var ankle_h := hips_h + th.y - (l_thigh + l_shin)
	var d := {
		"root": [0.0, 0.0, 0.0], "yaw": 0.0,
		"hips_pos": [0.0, hips_h, 0.0],
		"foot_l": [th.x, ankle_h, 0.0], "foot_r": [-th.x, ankle_h, 0.0],
		"knee_l": [-0.2, 0.0, -1.0], "knee_r": [0.2, 0.0, -1.0],
		"elbow_l": [-0.35, -1.0, 0.35], "elbow_r": [0.35, -1.0, 0.35],
		"weapon_pos": [0.25, 0.9, -0.3],
		"ik_l": 1.0, "ik_r": 1.0,
		"grip_l": float(weapon.get("grip_l", 0.0)), "grip_r": float(weapon.get("grip_r", 0.0)),
	}
	for ch in PoseMath.CHANNELS:
		if not d.has(ch):
			d[ch] = [0.0, 0.0, 0.0]
	return d


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("Missing data file %s" % path)
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Could not parse %s" % path)
		return {}
	return parsed
