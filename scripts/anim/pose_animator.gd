class_name PoseAnimator
extends RefCounted
## Plays ClipData on a HumanoidRig with crossfades, clip events, root motion,
## a locomotion blend space and an upper-body overlay layer.

signal event_fired(clip_name: String, ev: Dictionary)

var rig: HumanoidRig
var clip: ClipData = null
var time := 0.0
var speed := 1.0
var finished := false
## Root motion (facing space, meters) produced by the last update.
var root_delta := Vector3.ZERO
var last_pose: Dictionary = {}

var _from_pose: Dictionary = {}
var _blend_t := 0.0
var _blend_dur := 0.0
var _root_prev := Vector3.ZERO

# Locomotion
var loco_active := false
var loco_clips: Dictionary = {}     ## role -> ClipData ("idle", "fwd", "back", "left", "right", "run")
var loco_weights: Dictionary = {}   ## role -> target weight
var _loco_w: Dictionary = {}        ## role -> smoothed weight
var loco_phase := 0.0               ## cycles
var loco_cycle_rate := 0.0          ## cycles per second
var _idle_time := 0.0

# Upper-body overlay
var overlay_clip: ClipData = null
var overlay_time := 0.0
var overlay_target := 0.0
var overlay_weight := 0.0
var overlay_speed := 10.0

# Recoil spring (applied to weapon + chest)
var _kick_pos := Vector3.ZERO
var _kick_pos_v := Vector3.ZERO
var _kick_rot := Vector3.ZERO        ## axis-angle vector (radians)
var _kick_rot_v := Vector3.ZERO


func _init(p_rig: HumanoidRig) -> void:
	rig = p_rig


func current_name() -> String:
	return clip.name if clip != null and not loco_active else ""


func is_playing(clip_name: String) -> bool:
	return not loco_active and clip != null and clip.name == clip_name


## Starts an action clip, crossfading from the current pose.
func play(clip_name: String, blend := 0.12, p_speed := 1.0, start_time := 0.0) -> void:
	var c := AnimLibrary.get_clip(clip_name)
	if c == null:
		return
	_begin_blend(blend)
	loco_active = false
	clip = c
	speed = p_speed
	time = start_time
	finished = false
	var s := clip.sample(start_time)
	_root_prev = s["root"]
	_fire_events(start_time - 0.0001, start_time)


## Switches to the locomotion blend space.
func play_locomotion(clips_by_role: Dictionary, blend := 0.18) -> void:
	if loco_active and _same_loco(clips_by_role):
		return
	_begin_blend(blend)
	loco_active = true
	clip = null
	finished = false
	loco_clips.clear()
	for role in clips_by_role:
		var c := AnimLibrary.get_clip(str(clips_by_role[role]))
		if c != null:
			loco_clips[role] = c
	for role in loco_clips:
		if not _loco_w.has(role):
			_loco_w[role] = 1.0 if role == "idle" else 0.0


func _same_loco(clips_by_role: Dictionary) -> bool:
	if clips_by_role.size() != loco_clips.size():
		return false
	for role in clips_by_role:
		if not loco_clips.has(role) or (loco_clips[role] as ClipData).name != str(clips_by_role[role]):
			return false
	return true


func set_overlay(clip_name: String, weight: float, rate := 12.0) -> void:
	if clip_name == "":
		overlay_target = 0.0
		return
	if overlay_clip == null or overlay_clip.name != clip_name:
		overlay_clip = AnimLibrary.get_clip(clip_name)
		overlay_time = 0.0
	overlay_target = weight
	overlay_speed = rate


## Drops the overlay immediately (full-body actions; the crossfade snapshot hides the switch).
func clear_overlay() -> void:
	overlay_target = 0.0
	overlay_weight = 0.0


## Adds a recoil impulse: `pos` (model-space m/s) and `rot` (axis * rad/s).
func kick(pos_impulse: Vector3, rot_impulse: Vector3) -> void:
	_kick_pos_v += pos_impulse
	_kick_rot_v += rot_impulse


func _begin_blend(blend: float) -> void:
	if last_pose.is_empty() or blend <= 0.0:
		_blend_dur = 0.0
		_blend_t = 0.0
		return
	_from_pose = last_pose.duplicate()
	PoseMath.wrap_yaw(_from_pose)
	_blend_dur = blend
	_blend_t = 0.0


func update(delta: float) -> void:
	root_delta = Vector3.ZERO
	var pose: Dictionary
	if loco_active:
		pose = _eval_locomotion(delta)
	elif clip != null:
		var prev := time
		time += delta * speed
		if clip.loop and clip.length > 0.0:
			if time >= clip.length:
				_fire_events(prev, clip.length)
				var end_root: Vector3 = clip.sample(clip.length)["root"]
				var start_root: Vector3 = clip.sample(0.0)["root"]
				root_delta += end_root - _root_prev
				_root_prev = start_root
				time = fposmod(time, clip.length)
				prev = -0.0001
			pose = clip.sample(time)
		else:
			if time >= clip.length:
				time = clip.length
				finished = true
			pose = clip.sample(time)
		var r: Vector3 = pose["root"]
		root_delta += r - _root_prev
		_root_prev = r
		_fire_events(prev, time)
	else:
		return

	# Upper-body overlay
	overlay_weight = move_toward(overlay_weight, overlay_target, delta * overlay_speed)
	if overlay_clip != null and overlay_weight > 0.001:
		overlay_time += delta
		pose = PoseMath.blend(pose, overlay_clip.sample(overlay_time), overlay_weight, PoseMath.UPPER)

	# Crossfade from the previous pose
	if _blend_t < _blend_dur:
		_blend_t += delta
		var w := smoothstep(0.0, 1.0, clampf(_blend_t / _blend_dur, 0.0, 1.0))
		pose = PoseMath.blend(_from_pose, pose, w)

	_update_kick(delta)
	last_pose = pose
	rig.apply_pose(pose)


func _update_kick(delta: float) -> void:
	# Critically damped-ish springs back to rest.
	var k := 260.0
	var c := 26.0
	_kick_pos_v += (-_kick_pos * k - _kick_pos_v * c) * delta
	_kick_pos += _kick_pos_v * delta
	_kick_rot_v += (-_kick_rot * k - _kick_rot_v * c) * delta
	_kick_rot += _kick_rot_v * delta
	rig.weapon_kick_pos = _kick_pos
	var ang := _kick_rot.length()
	if ang > 1e-5:
		rig.weapon_kick_rot = Quaternion(_kick_rot / ang, ang)
		rig.chest_kick = Quaternion(_kick_rot / ang, ang * 0.35)
	else:
		rig.weapon_kick_rot = Quaternion.IDENTITY
		rig.chest_kick = Quaternion.IDENTITY


## Sets locomotion targets from a facing-space velocity (m/s).
## `run` selects the run cycle for forward motion instead of the walk cycle.
func set_locomotion_velocity(local_vel: Vector3, walk_speed: float, run: bool) -> void:
	var planar := Vector2(local_vel.x, -local_vel.z)   # x = right, y = forward
	var spd := planar.length()
	var move_w := clampf(spd / maxf(walk_speed * 0.6, 0.01), 0.0, 1.0)
	for role in loco_clips:
		loco_weights[role] = 0.0
	loco_weights["idle"] = 1.0 - move_w
	if move_w > 0.0:
		var dirn := planar / maxf(spd, 0.0001)
		var fwd := maxf(dirn.y, 0.0)
		var back := maxf(-dirn.y, 0.0)
		var right := maxf(dirn.x, 0.0)
		var left := maxf(-dirn.x, 0.0)
		var total := fwd + back + right + left
		if run and loco_clips.has("run"):
			loco_weights["run"] = move_w
		else:
			loco_weights["fwd"] = move_w * fwd / total
			loco_weights["back"] = move_w * back / total
			loco_weights["right"] = move_w * right / total
			loco_weights["left"] = move_w * left / total
	# Cycle rate from stride length of the dominant clips.
	var stride := 0.0
	var wsum := 0.0
	for role in loco_weights:
		if role == "idle" or not loco_clips.has(role):
			continue
		var c: ClipData = loco_clips[role]
		var w: float = loco_weights[role]
		stride += w * c.get_float("stride_speed", 1.5) * c.length
		wsum += w
	if wsum > 0.0 and stride > 0.0:
		loco_cycle_rate = spd / (stride / wsum)
	else:
		loco_cycle_rate = 0.0


func _eval_locomotion(delta: float) -> Dictionary:
	loco_phase += loco_cycle_rate * delta
	_idle_time += delta
	var pose: Dictionary = {}
	var acc := 0.0
	for role in loco_clips:
		var target: float = loco_weights.get(role, 1.0 if role == "idle" else 0.0)
		var cur: float = _loco_w.get(role, 0.0)
		cur = move_toward(cur, target, delta * 6.0)
		_loco_w[role] = cur
		if cur <= 0.001:
			continue
		var c: ClipData = loco_clips[role]
		var t: float
		if role == "idle":
			t = fposmod(_idle_time, maxf(c.length, 0.01))
		else:
			t = fposmod(loco_phase, 1.0) * c.length
		var s := c.sample(t)
		if pose.is_empty():
			pose = s
			acc = cur
		else:
			acc += cur
			pose = PoseMath.blend(pose, s, cur / acc)
	if pose.is_empty() and loco_clips.has("idle"):
		pose = (loco_clips["idle"] as ClipData).sample(0.0)
	return pose


func _fire_events(from_t: float, to_t: float) -> void:
	if clip == null:
		return
	for ev in clip.events:
		var et := float(ev["t"])
		if et > from_t and et <= to_t:
			event_fired.emit(clip.name, ev)


## Normalized progress 0..1 of the current action clip.
func progress() -> float:
	if clip == null or clip.length <= 0.0:
		return 1.0
	return clampf(time / clip.length, 0.0, 1.0)


## True while the current clip time is inside [from, to].
func in_window(from_t: float, to_t: float) -> bool:
	return clip != null and not loco_active and time >= from_t and time <= to_t
